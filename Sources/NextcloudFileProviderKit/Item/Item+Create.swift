//
//  Item+Create.swift
//
//
//  Created by Claudio Cambra on 16/4/24.
//

import FileProvider
import Foundation
import NextcloudKit

extension Item {
    
    private static func createNewFolder(
        itemTemplate: NSFileProviderItem?,
        remotePath: String,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        domain: NSFileProviderDomain? = nil,
        account: Account,
        remoteInterface: RemoteInterface,
        progress: Progress,
        dbManager: FilesDatabaseManager
    ) async -> (Item?, Error?) {

        let (_, _, _, createError) = await remoteInterface.createFolder(
            remotePath: remotePath, account: account, options: .init(), taskHandler: { task in
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
            account: account,
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
            return (nil, readError.fileProviderError)
        }
        
        guard let (directoryMetadata, _, _) = await files.toDirectoryReadMetadatas(account: account)
        else {
            return (nil, NSFileProviderError(.noSuchItem))
        }
        dbManager.addItemMetadata(directoryMetadata)

        let fpItem = Item(
            metadata: directoryMetadata,
            parentItemIdentifier: parentItemIdentifier,
            account: account,
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
        account: Account,
        remoteInterface: RemoteInterface,
        forcedChunkSize: Int?,
        progress: Progress,
        dbManager: FilesDatabaseManager
    ) async -> (Item?, Error?) {
        let chunkUploadId =
            itemTemplate.itemIdentifier.rawValue.replacingOccurrences(of: "/", with: "")
        let (ocId, _, etag, date, size, _, error) = await upload(
            fileLocatedAt: localPath,
            toRemotePath: remotePath,
            usingRemoteInterface: remoteInterface,
            withAccount: account,
            inChunksSized: forcedChunkSize,
            usingChunkUploadId: chunkUploadId,
            dbManager: dbManager,
            creationDate: itemTemplate.creationDate as? Date,
            modificationDate: itemTemplate.contentModificationDate as? Date,
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
            return (
                nil,
                error.matchesCollisionError ?
                    NSFileProviderError(.filenameCollision) : error.fileProviderError
            )
        }
        
        if let expectedSize = itemTemplate.documentSize??.int64Value, size != expectedSize {
        }
        
        let newMetadata = SendableItemMetadata(
            ocId: ocId,
            account: account.ncKitAccount,
            classFile: "", // Placeholder as not set in original code
            contentType: itemTemplate.contentType?.preferredMIMEType ?? "",
            creationDate: Date(), // Default as not set in original code
            date: date ?? Date(),
            directory: false,
            e2eEncrypted: false, // Default as not set in original code
            etag: etag ?? "",
            fileId: "", // Placeholder as not set in original code
            fileName: itemTemplate.filename,
            fileNameView: itemTemplate.filename,
            hasPreview: false, // Default as not set in original code
            iconName: "", // Placeholder as not set in original code
            mountType: "", // Placeholder as not set in original code
            ownerId: "", // Placeholder as not set in original code
            ownerDisplayName: "", // Placeholder as not set in original code
            path: "", // Placeholder as not set in original code
            serverUrl: parentItemRemotePath,
            size: size ?? 0,
            status: Status.normal.rawValue,
            downloaded: true,
            uploaded: true,
            urlBase: "", // Placeholder as not set in original code
            user: "", // Placeholder as not set in original code
            userId: "" // Placeholder as not set in original code
        )

        dbManager.addItemMetadata(newMetadata)
        
        let fpItem = Item(
            metadata: newMetadata,
            parentItemIdentifier: itemTemplate.parentItemIdentifier,
            account: account,
            remoteInterface: remoteInterface
        )
        
        return (fpItem, nil)
    }

    @discardableResult private static func createBundleOrPackageInternals(
        rootItem: Item,
        contents: URL,
        remotePath: String,
        domain: NSFileProviderDomain? = nil,
        account: Account,
        remoteInterface: RemoteInterface,
        forcedChunkSize: Int?,
        progress: Progress,
        dbManager: FilesDatabaseManager
    ) async throws -> Item? {
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

        func remoteErrorToThrow(_ error: NKError) -> Error {
            if error.matchesCollisionError {
                return NSFileProviderError(.filenameCollision)
            } else if let error = error.fileProviderError {
                return error
            } else {
                return NSFileProviderError(.cannotSynchronize)
            }
        }

        let contentsPath = contents.path
        let privatePrefix = "/private"
        let privateContentsPath = contentsPath.hasPrefix(privatePrefix)
        var remoteDirectoriesPaths = [remotePath]

        // Add one more total unit count to signify final reconciliation of bundle creation process
        progress.totalUnitCount = Int64(enumeratorArray.count) + 1

        for childUrl in enumeratorArray {
            var childUrlPath = childUrl.path
            if childUrlPath.hasPrefix(privatePrefix), !privateContentsPath {
                childUrlPath.removeFirst(privatePrefix.count)
            }
            let childRelativePath = childUrlPath.replacingOccurrences(of: contents.path, with: "")
            let childRemoteUrl = remotePath + childRelativePath
            let childUrlAttributes = try childUrl.resourceValues(forKeys: attributesToFetch)

            if childUrlAttributes.isDirectory ?? false {
                let (_, _, _, createError) = await remoteInterface.createFolder(
                    remotePath: childRemoteUrl,
                    account: account,
                    options: .init(), taskHandler: { task in
                        if let domain {
                            NSFileProviderManager(for: domain)?.register(
                                task,
                                forItemWithIdentifier: rootItem.itemIdentifier,
                                completionHandler: { _ in }
                            )
                        }
                    }
                )

                // As with the creating of the bundle's root folder, we do not want to abort on fail
                // as we might have faced an error creating some other internal content and we want
                // to retry all of its contents
                guard createError == .success || createError.matchesCollisionError else {
                    throw remoteErrorToThrow(createError)
                }
                remoteDirectoriesPaths.append(childRemoteUrl)

            } else {
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
                                forItemWithIdentifier: rootItem.itemIdentifier,
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
            progress.completedUnitCount += 1
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
            account: account.ncKitAccount, locatedAtRemoteUrl: remotePath
        ) else {
            throw NSFileProviderError(.noSuchItem)
        }

        progress.completedUnitCount += 1

        return Item(
            metadata: bundleRootMetadata,
            parentItemIdentifier: rootItem.parentItemIdentifier,
            account: account,
            remoteInterface: remoteInterface
        )
    }

    public static func create(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields = NSFileProviderItemFields(),
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest = NSFileProviderRequest(),
        domain: NSFileProviderDomain? = nil,
        account: Account,
        remoteInterface: RemoteInterface,
        forcedChunkSize: Int? = nil,
        progress: Progress,
        dbManager: FilesDatabaseManager = .shared
    ) async -> (Item?, Error?) {
        let tempId = itemTemplate.itemIdentifier.rawValue
        
        guard itemTemplate.contentType != .symbolicLink else {
            return (nil, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        }
        
        if options.contains(.mayAlreadyExist) {
            // TODO: This needs to be properly handled with a check in the db
            return (nil, NSFileProviderError(.noSuchItem))
        }
        
        let parentItemIdentifier = itemTemplate.parentItemIdentifier
        var parentItemRemotePath: String
        
        // TODO: Deduplicate
        if parentItemIdentifier == .rootContainer {
            parentItemRemotePath = account.davFilesUrl
        } else {
            guard let parentItemMetadata = dbManager.directoryMetadata(
                ocId: parentItemIdentifier.rawValue
            ) else {
                return (nil, NSFileProviderError(.noSuchItem))
            }
            parentItemRemotePath = parentItemMetadata.serverUrl + "/" + parentItemMetadata.fileName
        }
        
        let fileNameLocalPath = url?.path ?? ""
        let newServerUrlFileName = parentItemRemotePath + "/" + itemTemplate.filename
        let itemTemplateIsFolder = itemTemplate.contentType?.conforms(to: .directory) ?? false

        guard !itemTemplateIsFolder else {
            let isBundleOrPackage =
                itemTemplate.contentType?.conforms(to: .bundle) == true ||
                itemTemplate.contentType?.conforms(to: .package) == true

            var (item, error) = await Self.createNewFolder(
                itemTemplate: itemTemplate,
                remotePath: newServerUrlFileName,
                parentItemIdentifier: parentItemIdentifier,
                domain: domain,
                account: account,
                remoteInterface: remoteInterface,
                progress: isBundleOrPackage ? Progress() : progress,
                dbManager: dbManager
            )

            guard isBundleOrPackage else {
                return (item, error)
            }

            // Ignore collision errors as we might have faced an error creating one of the bundle's
            // internal files or folders and we want to retry all of its contents
            let fpErrorCode = (error as? NSFileProviderError)?.code
            guard error == nil || fpErrorCode == .filenameCollision else {
                return (item, error)
            }

            if item == nil {
                let (metadatas, _, _, _, readError) = await Enumerator.readServerUrl(
                    newServerUrlFileName,
                    account: account,
                    remoteInterface: remoteInterface,
                    dbManager: dbManager,
                    domain: domain,
                    depth: .target
                )

                if let readError, readError != .success {
                    return (nil, readError.fileProviderError)
                }
                guard let itemMetadata = metadatas?.first else {
                    return (nil, NSFileProviderError(.noSuchItem))
                }

                item = Item(
                    metadata: itemMetadata,
                    parentItemIdentifier: parentItemIdentifier,
                    account: account,
                    remoteInterface: remoteInterface
                )
            }

            guard let item = item else {
                return (nil, NSFileProviderError(.noSuchItem))
            }

            guard let url else {
                return (nil, NSFileProviderError(.noSuchItem))
            }

            // Bundles and packages are given to us as if they were files -- i.e. we don't get
            // notified about internal changes. So we need to manually handle their internal
            // contents
            do {
                return (try await Self.createBundleOrPackageInternals(
                    rootItem: item,
                    contents: url,
                    remotePath: newServerUrlFileName,
                    domain: domain,
                    account: account,
                    remoteInterface: remoteInterface,
                    forcedChunkSize: forcedChunkSize,
                    progress: progress,
                    dbManager: dbManager
                ), nil)
            } catch {
                return (nil, error)
            }
        }
        
        
        return await Self.createNewFile(
            remotePath: newServerUrlFileName,
            localPath: fileNameLocalPath,
            itemTemplate: itemTemplate,
            parentItemRemotePath: parentItemRemotePath,
            domain: domain,
            account: account,
            remoteInterface: remoteInterface,
            forcedChunkSize: forcedChunkSize,
            progress: progress,
            dbManager: dbManager
        )
    }
}
