//
//  Item+Create.swift
//
//
//  Created by Claudio Cambra on 16/4/24.
//

import FileProvider
import Foundation
import NextcloudKit
import OSLog

extension Item {
    
    private static func createNewFolder(
        itemTemplate: NSFileProviderItem?,
        remotePath: String,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        domain: NSFileProviderDomain? = nil,
        remoteInterface: RemoteInterface,
        progress: Progress
    ) async -> (Item?, Error?) {

        let (account, _, _, createError) = await remoteInterface.createFolder(
            remotePath: remotePath, options: .init(), taskHandler: { task in
                if let domain, let itemTemplate {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: itemTemplate.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }
        )

        guard createError == .success else {
            Self.logger.error(
                """
                Could not create new folder at: \(remotePath, privacy: .public),
                received error: \(createError.errorCode, privacy: .public)
                \(createError.errorDescription, privacy: .public)
                """
            )
            return (
                nil,
                createError.matchesCollisionError ?
                    NSFileProviderError(.filenameCollision) : createError.fileProviderError
            )
        }
        
        // Read contents after creation
        let (_, files, _, readError) = await remoteInterface.enumerate(
            remotePath: remotePath,
            depth: .target,
            showHiddenFiles: true,
            includeHiddenFiles: [],
            requestBody: nil,
            options: .init(),
            taskHandler: { task in
                if let domain, let itemTemplate {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: itemTemplate.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }
        )

        guard readError == .success else {
            Self.logger.error(
                """
                Could not read new folder at: \(remotePath, privacy: .public),
                received error: \(readError.errorCode, privacy: .public)
                \(readError.errorDescription, privacy: .public)
                """
            )
            return (nil, readError.fileProviderError)
        }
        
        let directoryMetadata = await withCheckedContinuation { continuation in
            ItemMetadata.metadatasFromDirectoryReadNKFiles(
                files, account: account
            ) { directoryMetadata, _, _ in
                continuation.resume(returning: directoryMetadata)
            }
        }
        
        FilesDatabaseManager.shared.addItemMetadata(directoryMetadata)
        
        let fpItem = Item(
            metadata: directoryMetadata,
            parentItemIdentifier: parentItemIdentifier,
            remoteInterface: remoteInterface
        )
        
        return (fpItem, nil)
    }
    
    private static func createNewFile(
        remotePath: String,
        localPath: String,
        itemTemplate: NSFileProviderItem,
        parentItemRemotePath: String,
        domain: NSFileProviderDomain? = nil,
        remoteInterface: RemoteInterface,
        progress: Progress
    ) async -> (Item?, Error?) {
        let (account, ocId, etag, date, size, _, _, error) = await remoteInterface.upload(
            remotePath: remotePath,
            localPath: localPath,
            creationDate: itemTemplate.creationDate as? Date,
            modificationDate: itemTemplate.contentModificationDate as? Date,
            options: .init(),
            requestHandler: { progress.setHandlersFromAfRequest($0) },
            taskHandler: { task in
                if let domain = domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: itemTemplate.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            },
            progressHandler: { $0.copyCurrentStateToProgress(progress) }
        )
        
        guard error == .success, let ocId else {
            Self.logger.error(
                """
                Could not upload item with filename: \(itemTemplate.filename, privacy: .public),
                received error: \(error.errorCode, privacy: .public)
                \(error.errorDescription, privacy: .public)
                received ocId: \(ocId ?? "empty", privacy: .public)
                """
            )
            return (
                nil,
                error.matchesCollisionError ?
                    NSFileProviderError(.filenameCollision) : error.fileProviderError
            )
        }
        
        Self.logger.info(
            """
            Successfully uploaded item with identifier: \(ocId, privacy: .public)
            filename: \(itemTemplate.filename, privacy: .public)
            ocId: \(ocId, privacy: .public)
            etag: \(etag ?? "", privacy: .public)
            date: \(date ?? NSDate(), privacy: .public)
            size: \(size, privacy: .public),
            account: \(account, privacy: .public)
            """
        )
        
        if size != itemTemplate.documentSize as? Int64 {
            Self.logger.warning(
                """
                Created item upload reported as successful, but there are differences between
                the received file size (\(size, privacy: .public))
                and the original file size (\(itemTemplate.documentSize??.int64Value ?? 0))
                """
            )
        }
        
        let newMetadata = ItemMetadata()
        newMetadata.date = (date ?? NSDate()) as Date
        newMetadata.etag = etag ?? ""
        newMetadata.account = account
        newMetadata.fileName = itemTemplate.filename
        newMetadata.fileNameView = itemTemplate.filename
        newMetadata.ocId = ocId
        newMetadata.size = size
        newMetadata.contentType = itemTemplate.contentType?.preferredMIMEType ?? ""
        newMetadata.directory = false
        newMetadata.serverUrl = parentItemRemotePath
        newMetadata.session = ""
        newMetadata.sessionError = ""
        newMetadata.sessionTaskIdentifier = 0
        newMetadata.status = ItemMetadata.Status.normal.rawValue
        
        let dbManager = FilesDatabaseManager.shared
        dbManager.addLocalFileMetadataFromItemMetadata(newMetadata)
        dbManager.addItemMetadata(newMetadata)
        
        let fpItem = Item(
            metadata: newMetadata,
            parentItemIdentifier: itemTemplate.parentItemIdentifier,
            remoteInterface: remoteInterface
        )
        
        return (fpItem, nil)
    }
    
    public static func create(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields = NSFileProviderItemFields(),
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest = NSFileProviderRequest(),
        domain: NSFileProviderDomain? = nil,
        remoteInterface: RemoteInterface,
        ncAccount: Account,
        progress: Progress
    ) async -> (Item?, Error?) {
        let tempId = itemTemplate.itemIdentifier.rawValue
        
        guard itemTemplate.contentType != .symbolicLink else {
            Self.logger.error(
                "Cannot create item \(tempId, privacy: .public), symbolic links not supported."
            )
            return (nil, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        }
        
        if options.contains(.mayAlreadyExist) {
            // TODO: This needs to be properly handled with a check in the db
            Self.logger.info(
                """
                Not creating item: \(itemTemplate.itemIdentifier.rawValue, privacy: .public)
                as it may already exist
                """
            )
            return (nil, NSFileProviderError(.noSuchItem))
        }
        
        let parentItemIdentifier = itemTemplate.parentItemIdentifier
        var parentItemRemotePath: String
        
        // TODO: Deduplicate
        if parentItemIdentifier == .rootContainer {
            parentItemRemotePath = ncAccount.davFilesUrl
        } else {
            guard let parentItemMetadata = FilesDatabaseManager.shared.directoryMetadata(
                ocId: parentItemIdentifier.rawValue
            ) else {
                Self.logger.error(
                    """
                    Not creating item: \(itemTemplate.itemIdentifier.rawValue, privacy: .public),
                    could not find metadata for parentItemIdentifier:
                        \(parentItemIdentifier.rawValue, privacy: .public)
                    """
                )
                return (nil, NSFileProviderError(.noSuchItem))
            }
            parentItemRemotePath = parentItemMetadata.serverUrl + "/" + parentItemMetadata.fileName
        }
        
        let fileNameLocalPath = url?.path ?? ""
        let newServerUrlFileName = parentItemRemotePath + "/" + itemTemplate.filename
        let itemTemplateIsFolder =
        itemTemplate.contentType == .folder || itemTemplate.contentType == .directory
        
        Self.logger.debug(
            """
            About to upload item with identifier: \(tempId, privacy: .public)
            of type: \(itemTemplate.contentType?.identifier ?? "UNKNOWN", privacy: .public)
            (is folder: \(itemTemplateIsFolder ? "yes" : "no", privacy: .public)
            and filename: \(itemTemplate.filename, privacy: .public)
            to server url: \(newServerUrlFileName, privacy: .public)
            with contents located at: \(fileNameLocalPath, privacy: .public)
            """
        )
        
        guard !itemTemplateIsFolder else  {
            return await Self.createNewFolder(
                itemTemplate: itemTemplate,
                remotePath: newServerUrlFileName,
                parentItemIdentifier: parentItemIdentifier,
                domain: domain,
                remoteInterface: remoteInterface,
                progress: progress
            )
        }
        
        
        return await Self.createNewFile(
            remotePath: newServerUrlFileName,
            localPath: fileNameLocalPath,
            itemTemplate: itemTemplate,
            parentItemRemotePath: parentItemRemotePath,
            domain: domain,
            remoteInterface: remoteInterface,
            progress: progress
        )
    }
}
