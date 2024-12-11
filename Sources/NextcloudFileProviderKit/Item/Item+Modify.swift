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
        dbManager: FilesDatabaseManager = .shared
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
                Could not move file or folder: \(oldRemotePath, privacy: .public)
                to \(newRemotePath, privacy: .public),
                received error: \(moveError.errorCode, privacy: .public)
                \(moveError.errorDescription, privacy: .public)
                """
            )
            return (
                nil,
                moveError.matchesCollisionError ?
                    NSFileProviderError(.filenameCollision) : moveError.fileProviderError
            )
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
                Could not acquire metadata of item with identifier: \(ocId, privacy: .public),
                cannot correctly inform of modification
                """
            )
            return (nil, NSFileProviderError(.noSuchItem))
        }

        let modifiedItem = Item(
            metadata: newMetadata,
            parentItemIdentifier: newParentItemIdentifier,
            account: account,
            remoteInterface: remoteInterface
        )
        return (modifiedItem, nil)
    }

    private func modifyContents(
        contents newContents: URL?,
        remotePath: String,
        newCreationDate: Date?,
        newContentModificationDate: Date?,
        domain: NSFileProviderDomain?,
        progress: Progress,
        dbManager: FilesDatabaseManager
    ) async -> (Item?, Error?) {
        let ocId = itemIdentifier.rawValue

        guard newContents != nil, let localPath = newContents?.path else {
            Self.logger.error(
                """
                ERROR. Could not upload modified contents as was provided nil contents url.
                ocId: \(ocId, privacy: .public) filename: \(self.filename, privacy: .public)
                """
            )
            return (nil, NSFileProviderError(.noSuchItem))
        }

        guard let metadata = dbManager.itemMetadata(ocId: ocId) else {
            Self.logger.error(
                "Could not acquire metadata of item with identifier: \(ocId, privacy: .public)"
            )
            return (nil, NSFileProviderError(.noSuchItem))
        }

        let updatedMetadata = await withCheckedContinuation { continuation in
            dbManager.setStatusForItemMetadata(
                metadata, status: ItemMetadata.Status.uploading
            ) { continuation.resume(returning: $0) }
        }

        if updatedMetadata == nil {
            Self.logger.warning(
                """
                Could not acquire updated metadata of item: \(ocId, privacy: .public),
                unable to update item status to uploading
                """
            )
        }

        let (_, _, etag, date, size, _, _, error) = await remoteInterface.upload(
            remotePath: remotePath,
            localPath: localPath,
            creationDate: newCreationDate,
            modificationDate: newContentModificationDate,
            account: account,
            options: .init(),
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
                Could not upload item \(ocId, privacy: .public)
                with filename: \(self.filename, privacy: .public),
                received error: \(error.errorCode, privacy: .public),
                \(error.errorDescription, privacy: .public)
                """
            )

            metadata.status = ItemMetadata.Status.uploadError.rawValue
            metadata.sessionError = error.errorDescription
            dbManager.addItemMetadata(metadata)
            return (nil, error.fileProviderError)
        }

        Self.logger.info(
            """
            Successfully uploaded item with identifier: \(ocId, privacy: .public)
            and filename: \(self.filename, privacy: .public)
            """
        )

        if size != documentSize as? Int64 {
            Self.logger.warning(
                """
                Item content modification upload reported as successful,
                but there are differences between the received file size (\(size, privacy: .public))
                and the original file size (\(self.documentSize?.int64Value ?? 0))
                """
            )
        }

        let newMetadata = ItemMetadata()
        newMetadata.date = (date ?? NSDate()) as Date
        newMetadata.etag = etag ?? metadata.etag
        newMetadata.account = metadata.account
        newMetadata.fileName = metadata.fileName
        newMetadata.fileNameView = metadata.fileNameView
        newMetadata.ocId = ocId
        newMetadata.size = size
        newMetadata.contentType = metadata.contentType
        newMetadata.directory = metadata.directory
        newMetadata.serverUrl = metadata.serverUrl
        newMetadata.session = ""
        newMetadata.sessionError = ""
        newMetadata.sessionTaskIdentifier = 0
        newMetadata.status = ItemMetadata.Status.normal.rawValue
        newMetadata.downloaded = true
        newMetadata.uploaded = true

        dbManager.addItemMetadata(newMetadata)

        let modifiedItem = Item(
            metadata: newMetadata,
            parentItemIdentifier: parentItemIdentifier,
            account: account,
            remoteInterface: remoteInterface
        )
        return (modifiedItem, nil)
    }

    private func modifyBundleOrPackageContents(
        contents newContents: URL?,
        remotePath: String,
        domain: NSFileProviderDomain?,
        progress: Progress,
        dbManager: FilesDatabaseManager
    ) async throws -> Item? {
        guard let contents = newContents else {
            Self.logger.error(
                """
                Could not modify bundle or package contents as was provided nil contents url
                for item with ocID \(self.itemIdentifier.rawValue, privacy: .public)
                (\(self.filename, privacy: .public))
                """
            )
            throw NSFileProviderError(.cannotSynchronize)
        }

        Self.logger.debug(
            """
            Handling modified bundle/package/internal directory at:
            \(contents.path, privacy: .public)
            """
        )

        func remoteErrorToThrow(_ error: NKError) -> Error {
            if error.matchesCollisionError {
                return NSFileProviderError(.filenameCollision)
            } else if let error = error.fileProviderError {
                return error
            } else {
                return NSFileProviderError(.cannotSynchronize)
            }
        }

        // 1. Scan the remote contents of the bundle (recursively)
        // 2. Create set of the found items
        // 3. Upload new contents and get their paths post-upload
        // 4. Delete remote items with paths not present in the new set
        var allMetadatas = [ItemMetadata]()
        var directoriesToRead = [remotePath]
        while !directoriesToRead.isEmpty {
            let remoteDirectoryPath = directoriesToRead.removeFirst()
            let (metadatas, _, _, _, readError) = await Enumerator.readServerUrl(
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
                    \(self.itemIdentifier.rawValue, privacy: .public)
                    (\(self.filename, privacy: .public)),
                    received error: \(readError.errorDescription, privacy: .public)
                    """
                )
                throw remoteErrorToThrow(readError)
            }
            guard let metadatas else {
                Self.logger.error(
                    """
                    Could not read server url for item with ocID
                    \(self.itemIdentifier.rawValue, privacy: .public)
                    (\(self.filename, privacy: .public)),
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

        var staleItems = [String: ItemMetadata]() // remote urls to metadata
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
                """
                Could not create enumerator for contents of bundle or package
                at: \(contents.path, privacy: .public)
                """
            )
            throw NSFileProviderError(.noSuchItem)
        }

        guard let enumeratorArray = enumerator.allObjects as? [URL] else {
            Self.logger.error(
                """
                Could not create enumerator array for contents of bundle or package
                at: \(contents.path, privacy: .public)
                """
            )
            throw NSFileProviderError(.noSuchItem)
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
                Self.logger.debug(
                    """
                    Handling child bundle or package directory at: \(childUrlPath, privacy: .public)
                    """
                )
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
                guard createError == .success else {
                    Self.logger.error(
                        """
                        Could not create new bpi folder at: \(remotePath, privacy: .public),
                        received error: \(createError.errorCode, privacy: .public)
                        \(createError.errorDescription, privacy: .public)
                        """
                    )
                    throw remoteErrorToThrow(createError)
                }
                remoteDirectoriesPaths.append(childRemoteUrl)

            } else if !childIsFolder {
                Self.logger.debug(
                    """
                    Handling child bundle or package file at: \(childUrlPath, privacy: .public)
                    """
                )
                let (_, _, _, _, _, _, _, error) = await remoteInterface.upload(
                    remotePath: childRemoteUrl,
                    localPath: childUrlPath,
                    creationDate: childUrlAttributes.creationDate,
                    modificationDate: childUrlAttributes.contentModificationDate,
                    account: account,
                    options: .init(),
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
                        Could not upload bpi file at: \(childUrlPath, privacy: .public),
                        received error: \(error.errorCode, privacy: .public)
                        \(error.errorDescription, privacy: .public)
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
                    Could not delete stale bpi item at: \(staleItem.key, privacy: .public),
                    received error: \(deleteError.errorCode, privacy: .public)
                    \(deleteError.errorDescription, privacy: .public)
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
            let (_, _, _, _, readError) = await Enumerator.readServerUrl(
                remoteDirectoryPath,
                account: account,
                remoteInterface: remoteInterface,
                dbManager: dbManager
            )

            if let readError, readError != .success {
                Self.logger.error(
                    """
                    Could not read new bpi folder at: \(remotePath, privacy: .public),
                    received error: \(readError.errorDescription, privacy: .public)
                    """
                )
                throw remoteErrorToThrow(readError)
            }
        }

        guard let bundleRootMetadata = dbManager.itemMetadata(
            ocId: self.itemIdentifier.rawValue
        ) else {
            Self.logger.error(
                """
                Could not find directory metadata for bundle or package at:
                \(contentsPath, privacy: .public)
                """
            )
            throw NSFileProviderError(.noSuchItem)
        }

        progress.completedUnitCount += 1

        return Item(
            metadata: bundleRootMetadata,
            parentItemIdentifier: parentItemIdentifier,
            account: account,
            remoteInterface: remoteInterface
        )
    }

    private static func trash(
        _ modifiedItem: Item,
        account: Account,
        dbManager: FilesDatabaseManager,
        domain: NSFileProviderDomain?
    ) async -> (Item, Error?) {
        let deleteError =
            await modifiedItem.delete(trashing: true, domain: domain, dbManager: dbManager)
        guard deleteError == nil else {
            Self.logger.error(
                """
                Error attempting to move item into trash:
                \(modifiedItem.filename, privacy: .public)
                \(deleteError?.localizedDescription ?? "", privacy: .public)
                """
            )
            return (modifiedItem, deleteError)
        }

        let ocId = modifiedItem.itemIdentifier.rawValue
        guard let dirtyMetadata = dbManager.itemMetadataFromOcId(ocId) else {
            Self.logger.error(
                """
                Could not correctly process trashing results, dirty metadata not found.
                \(modifiedItem.filename, privacy: .public) \(ocId, privacy: .public)
                """
            )
            return (modifiedItem, NSFileProviderError(.cannotSynchronize))
        }

        // The server may have renamed the trashed file so we need to scan the entire trash
        let (_, files, _, error) = await modifiedItem.remoteInterface.enumerate(
            remotePath: account.trashUrl,
            depth: EnumerateDepth.targetAndAllChildren,
            showHiddenFiles: true,
            includeHiddenFiles: [],
            requestBody: nil,
            account: account,
            options: .init(),
            taskHandler: { task in
                if let domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: modifiedItem.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }
        )

        guard error == .success,
              let targetItemNKFile = files.first(where: { $0.ocId == modifiedItem.metadata.ocId })
        else {
            Self.logger.error(
                """
                Received bad error or files from post-trashing remote scan:
                \(error.errorDescription, privacy: .public) \(files, privacy: .public)
                """
            )
            return(Item(
                metadata: dirtyMetadata,
                parentItemIdentifier: .trashContainer,
                account: account,
                remoteInterface: modifiedItem.remoteInterface
            ), error.fileProviderError)
        }

        let postDeleteMetadata = ItemMetadata.fromNKFile(targetItemNKFile, account: account)
        dbManager.addItemMetadata(postDeleteMetadata)

        let postDeleteItem = Item(
            metadata: postDeleteMetadata,
            parentItemIdentifier: .trashContainer,
            account: account,
            remoteInterface: modifiedItem.remoteInterface
        )

        // Now we can directly update info on the child items
        var (_, childFiles, _, childError) = await modifiedItem.remoteInterface.enumerate(
            remotePath: account.trashUrl,
            depth: EnumerateDepth.targetAndAllChildren, // Just do it in one go
            showHiddenFiles: true,
            includeHiddenFiles: [],
            requestBody: nil,
            account: account,
            options: .init(),
            taskHandler: { task in
                if let domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: modifiedItem.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }
        )

        guard error == .success else {
            Self.logger.error(
                """
                Received bad error or files from post-trashing child items remote scan:
                \(error.errorDescription, privacy: .public) \(files, privacy: .public)
                """
            )
            return (postDeleteItem, childError.fileProviderError)
        }

        // Update state of child files
        childFiles.removeFirst() // This is the target path, already scanned
        for file in childFiles {
            let metadata = ItemMetadata.fromNKFile(file, account: account)
            dbManager.addItemMetadata(metadata)
        }

        return (postDeleteItem, nil)
    }

    func modify(
        itemTarget: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion = NSFileProviderItemVersion(),
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest = NSFileProviderRequest(),
        domain: NSFileProviderDomain? = nil,
        progress: Progress = .init(),
        dbManager: FilesDatabaseManager = .shared
    ) async -> (Item?, Error?) {
        var modifiedItem = self

        let ocId = modifiedItem.itemIdentifier.rawValue
        guard itemTarget.itemIdentifier == modifiedItem.itemIdentifier else {
            Self.logger.error(
                """
                Could not modify item: \(ocId, privacy: .public), different identifier to the
                item the modification was targeting
                (\(itemTarget.itemIdentifier.rawValue, privacy: .public))
                """
            )
            return (nil, NSFileProviderError(.noSuchItem))
        }

        let parentItemIdentifier = itemTarget.parentItemIdentifier
        let isFolder = modifiedItem.contentType.conforms(to: .directory)
        let bundleOrPackage =
            modifiedItem.contentType.conforms(to: .bundle) ||
            modifiedItem.contentType.conforms(to: .package)

        if options.contains(.mayAlreadyExist) {
            // TODO: This needs to be properly handled with a check in the db
            Self.logger.warning(
                "Modification for item: \(ocId, privacy: .public) may already exist"
            )
        }

        var parentItemServerUrl: String

        // The target parent should already be present in our database. The system will have synced
        // remote changes and then, upon user interaction, will try to modify the item.
        // That is, if the parent item has changed at all (it might not have)
        if parentItemIdentifier == .rootContainer {
            parentItemServerUrl = account.davFilesUrl
        } else if parentItemIdentifier == .trashContainer {
            parentItemServerUrl = account.trashUrl
        } else {
            guard let parentItemMetadata = dbManager.directoryMetadata(
                ocId: parentItemIdentifier.rawValue
            ) else {
                Self.logger.error(
                    """
                    Not modifying item: \(ocId, privacy: .public),
                    could not find metadata for target parentItemIdentifier
                        \(parentItemIdentifier.rawValue, privacy: .public)
                    """
                )
                return (nil, NSFileProviderError(.noSuchItem))
            }

            parentItemServerUrl = parentItemMetadata.serverUrl + "/" + parentItemMetadata.fileName
        }

        let newServerUrlFileName = parentItemServerUrl + "/" + itemTarget.filename

        Self.logger.debug(
            """
            About to modify item with identifier: \(ocId, privacy: .public)
            of type: \(modifiedItem.contentType.identifier)
            (is folder: \(isFolder ? "yes" : "no", privacy: .public)
            and filename: \(itemTarget.filename, privacy: .public)
            from old server url:
                \(modifiedItem.metadata.serverUrl + "/" + modifiedItem.filename, privacy: .public)
            to server url: \(newServerUrlFileName, privacy: .public)
            with contents located at: \(newContents?.path ?? "", privacy: .public)
            """
        )

        if (changedFields.contains(.parentItemIdentifier) && parentItemIdentifier == .trashContainer) {
            Self.logger.debug(
                """
                Changed fields for item \(ocId, privacy: .public)
                with filename \(modifiedItem.filename, privacy: .public)
                includes filename or parentitemidentifier.
                old filename: \(modifiedItem.filename, privacy: .public)
                new filename: \(itemTarget.filename, privacy: .public)
                old parent identifier: \(modifiedItem.parentItemIdentifier.rawValue, privacy: .public)
                new parent identifier: \(itemTarget.parentItemIdentifier.rawValue, privacy: .public)
                """
            )

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
                        Could not rename pre-trash item with ocID \(ocId, privacy: .public)
                        (\(modifiedItem.filename, privacy: .public)) to
                        \(newServerUrlFileName, privacy: .public),
                        received error: \(renameError?.localizedDescription ?? "", privacy: .public)
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
            let (renameModifiedItem, renameError) = await modifiedItem.move(
                newFileName: itemTarget.filename,
                newRemotePath: newServerUrlFileName,
                newParentItemIdentifier: parentItemIdentifier,
                newParentItemRemotePath: parentItemServerUrl,
                dbManager: dbManager
            )

            guard renameError == nil, let renameModifiedItem else {
                Self.logger.error(
                    """
                    Could not rename item with ocID \(ocId, privacy: .public)
                    (\(modifiedItem.filename, privacy: .public)) to
                    \(newServerUrlFileName, privacy: .public),
                    received error: \(renameError?.localizedDescription ?? "", privacy: .public)
                    """
                )
                return (nil, renameError)
            }

            modifiedItem = renameModifiedItem
        }

        guard !isFolder || bundleOrPackage else {
            Self.logger.debug(
                """
                System requested modification for folder with ocID \(ocId, privacy: .public)
                (\(newServerUrlFileName, privacy: .public)) of something other than folder name.
                This is not supported.
                """
            )
            return (modifiedItem, nil)
        }

        if changedFields.contains(.contents) {
            Self.logger.debug(
                """
                Item modification for \(ocId, privacy: .public)
                \(modifiedItem.filename, privacy: .public)
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
                    domain: domain,
                    progress: progress,
                    dbManager: dbManager
                )
            }

            guard contentError == nil, let contentModifiedItem else {
                Self.logger.error(
                    """
                    Could not modify contents for item with ocID \(ocId, privacy: .public)
                    (\(modifiedItem.filename, privacy: .public)) to
                    \(newServerUrlFileName, privacy: .public),
                    received error: \(contentError?.localizedDescription ?? "", privacy: .public)
                    """
                )
                return (nil, contentError)
            }

            modifiedItem = contentModifiedItem
        }

        Self.logger.debug(
            """
            Nothing more to do with \(ocId, privacy: .public)
            \(modifiedItem.filename, privacy: .public), modifications complete
            """
        )
        return (modifiedItem, nil)
    }
}
