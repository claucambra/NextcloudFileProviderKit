//
//  Item+Modify.swift
//
//
//  Created by Claudio Cambra on 16/4/24.
//

import FileProvider
import Foundation
import NextcloudKit

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
        forcedChunkSize: Int?,
        domain: NSFileProviderDomain?,
        progress: Progress,
        dbManager: FilesDatabaseManager
    ) async -> (Item?, Error?) {
        let ocId = itemIdentifier.rawValue

        guard let newContents else {
            return (nil, NSFileProviderError(.noSuchItem))
        }

        guard var metadata = dbManager.itemMetadata(ocId: ocId) else {
            return (nil, NSFileProviderError(.noSuchItem))
        }

        guard let updatedMetadata = dbManager.setStatusForItemMetadata(metadata, status: .uploading) else {
            return (nil, NSFileProviderError(.noSuchItem))
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
            metadata.status = Status.uploadError.rawValue
            metadata.sessionError = error.errorDescription
            dbManager.addItemMetadata(metadata)
            return (nil, error.fileProviderError)
        }

        let contentAttributes = try? FileManager.default.attributesOfItem(atPath: newContents.path)
        if let expectedSize = contentAttributes?[.size] as? Int64, size != expectedSize {
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
            remoteInterface: remoteInterface
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
            throw NSFileProviderError(.cannotSynchronize)
        }

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
        var allMetadatas = [SendableItemMetadata]()
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
                throw remoteErrorToThrow(readError)
            }
            guard let metadatas else {
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
            throw NSFileProviderError(.noSuchItem)
        }

        guard let enumeratorArray = enumerator.allObjects as? [URL] else {
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
                    throw remoteErrorToThrow(createError)
                }
                remoteDirectoriesPaths.append(childRemoteUrl)

            } else if !childIsFolder {
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
                throw remoteErrorToThrow(readError)
            }
        }

        guard let bundleRootMetadata = dbManager.itemMetadata(
            ocId: self.itemIdentifier.rawValue
        ) else {
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
            return (modifiedItem, deleteError)
        }

        let ocId = modifiedItem.itemIdentifier.rawValue
        guard let dirtyMetadata = dbManager.itemMetadata(ocId: ocId) else {
            return (modifiedItem, NSFileProviderError(.cannotSynchronize))
        }
        let dirtyChildren = dbManager.childItems(directoryMetadata: dirtyMetadata)
        let dirtyItem = Item(
            metadata: dirtyMetadata,
            parentItemIdentifier: .trashContainer,
            account: account,
            remoteInterface: modifiedItem.remoteInterface
        )

        // The server may have renamed the trashed file so we need to scan the entire trash
        let (_, files, _, error) = await modifiedItem.remoteInterface.trashedItems(
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
            return (dirtyItem, error.fileProviderError)
        }

        guard let targetItemNKTrash = files.first(
            // It seems the server likes to return a fileId as the ocId for trash files, so let's
            // check for the fileId too
            where: { $0.ocId == modifiedItem.metadata.ocId ||
                     $0.fileId == modifiedItem.metadata.fileId })
        else {
            if #available(macOS 11.3, *) {
                return (dirtyItem, NSFileProviderError(.unsyncedEdits))
            } else {
                return (dirtyItem, NSFileProviderError(.syncAnchorExpired))
            }
        }

        var postDeleteMetadata = targetItemNKTrash.toItemMetadata(account: account)
        postDeleteMetadata.ocId = modifiedItem.itemIdentifier.rawValue
        dbManager.addItemMetadata(postDeleteMetadata)

        let postDeleteItem = Item(
            metadata: postDeleteMetadata,
            parentItemIdentifier: .trashContainer,
            account: account,
            remoteInterface: modifiedItem.remoteInterface
        )

        // Now we can directly update info on the child items
        var (_, childFiles, _, childError) = await modifiedItem.remoteInterface.enumerate(
            remotePath: postDeleteMetadata.serverUrl + "/" + postDeleteMetadata.fileName,
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
            return (postDeleteItem, childError.fileProviderError)
        }

        // Update state of child files
        childFiles.removeFirst() // This is the target path, already scanned
        for file in childFiles {
            var metadata = file.toItemMetadata()
            guard let original = dirtyChildren
                .filter({ $0.ocId == metadata.ocId || $0.fileId == metadata.fileId })
                .first
            else {
                continue
            }
            metadata.ocId = original.ocId // Give original id back
            dbManager.addItemMetadata(metadata)
        }

        return (postDeleteItem, nil)
    }

    private static func restoreFromTrash(
        _ modifiedItem: Item,
        account: Account,
        dbManager: FilesDatabaseManager,
        domain: NSFileProviderDomain?
    ) async -> (Item, Error?) {

        func finaliseRestore(target: NKFile) -> (Item, Error?) {
            let restoredItemMetadata = target.toItemMetadata()
            guard let parentItemIdentifier = dbManager.parentItemIdentifierFromMetadata(
                restoredItemMetadata
            ) else {
                return (modifiedItem, NSFileProviderError(.cannotSynchronize))
            }

            if restoredItemMetadata.directory {
                _ = dbManager.renameDirectoryAndPropagateToChildren(
                    ocId: restoredItemMetadata.ocId,
                    newServerUrl: restoredItemMetadata.serverUrl,
                    newFileName: restoredItemMetadata.fileName
                )
            }
            dbManager.addItemMetadata(restoredItemMetadata)

            return (Item(
                metadata: restoredItemMetadata,
                parentItemIdentifier: parentItemIdentifier,
                account: account,
                remoteInterface: modifiedItem.remoteInterface
            ), nil)
        }

        let (_, _, restoreError) = await modifiedItem.remoteInterface.restoreFromTrash(
            filename: modifiedItem.metadata.fileName,
            account: account,
            options: .init(),
            taskHandler: { _ in }
        )
        guard restoreError == .success else {
            return (modifiedItem, restoreError.fileProviderError)
        }
        guard modifiedItem.metadata.trashbinOriginalLocation != "" else {
            if #available(macOS 11.3, *) {
                return (modifiedItem, NSFileProviderError(.unsyncedEdits))
            }
            return (modifiedItem, NSFileProviderError(.cannotSynchronize))
        }
        let originalLocation =
            account.davFilesUrl + "/" + modifiedItem.metadata.trashbinOriginalLocation

        let (_, files, _, enumerateError) = await modifiedItem.remoteInterface.enumerate(
            remotePath: originalLocation,
            depth: .target,
            showHiddenFiles: true,
            includeHiddenFiles: [],
            requestBody: nil,
            account: account,
            options: .init(),
            taskHandler: { _ in }
        )
        guard enumerateError == .success, !files.isEmpty, let target = files.first else {
            if #available(macOS 11.3, *) {
                return (modifiedItem, NSFileProviderError(.unsyncedEdits))
            }
            return (modifiedItem, enumerateError.fileProviderError)
        }

        guard target.ocId == modifiedItem.itemIdentifier.rawValue else {
            guard let finalSlashIndex = originalLocation.lastIndex(of: "/") else {
                return (modifiedItem, NSFileProviderError(.cannotSynchronize))
            }
            var parentDirectoryRemotePath = originalLocation
            parentDirectoryRemotePath.removeSubrange(finalSlashIndex..<originalLocation.endIndex)

            let (_, files, _, folderScanError) = await modifiedItem.remoteInterface.enumerate(
                remotePath: parentDirectoryRemotePath,
                depth: .targetAndDirectChildren,
                showHiddenFiles: true,
                includeHiddenFiles: [],
                requestBody: nil,
                account: account,
                options: .init(),
                taskHandler: { _ in }
            )

            guard folderScanError == .success else {
                return (modifiedItem, NSFileProviderError(.cannotSynchronize))
            }

            guard let actualTarget = files.first(
                where: { $0.ocId == modifiedItem.itemIdentifier.rawValue }
            ) else {
                return (modifiedItem, NSFileProviderError(.cannotSynchronize))
            }

            return finaliseRestore(target: actualTarget)
        }

        return finaliseRestore(target: target)
    }

    func modify(
        itemTarget: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion = NSFileProviderItemVersion(),
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest = NSFileProviderRequest(),
        domain: NSFileProviderDomain? = nil,
        forcedChunkSize: Int? = nil,
        progress: Progress = .init(),
        dbManager: FilesDatabaseManager = .shared
    ) async -> (Item?, Error?) {
        var modifiedItem = self

        let ocId = modifiedItem.itemIdentifier.rawValue
        guard itemTarget.itemIdentifier == modifiedItem.itemIdentifier else {
            return (nil, NSFileProviderError(.noSuchItem))
        }

        let newParentItemIdentifier = itemTarget.parentItemIdentifier
        let isFolder = modifiedItem.contentType.conforms(to: .directory)
        let bundleOrPackage =
            modifiedItem.contentType.conforms(to: .bundle) ||
            modifiedItem.contentType.conforms(to: .package)

        if options.contains(.mayAlreadyExist) {
            // TODO: This needs to be properly handled with a check in the db
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
                return (nil, NSFileProviderError(.noSuchItem))
            }

            newParentItemRemoteUrl = parentItemMetadata.serverUrl + "/" + parentItemMetadata.fileName
        }

        let newServerUrlFileName = newParentItemRemoteUrl + "/" + itemTarget.filename

        if changedFields.contains(.parentItemIdentifier)
            && newParentItemIdentifier == .trashContainer
            && modifiedItem.metadata.isTrashed {

            if (changedFields.contains(.filename)) {
            }

            return (modifiedItem, nil)
        } else if changedFields.contains(.parentItemIdentifier) && newParentItemIdentifier == .trashContainer {
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
                    modifiedItem, account: account, dbManager: dbManager, domain: domain
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
            return (modifiedItem, nil)
        }

        guard newParentItemIdentifier != .trashContainer else {
            return (modifiedItem, nil)
        }

        if changedFields.contains(.contents) {
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
                return (nil, contentError)
            }

            modifiedItem = contentModifiedItem
        }

        return (modifiedItem, nil)
    }
}
