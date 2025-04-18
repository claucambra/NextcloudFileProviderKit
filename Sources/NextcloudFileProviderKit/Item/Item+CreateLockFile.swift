//
//  Item+CreateLockFile.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 17/4/25.
//

import FileProvider
import NextcloudCapabilitiesKit

extension Item {
    static func createLockFile(
        basedOn itemTemplate: NSFileProviderItem,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        parentItemRemotePath: String,
        progress: Progress,
        domain: NSFileProviderDomain? = nil,
        account: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager
    ) async -> (Item?, Error?) {
        progress.totalUnitCount = 1

        // Lock but don't upload, do not error
        let (_, capabilitiesData, capabilitiesError) = await remoteInterface.fetchCapabilities(
            account: account,
            options: .init(),
            taskHandler: { task in
                if let domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: itemTemplate.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }
        )
        guard capabilitiesError == .success,
              let capabilitiesData,
              let capabilities = Capabilities(data: capabilitiesData),
              capabilities.files?.locking != nil
        else {
            uploadLogger.info(
                """
                Received nil capabilities data.
                    Received error: \(capabilitiesError.errorDescription, privacy: .public)
                    Will not proceed with locking for \(itemTemplate.filename, privacy: .public)
                """
            )
            return (nil, nil)
        }

        Self.logger.info(
            """
            Item to create:
                \(itemTemplate.filename)
                is a lock file. Will handle by remotely locking the target file.
            """
        )
        guard let targetFileName = originalFileName(
            fromLockFileName: itemTemplate.filename
        ) else {
            Self.logger.error(
                """
                Could not get original filename from lock file filename
                    \(itemTemplate.filename, privacy: .public)
                    so will not lock target file.
                """
            )
            return (nil, nil)
        }
        let (_, _, error) = await remoteInterface.setLockStateForFile(
            remotePath: parentItemRemotePath + "/" + targetFileName,
            lock: true,
            account: account,
            options: .init(),
            taskHandler: { task in
                if let domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: itemTemplate.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }
        )
        if error != .success {
            Self.logger.error(
                """
                Failed to lock target file \(targetFileName, privacy: .public)
                    for lock file: \(itemTemplate.filename, privacy: .public)
                    received error: \(error.errorDescription)
                """
            )
        }

        let metadata = SendableItemMetadata(
            ocId: itemTemplate.itemIdentifier.rawValue,
            account: account.ncKitAccount,
            classFile: "lock", // Indicates this metadata is for a locked file
            contentType: itemTemplate.contentType?.preferredMIMEType ?? "",
            creationDate: itemTemplate.creationDate as? Date ?? Date(),
            date: Date(),
            directory: false,
            e2eEncrypted: false,
            etag: "",
            fileId: itemTemplate.itemIdentifier.rawValue,
            fileName: itemTemplate.filename,
            fileNameView: itemTemplate.filename,
            hasPreview: false,
            iconName: "lockIcon", // Custom icon for locked items
            mountType: "",
            ownerId: account.id,
            ownerDisplayName: "",
            path: parentItemRemotePath + "/" + targetFileName,
            serverUrl: parentItemRemotePath,
            size: 0,
            status: Status.normal.rawValue,
            downloaded: true,
            uploaded: false,
            urlBase: account.serverUrl,
            user: account.username,
            userId: account.id
        )
        dbManager.addItemMetadata(metadata)

        progress.completedUnitCount = 1

        return (
            Item(
                metadata: metadata,
                parentItemIdentifier: parentItemIdentifier,
                account: account,
                remoteInterface: remoteInterface,
                dbManager: dbManager
            ),
            error.fileProviderError
        )
    }
}
