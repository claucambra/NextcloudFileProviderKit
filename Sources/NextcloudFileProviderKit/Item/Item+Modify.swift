//
//  Item+Modify.swift
//
//
//  Created by Claudio Cambra on 16/4/24.
//

import FileProvider
import Foundation
import NextcloudKit
import OSLog

public extension Item {

    func move(
        newFileName: String,
        newRemotePath: String,
        newParentItemIdentifier: NSFileProviderItemIdentifier,
        newParentItemRemotePath: String,
        domain: NSFileProviderDomain? = nil,
        dbManager: FilesDatabaseManager
    ) async -> (Item?, Error?) {
        let ocId = itemIdentifier.rawValue
        let isFolder = contentType.conforms(to: .directory)
        let oldRemotePath = metadata.serverUrl + "/" + filename
        let (_, _, moveError) = await remoteInterface.move(
            remotePathSource: oldRemotePath,
            remotePathDestination: newRemotePath,
            overwrite: false,
            account: account,
            options: .init(),
            taskHandler: { task in
                if let domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: self.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }
        )

        guard moveError == .success else {
            Self.logger.error(
                """
                Could not move file or folder: \(oldRemotePath)
                    to \(newRemotePath),
                    received error: \(moveError.errorCode) \(moveError.errorDescription)
                """
            )
            return (nil, await moveError.fileProviderError(
                handlingCollisionAgainstItemInRemotePath: newRemotePath,
                dbManager: dbManager,
                remoteInterface: remoteInterface
            ))
        }

        if isFolder {
            _ = dbManager.renameDirectoryAndPropagateToChildren(
                ocId: ocId,
                newServerUrl: newParentItemRemotePath,
                newFileName: newFileName
            )
        } else {
            dbManager.renameItemMetadata(
                ocId: ocId,
                newServerUrl: newParentItemRemotePath,
                newFileName: newFileName
            )
        }

        guard let newMetadata = dbManager.itemMetadata(ocId: ocId) else {
            Self.logger.error(
                """
                Could not acquire metadata of item with identifier: \(ocId),
                    cannot correctly inform of modification
                """
            )
            return (
                nil,
                NSError.fileProviderErrorForNonExistentItem(withIdentifier: self.itemIdentifier)
            )
        }

        let modifiedItem = Item(
            metadata: newMetadata,
            parentItemIdentifier: newParentItemIdentifier,
            account: account,
            remoteInterface: remoteInterface,
            dbManager: dbManager,
            remoteSupportsTrash: await remoteInterface.supportsTrash(account: account)
        )
        return (modifiedItem, nil)
    }

    private func modifyContents(
        contents newContents: URL?,
        remotePath: String,
        newCreationDate: Date?,
        newContentModificationDate: Date?,
        forcedChunkSize: Int?,
        domain: NSFileProviderDomain?,
        progress: Progress,
        dbManager: FilesDatabaseManager
    ) async -> (Item?, Error?) {
        let ocId = itemIdentifier.rawValue

        guard let newContents else {
            Self.logger.error(
                """
                ERROR. Could not upload modified contents as was provided nil contents url.
                    ocId: \(ocId) filename: \(self.filename)
                """
            )
            return (
                nil,
                NSError.fileProviderErrorForNonExistentItem(withIdentifier: self.itemIdentifier)
            )
        }

        guard var metadata = dbManager.itemMetadata(ocId: ocId) else {
            Self.logger.error(
                "Could not acquire metadata of item with identifier: \(ocId)"
            )
            return (
                nil,
                NSError.fileProviderErrorForNonExistentItem(withIdentifier: self.itemIdentifier)
            )
        }

        guard let updatedMetadata = dbManager.setStatusForItemMetadata(metadata, status: .uploading) else {
            Self.logger.warning(
                """
                Could not acquire updated metadata of item: \(ocId),
                    unable to update item status to uploading
                """
            )
            return (
                nil,
                NSError.fileProviderErrorForNonExistentItem(withIdentifier: self.itemIdentifier)
            )
        }

        let (_, _, etag, date, size, _, error) = await upload(
            fileLocatedAt: newContents.path,
            toRemotePath: remotePath,
            usingRemoteInterface: remoteInterface,
            withAccount: account,
            inChunksSized: forcedChunkSize,
            usingChunkUploadId: metadata.chunkUploadId,
            dbManager: dbManager,
            creationDate: newCreationDate,
            modificationDate: newContentModificationDate,
            requestHandler: { progress.setHandlersFromAfRequest($0) },
            taskHandler: { task in
                if let domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: self.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            },
            progressHandler: { $0.copyCurrentStateToProgress(progress) }
        )

        guard error == .success else {
            Self.logger.error(
                """
                Could not upload item \(ocId)
                    with filename: \(self.filename),
                    received error: \(error.errorCode), \(error.errorDescription)
                """
            )

            metadata.status = Status.uploadError.rawValue
            metadata.sessionError = error.errorDescription
            dbManager.addItemMetadata(metadata)
            // Moving should be done before uploading and should catch collisions already, but,
            // it is painless to check here too just in case
            return (nil, await error.fileProviderError(
                handlingCollisionAgainstItemInRemotePath: remotePath,
                dbManager: dbManager,
                remoteInterface: remoteInterface
            ))
        }

        Self.logger.info(
            "Successfully uploaded item with identifier: \(ocId) and filename: \(self.filename)"
        )

        let contentAttributes = try? FileManager.default.attributesOfItem(atPath: newContents.path)
        if let expectedSize = contentAttributes?[.size] as? Int64, size != expectedSize {
            Self.logger.warning(
                """
                Item content modification upload reported as successful,
                    but there are differences between the received file size (\(size ?? -1))
                    and the original file size (\(self.documentSize?.int64Value ?? 0))
                """
            )
        }

        var newMetadata =
            dbManager.setStatusForItemMetadata(updatedMetadata, status: .normal) ?? SendableItemMetadata(value: updatedMetadata)

        newMetadata.date = date ?? Date()
        newMetadata.etag = etag ?? metadata.etag
        newMetadata.ocId = ocId
        newMetadata.size = size ?? 0
        newMetadata.session = ""
        newMetadata.sessionError = ""
        newMetadata.sessionTaskIdentifier = 0
        newMetadata.downloaded = true
        newMetadata.uploaded = true

        dbManager.addItemMetadata(newMetadata)

        let modifiedItem = Item(
            metadata: newMetadata,
            parentItemIdentifier: parentItemIdentifier,
            account: account,
            remoteInterface: remoteInterface,
            dbManager: dbManager,
            remoteSupportsTrash: await remoteInterface.supportsTrash(account: account)
        )
        return (modifiedItem, nil)
    }

    private func modifyBundleOrPackageContents(
        contents newContents: URL?,
        remotePath: String,
        forcedChunkSize: Int?,
        domain: NSFileProviderDomain?,
        progress: Progress,
        dbManager: FilesDatabaseManager
    ) async throws -> Item? {
        guard let contents = newContents else {
            Self.logger.error(
                """
                Could not modify bundle or package contents as was provided nil contents url
                    for item with ocID \(self.itemIdentifier.rawValue)
                    (\(self.filename))
                """
            )
            throw NSFileProviderError(.cannotSynchronize)
        }

        Self.logger.debug("Handling modified bundle/package/internal directory at \(contents.path)")

        func remoteErrorToThrow(_ error: NKError) -> Error {
            return error.fileProviderError ?? NSFileProviderError(.cannotSynchronize)
        }

        // 1. Scan the remote contents of the bundle (recursively)
        // 2. Create set of the found items
        // 3. Upload new contents and get their paths post-upload
        // 4. Delete remote items with paths not present in the new set
        var allMetadatas = [SendableItemMetadata]()
        var directoriesToRead = [remotePath]
        while !directoriesToRead.isEmpty {
            let remoteDirectoryPath = directoriesToRead.removeFirst()
            let (metadatas, _, _, _, _, readError) = await Enumerator.readServerUrl(
                remoteDirectoryPath,
                account: account,
                remoteInterface: remoteInterface,
                dbManager: dbManager
            )
            // Important note -- the enumerator will import found items' metadata into the database.
            // This is important for when we want to start deleting stale items and want to avoid trying
            // to delete stale items that have already been deleted because the parent folder and all of
            // its contents have been nuked already

            if let readError {
                Self.logger.error(
                    """
                    Could not read server url for item with ocID
                        \(self.itemIdentifier.rawValue)
                        (\(self.filename)),
                        received error: \(readError.errorDescription)
                    """
                )
                throw remoteErrorToThrow(readError)
            }
            guard let metadatas else {
                Self.logger.error(
                    """
                    Could not read server url for item with ocID
                        \(self.itemIdentifier.rawValue)
                        (\(self.filename)),
                        received nil metadatas
                    """
                )
                throw NSFileProviderError(.serverUnreachable)
            }

            allMetadatas.append(contentsOf: metadatas)

            var childDirPaths = [String]()
            for metadata in metadatas {
                guard metadata.directory,
                      metadata.ocId != self.itemIdentifier.rawValue
                else { continue }
                childDirPaths.append(remoteDirectoryPath + "/" + metadata.fileName)
            }
            directoriesToRead.append(contentsOf: childDirPaths)
        }

        var staleItems = [String: SendableItemMetadata]() // remote urls to metadata
        for metadata in allMetadatas {
            let remoteUrlPath = metadata.serverUrl + "/" + metadata.fileName
            guard remoteUrlPath != remotePath else { continue }
            staleItems[remoteUrlPath] = metadata
        }

        let attributesToFetch: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey
        ]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: contents, includingPropertiesForKeys: Array(attributesToFetch)
        ) else {
            Self.logger.error(
                "Could not create enumerator for contents of bundle or package at: \(contents.path)"
            )
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable)
        }

        guard let enumeratorArray = enumerator.allObjects as? [URL] else {
            Self.logger.error(
                """
                Could not create enumerator array for contents of bundle or package
                    at: \(contents.path)
                """
            )
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable)
        }

        // Add one more total unit count to signify final reconciliation of bundle modify process
        progress.totalUnitCount = Int64(enumeratorArray.count) + 1

        let contentsPath = contents.path
        let privatePrefix = "/private"
        let privateContentsPath = contentsPath.hasPrefix(privatePrefix)
        var remoteDirectoriesPaths = [remotePath]

        for childUrl in enumeratorArray {
            var childUrlPath = childUrl.path
            if childUrlPath.hasPrefix(privatePrefix), !privateContentsPath {
                childUrlPath.removeFirst(privatePrefix.count)
            }
            let childRelativePath = childUrlPath.replacingOccurrences(of: contents.path, with: "")
            let childRemoteUrl = remotePath + childRelativePath
            let childUrlAttributes = try childUrl.resourceValues(forKeys: attributesToFetch)
            let childIsFolder = childUrlAttributes.isDirectory ?? false

            // Do not re-create directories
            if childIsFolder, !staleItems.keys.contains(childRemoteUrl) {
                Self.logger.debug("Handling child bundle or package directory at: \(childUrlPath)")
                let (_, _, _, createError) = await remoteInterface.createFolder(
                    remotePath: childRemoteUrl,
                    account: account,
                    options: .init(),
                    taskHandler: { task in
                        if let domain {
                            NSFileProviderManager(for: domain)?.register(
                                task,
                                forItemWithIdentifier: self.itemIdentifier,
                                completionHandler: { _ in }
                            )
                        }
                    }
                )
                // Don't error if there is a collision
                guard createError == .success || createError.matchesCollisionError else {
                    Self.logger.error(
                        """
                        Could not create new bpi folder at: \(remotePath),
                        received error: \(createError.errorCode)
                        \(createError.errorDescription)
                        """
                    )
                    throw remoteErrorToThrow(createError)
                }
                remoteDirectoriesPaths.append(childRemoteUrl)

            } else if !childIsFolder {
                Self.logger.debug(
                    """
                    Handling child bundle or package file at: \(childUrlPath)
                    """
                )
                let (_, _, _, _, _, _, error) = await upload(
                    fileLocatedAt: childUrlPath,
                    toRemotePath: childRemoteUrl,
                    usingRemoteInterface: remoteInterface,
                    withAccount: account,
                    inChunksSized: forcedChunkSize,
                    dbManager: dbManager,
                    creationDate: childUrlAttributes.creationDate,
                    modificationDate: childUrlAttributes.contentModificationDate,
                    requestHandler: { progress.setHandlersFromAfRequest($0) },
                    taskHandler: { task in
                        if let domain {
                            NSFileProviderManager(for: domain)?.register(
                                task,
                                forItemWithIdentifier: self.itemIdentifier,
                                completionHandler: { _ in }
                            )
                        }
                    },
                    progressHandler: { _ in }
                )

                guard error == .success else {
                    Self.logger.error(
                        """
                        Could not upload bpi file at: \(childUrlPath),
                        received error: \(error.errorCode)
                        \(error.errorDescription)
                        """
                    )
                    throw remoteErrorToThrow(error)
                }
            }
            staleItems.removeValue(forKey: childRemoteUrl)
            progress.completedUnitCount += 1
        }

        for staleItem in staleItems {
            let staleItemMetadata = staleItem.value
            guard dbManager.itemMetadata(ocId: staleItemMetadata.ocId) != nil else { continue }

            let (_, _, deleteError) = await remoteInterface.delete(
                remotePath: staleItem.key,
                account: account,
                options: .init(),
                taskHandler: { task in
                    if let domain {
                        NSFileProviderManager(for: domain)?.register(
                            task,
                            forItemWithIdentifier: self.itemIdentifier,
                            completionHandler: { _ in }
                        )
                    }
                }
            )

            guard deleteError == .success else {
                Self.logger.error(
                    """
                    Could not delete stale bpi item at: \(staleItem.key),
                        received error: \(deleteError.errorCode)
                        \(deleteError.errorDescription)
                    """
                )
                throw remoteErrorToThrow(deleteError)
            }

            if staleItemMetadata.directory {
                _ = dbManager.deleteDirectoryAndSubdirectoriesMetadata(ocId: staleItemMetadata.ocId)
            } else {
                dbManager.deleteItemMetadata(ocId: staleItemMetadata.ocId)
            }
        }

        for remoteDirectoryPath in remoteDirectoriesPaths {
            // After everything, check into what the final state is of each folder now
            let (_, _, _, _, _, readError) = await Enumerator.readServerUrl(
                remoteDirectoryPath,
                account: account,
                remoteInterface: remoteInterface,
                dbManager: dbManager
            )

            if let readError, readError != .success {
                Self.logger.error(
                    """
                    Could not read new bpi folder at: \(remotePath),
                        received error: \(readError.errorDescription)
                    """
                )
                throw remoteErrorToThrow(readError)
            }
        }

        guard let bundleRootMetadata = dbManager.itemMetadata(
            ocId: self.itemIdentifier.rawValue
        ) else {
            Self.logger.error("Could'nt find directory metadata for bundle/package \(contentsPath)")
            throw NSError.fileProviderErrorForNonExistentItem(withIdentifier: self.itemIdentifier)
        }

        progress.completedUnitCount += 1

        return Item(
            metadata: bundleRootMetadata,
            parentItemIdentifier: parentItemIdentifier,
            account: account,
            remoteInterface: remoteInterface,
            dbManager: dbManager,
            remoteSupportsTrash: await remoteInterface.supportsTrash(account: account)
        )
    }

    func modify(
        itemTarget: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion = NSFileProviderItemVersion(),
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest = NSFileProviderRequest(),
        ignoredFiles: IgnoredFilesMatcher? = nil,
        domain: NSFileProviderDomain? = nil,
        forcedChunkSize: Int? = nil,
        progress: Progress = .init(),
        dbManager: FilesDatabaseManager
    ) async -> (Item?, Error?) {
        // For your own good: don't use "self" below here, it'll save you pain debugging when you do
        // refactors later on. Just use modifiedItem
        var modifiedItem = self

        guard metadata.classFile != "lock", !isLockFileName(metadata.fileName) else {
            return await modifiedItem.modifyLockFile(
                itemTarget: itemTarget,
                baseVersion: baseVersion,
                changedFields: changedFields,
                contents: newContents,
                options: options,
                request: request,
                ignoredFiles: ignoredFiles,
                domain: domain,
                forcedChunkSize: forcedChunkSize,
                progress: progress,
                dbManager: dbManager
            )
        }

        let relativePath = (
            metadata.serverUrl + "/" + metadata.fileName
        ).replacingOccurrences(of: account.davFilesUrl, with: "")

        guard ignoredFiles == nil || ignoredFiles?.isExcluded(relativePath) == false else {
            Self.logger.info(
                """
                File \(modifiedItem.filename) is in the ignore list.
                    Will delete locally with no remote effect.
                """
            )
            guard let modifiedIgnored = await modifyUnuploaded(
                itemTarget: itemTarget,
                baseVersion: baseVersion,
                changedFields: changedFields,
                contents: newContents,
                options: options,
                request: request,
                ignoredFiles: ignoredFiles,
                domain: domain,
                forcedChunkSize: forcedChunkSize,
                progress: progress,
                dbManager: dbManager
            ) else {
                Self.logger.error("Unable to modify ignored file, got nil item: \(relativePath)")
                return (nil, NSFileProviderError(.cannotSynchronize))
            }
            modifiedItem = modifiedIgnored
            if #available(macOS 13.0, *) {
                return (modifiedItem, NSFileProviderError(.excludedFromSync))
            } else {
                return (modifiedItem, nil)
            }
        }

        // We are handling an item that is available locally but not on the server -- so create it
        // This can happen when a previously ignored file is no longer ignored
        if !modifiedItem.isUploaded, modifiedItem.isDownloaded, modifiedItem.metadata.etag == "" {
            return await modifiedItem.createUnuploaded(
                itemTarget: itemTarget,
                baseVersion: baseVersion,
                changedFields: changedFields,
                contents: newContents,
                options: options,
                request: request,
                ignoredFiles: ignoredFiles,
                domain: domain,
                forcedChunkSize: forcedChunkSize,
                progress: progress,
                dbManager: dbManager
            )
        }

        let ocId = modifiedItem.itemIdentifier.rawValue
        guard itemTarget.itemIdentifier == modifiedItem.itemIdentifier else {
            Self.logger.error(
                """
                Could not modify item: \(ocId), different identifier to the item the modification
                    was targeting
                    (\(itemTarget.itemIdentifier.rawValue))
                """
            )
            return (
                nil,
                NSError.fileProviderErrorForNonExistentItem(withIdentifier: self.itemIdentifier)
            )
        }

        let newParentItemIdentifier = itemTarget.parentItemIdentifier
        let isFolder = modifiedItem.contentType.conforms(to: .directory)
        let bundleOrPackage =
            modifiedItem.contentType.conforms(to: .bundle) ||
            modifiedItem.contentType.conforms(to: .package)

        if options.contains(.mayAlreadyExist) {
            // TODO: This needs to be properly handled with a check in the db
            Self.logger.warning("Modification for item: \(ocId) may already exist")
        }

        var newParentItemRemoteUrl: String

        // The target parent should already be present in our database. The system will have synced
        // remote changes and then, upon user interaction, will try to modify the item.
        // That is, if the parent item has changed at all (it might not have)
        if newParentItemIdentifier == .rootContainer {
            newParentItemRemoteUrl = account.davFilesUrl
        } else if newParentItemIdentifier == .trashContainer {
            newParentItemRemoteUrl = account.trashUrl
        } else {
            guard let parentItemMetadata = dbManager.directoryMetadata(
                ocId: newParentItemIdentifier.rawValue
            ) else {
                Self.logger.error(
                    """
                    Not modifying item: \(ocId),
                        could not find metadata for target parentItemIdentifier
                        \(newParentItemIdentifier.rawValue)
                    """
                )
                return (
                    nil,
                    NSError.fileProviderErrorForNonExistentItem(withIdentifier: self.itemIdentifier)
                )
            }

            newParentItemRemoteUrl = parentItemMetadata.serverUrl + "/" + parentItemMetadata.fileName
        }

        let newServerUrlFileName = newParentItemRemoteUrl + "/" + itemTarget.filename

        Self.logger.debug(
            """
            About to modify item with identifier: \(ocId)
                of type: \(modifiedItem.contentType.identifier)
                (is folder: \(isFolder ? "yes" : "no")
                with filename: \(modifiedItem.filename)
                to filename: \(itemTarget.filename)
                from old server url:
                    \(modifiedItem.metadata.serverUrl + "/" + modifiedItem.metadata.fileName)
                to server url: \(newServerUrlFileName)
                old parent identifier: \(modifiedItem.parentItemIdentifier.rawValue)
                new parent identifier: \(itemTarget.parentItemIdentifier.rawValue)
                with contents located at: \(newContents?.path ?? "")
            """
        )

        if changedFields.contains(.parentItemIdentifier)
            && newParentItemIdentifier == .trashContainer
            && modifiedItem.metadata.isTrashed {

            if (changedFields.contains(.filename)) {
                Self.logger.warning(
                    """
                    Tried to modify filename of already trashed item. This is not supported.
                        ocId: \(modifiedItem.itemIdentifier.rawValue)
                        filename: \(modifiedItem.metadata.fileName)
                        new filename: \(itemTarget.filename)
                    """
                )
            }

            Self.logger.info(
                """
                Tried to trash item that is in fact already trashed.
                    ocId: \(modifiedItem.itemIdentifier.rawValue)
                    filename: \(modifiedItem.metadata.fileName)
                    serverUrl: \(modifiedItem.metadata.serverUrl)
                """
            )
            return (modifiedItem, nil)
        } else if changedFields.contains(.parentItemIdentifier) && newParentItemIdentifier == .trashContainer {
            let (_, capabilities, _, error) = await remoteInterface.currentCapabilities(
                account: account, options: .init(), taskHandler: { _ in }
            )
            guard let capabilities, error == .success else {
                Self.logger.error(
                    """
                    Could not acquire capabilities during item move to trash, won't proceed.
                        Error: \(error.errorDescription)
                        Item: \(modifiedItem.filename)
                    """
                )
                return (nil, error.fileProviderError)
            }
            guard capabilities.files?.undelete == true else {
                Self.logger.error(
                    "Cannot delete \(modifiedItem.filename) as server does not support trashing."
                )
                return (nil, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            }

            // We can't just move files into the trash, we need to issue a deletion; let's handle it
            // Rename the item if necessary before doing the trashing procedures
            if (changedFields.contains(.filename)) {
                let currentParentItemRemotePath = modifiedItem.metadata.serverUrl
                let preTrashingRenamedRemotePath =
                    currentParentItemRemotePath + "/" + itemTarget.filename
                let (renameModifiedItem, renameError) = await modifiedItem.move(
                    newFileName: itemTarget.filename,
                    newRemotePath: preTrashingRenamedRemotePath,
                    newParentItemIdentifier: modifiedItem.parentItemIdentifier,
                    newParentItemRemotePath: currentParentItemRemotePath,
                    dbManager: dbManager
                )

                guard renameError == nil, let renameModifiedItem else {
                    Self.logger.error(
                        """
                        Could not rename pre-trash item with ocID \(ocId)
                            (\(modifiedItem.filename)) to
                            \(newServerUrlFileName),
                            received error: \(renameError?.localizedDescription ?? "")
                        """
                    )
                    return (nil, renameError)
                }

                modifiedItem = renameModifiedItem
            }

            let (trashedItem, trashingError) = await Self.trash(
                modifiedItem, account: account, dbManager: dbManager, domain: domain
            )
            guard trashingError == nil else { return (modifiedItem, trashingError) }
            modifiedItem = trashedItem
        } else if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
            // Recover the item first
            if modifiedItem.parentItemIdentifier != itemTarget.parentItemIdentifier &&
                modifiedItem.parentItemIdentifier == .trashContainer &&
                modifiedItem.metadata.isTrashed
            {
                let (restoredItem, restoreError) = await Self.restoreFromTrash(
                    modifiedItem,
                    account: account,
                    remoteInterface: remoteInterface,
                    dbManager: dbManager,
                    domain: domain
                )
                guard restoreError == nil else {
                    return (modifiedItem, restoreError)
                }
                modifiedItem = restoredItem
            }

            // Maybe during the untrashing the item's intended modifications were complete.
            // If not the case, or the item modification does not involve untrashing, move/rename.
            if (changedFields.contains(.filename) && modifiedItem.filename != itemTarget.filename) ||
                (changedFields.contains(.parentItemIdentifier) &&
                 modifiedItem.parentItemIdentifier != itemTarget.parentItemIdentifier)
            {
                let (renameModifiedItem, renameError) = await modifiedItem.move(
                    newFileName: itemTarget.filename,
                    newRemotePath: newServerUrlFileName,
                    newParentItemIdentifier: newParentItemIdentifier,
                    newParentItemRemotePath: newParentItemRemoteUrl,
                    dbManager: dbManager
                )

                guard renameError == nil, let renameModifiedItem else {
                    return (nil, renameError)
                }

                modifiedItem = renameModifiedItem
            }
        }

        guard !isFolder || bundleOrPackage else {
            Self.logger.debug(
                """
                System requested modification for folder with ocID \(ocId)
                    (\(newServerUrlFileName)) of something other than folder name.
                    This is not supported.
                """
            )
            return (modifiedItem, nil)
        }

        guard newParentItemIdentifier != .trashContainer else {
            Self.logger.debug(
                """
                System requested modification in trash for item with ocID \(ocId)
                    (\(newServerUrlFileName))
                    This is not supported.
                """
            )
            return (modifiedItem, nil)
        }

        if changedFields.contains(.contents) {
            Self.logger.debug(
                """
                Item modification for \(ocId)
                    \(modifiedItem.filename)
                    includes contents. Will begin upload.
                """
            )

            let newCreationDate = itemTarget.creationDate ?? creationDate
            let newContentModificationDate =
                itemTarget.contentModificationDate ?? contentModificationDate
            var contentModifiedItem: Item?
            var contentError: Error?

            if bundleOrPackage {
                do {
                    contentModifiedItem = try await modifiedItem.modifyBundleOrPackageContents(
                        contents: newContents,
                        remotePath: newServerUrlFileName,
                        forcedChunkSize: forcedChunkSize,
                        domain: domain,
                        progress: progress,
                        dbManager: dbManager
                    )
                } catch let error {
                    contentError = error
                }
            } else {
                (contentModifiedItem, contentError) = await modifiedItem.modifyContents(
                    contents: newContents,
                    remotePath: newServerUrlFileName,
                    newCreationDate: newCreationDate,
                    newContentModificationDate: newContentModificationDate,
                    forcedChunkSize: forcedChunkSize,
                    domain: domain,
                    progress: progress,
                    dbManager: dbManager
                )
            }

            guard contentError == nil, let contentModifiedItem else {
                Self.logger.error(
                    """
                    Could not modify contents for item with ocID \(ocId)
                        (\(modifiedItem.filename)) to
                        \(newServerUrlFileName),
                        received error: \(contentError?.localizedDescription ?? "")
                    """
                )
                return (nil, contentError)
            }

            modifiedItem = contentModifiedItem
        }

        Self.logger.debug(
            "Nothing more to do with \(ocId) \(modifiedItem.filename), modifications complete"
        )
        return (modifiedItem, nil)
    }
}
