/*
 * Copyright (C) 2022 by Claudio Cambra <claudio.cambra@nextcloud.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

import FileProvider
import NextcloudKit
import UniformTypeIdentifiers
import OSLog

public class Item: NSObject, NSFileProviderItem {
    public enum FileProviderItemTransferError: Error {
        case downloadError
        case uploadError
    }

    lazy var dbManager: FilesDatabaseManager = .shared

    public let metadata: SendableItemMetadata
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let account: Account
    public let remoteInterface: RemoteInterface

    public var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(metadata.ocId)
    }

    public var capabilities: NSFileProviderItemCapabilities {
        guard !metadata.directory else {
            var directoryCapabilities: NSFileProviderItemCapabilities = [
                .allowsAddingSubItems,
                .allowsContentEnumerating,
                .allowsReading,
                .allowsDeleting,
                .allowsReparenting,
                .allowsRenaming,
                .allowsTrashing
            ]

            if #available(macOS 11.3, *) {
                directoryCapabilities.insert(.allowsExcludingFromSync)
            }

            // .allowsEvicting deprecated on macOS 13.0+, use contentPolicy instead
            if #unavailable(macOS 13.0) {
                directoryCapabilities.insert(.allowsEvicting)
            }
            return directoryCapabilities
        }
        guard !metadata.lock else {
            return [.allowsReading]
        }
        return [
            .allowsWriting,
            .allowsReading,
            .allowsDeleting,
            .allowsRenaming,
            .allowsReparenting,
            .allowsEvicting,
            .allowsTrashing
        ]
    }

    public var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: metadata.etag.data(using: .utf8)!,
            metadataVersion: metadata.etag.data(using: .utf8)!)
    }

    public var filename: String {
        metadata.isTrashed && !metadata.trashbinFileName.isEmpty ?
            metadata.trashbinFileName : !metadata.fileName.isEmpty ?
                metadata.fileName : "unnamed file"
    }

    public var contentType: UTType {
        if itemIdentifier == .rootContainer || (metadata.contentType.isEmpty && metadata.directory)
        {
            return .folder
        } else if metadata.contentType == "httpd/unix-directory", metadata.directory {
            let filenameComponents = filename.components(separatedBy: ".")
            if filenameComponents.count > 1, let ext = filenameComponents.last {
                return UTType(filenameExtension: ext, conformingTo: .directory) ?? .folder
            }
            return .folder
        } else if !metadata.contentType.isEmpty, let type = UTType(metadata.contentType) {
            return type
        }

        let filenameExtension = filename.components(separatedBy: ".").last ?? ""
        return UTType(filenameExtension: filenameExtension) ?? .content
    }

    public var documentSize: NSNumber? {
        NSNumber(value: metadata.size)
    }

    public var creationDate: Date? {
        metadata.creationDate as Date
    }

    public var lastUsedDate: Date? {
        metadata.date as Date
    }

    public var contentModificationDate: Date? {
        metadata.date as Date
    }

    public var isDownloaded: Bool {
        metadata.directory || metadata.downloaded
    }

    public var isDownloading: Bool {
        metadata.isDownload
    }

    public var downloadingError: Error? {
        if metadata.status == Status.downloadError.rawValue {
            return FileProviderItemTransferError.downloadError
        }
        return nil
    }

    public var isUploaded: Bool {
        metadata.uploaded
    }

    public var isUploading: Bool {
        metadata.isUpload
    }

    public var uploadingError: Error? {
        if metadata.status == Status.uploadError.rawValue {
            FileProviderItemTransferError.uploadError
        } else {
            nil
        }
    }

    public var childItemCount: NSNumber? {
        if metadata.directory {
            NSNumber(integerLiteral: dbManager.childItemCount(directoryMetadata: metadata))
        } else {
            nil
        }
    }

    public var fileSystemFlags: NSFileProviderFileSystemFlags {
        if metadata.lock,
           (metadata.lockOwnerType != 0 || metadata.lockOwner != account.username),
           metadata.lockTimeOut ?? Date() > Date()
        {
            return [.userReadable]
        }
        return [.userReadable, .userWritable]
    }

    public var userInfo: [AnyHashable : Any]? {
        var userInfoDict = [AnyHashable : Any]()
        if metadata.lock {
            // Can be used to display lock/unlock context menu entries for FPUIActions
            // Note that only files, not folders, should be lockable/unlockable
            userInfoDict["locked"] = metadata.lock
        }
        return userInfoDict
    }

    @available(macOS 13.0, *)
    public var contentPolicy: NSFileProviderContentPolicy {
        #if os(macOS)
        .downloadLazily
        #else
        .downloadLazilyAndEvictOnRemoteUpdate
        #endif
    }

    public static func rootContainer(account: Account, remoteInterface: RemoteInterface) -> Item {
        let metadata = SendableItemMetadata(
            ocId: NSFileProviderItemIdentifier.rootContainer.rawValue,
            account: account.ncKitAccount,
            classFile: NKCommon.TypeClassFile.directory.rawValue,
            contentType: "", // Placeholder as not set in original code
            creationDate: Date(), // Default as not set in original code
            date: Date(), // Default as not set in original code
            directory: true,
            e2eEncrypted: false, // Default as not set in original code
            etag: "", // Placeholder as not set in original code
            favorite: false, // Default as not set in original code
            fileId: "", // Placeholder as not set in original code
            fileName: "/",
            fileNameView: "/",
            hasPreview: false, // Default as not set in original code
            iconName: "", // Placeholder as not set in original code
            livePhoto: false, // Default as not set in original code
            mountType: "", // Placeholder as not set in original code
            name: "", // Placeholder as not set in original code
            note: "", // Placeholder as not set in original code
            ownerId: "", // Placeholder as not set in original code
            ownerDisplayName: "", // Placeholder as not set in original code
            path: "", // Placeholder as not set in original code
            permissions: "", // Placeholder as not set in original code
            quotaUsedBytes: 0, // Default as not set in original code
            quotaAvailableBytes: 0, // Default as not set in original code
            resourceType: "", // Placeholder as not set in original code
            richWorkspace: nil, // Default as not set in original code
            serverUrl: account.davFilesUrl,
            session: "", // Placeholder as not set in original code
            sessionError: "", // Placeholder as not set in original code
            sessionTaskIdentifier: 0, // Default as not set in original code
            sharePermissionsCollaborationServices: 0, // Default as not set in original code
            sharePermissionsCloudMesh: [], // Default as not set in original code
            size: 0, // Default as not set in original code
            urlBase: "", // Placeholder as not set in original code
            user: "", // Placeholder as not set in original code
            userId: "" // Placeholder as not set in original code
        )
        return Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: account,
            remoteInterface: remoteInterface
        )
    }

    public static func trashContainer(remoteInterface: RemoteInterface, account: Account) -> Item {
        let metadata = SendableItemMetadata(
            ocId: NSFileProviderItemIdentifier.trashContainer.rawValue,
            account: account.ncKitAccount,
            classFile: NKCommon.TypeClassFile.directory.rawValue,
            contentType: "", // Placeholder as not set in original code
            creationDate: Date(), // Default as not set in original code
            date: Date(), // Default as not set in original code
            directory: true,
            e2eEncrypted: false, // Default as not set in original code
            etag: "", // Placeholder as not set in original code
            favorite: false, // Default as not set in original code
            fileId: "", // Placeholder as not set in original code
            fileName: "Trash",
            fileNameView: "Trash",
            hasPreview: false, // Default as not set in original code
            iconName: "", // Placeholder as not set in original code
            livePhoto: false, // Default as not set in original code
            mountType: "", // Placeholder as not set in original code
            name: "", // Placeholder as not set in original code
            note: "", // Placeholder as not set in original code
            ownerId: "", // Placeholder as not set in original code
            ownerDisplayName: "", // Placeholder as not set in original code
            path: "", // Placeholder as not set in original code
            permissions: "", // Placeholder as not set in original code
            quotaUsedBytes: 0, // Default as not set in original code
            quotaAvailableBytes: 0, // Default as not set in original code
            resourceType: "", // Placeholder as not set in original code
            richWorkspace: nil, // Default as not set in original code
            serverUrl: account.trashUrl,
            session: "", // Placeholder as not set in original code
            sessionError: "", // Placeholder as not set in original code
            sessionTaskIdentifier: 0, // Default as not set in original code
            sharePermissionsCollaborationServices: 0, // Default as not set in original code
            sharePermissionsCloudMesh: [], // Default as not set in original code
            size: 0, // Default as not set in original code
            urlBase: "", // Placeholder as not set in original code
            user: "", // Placeholder as not set in original code
            userId: "" // Placeholder as not set in original code
        )
        return Item(
            metadata: metadata,
            parentItemIdentifier: .trashContainer,
            account: account,
            remoteInterface: remoteInterface
        )
    }

    static let logger = Logger(subsystem: Logger.subsystem, category: "item")

    public required init(
        metadata: SendableItemMetadata,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        account: Account,
        remoteInterface: RemoteInterface
    ) {
        self.metadata = metadata
        self.parentItemIdentifier = parentItemIdentifier
        self.account = account
        self.remoteInterface = remoteInterface
        super.init()
    }

    public static func storedItem(
        identifier: NSFileProviderItemIdentifier,
        account: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager = .shared
    ) -> Item? {
        // resolve the given identifier to a record in the model
        guard identifier != .rootContainer else {
            return Item.rootContainer(account: account, remoteInterface: remoteInterface)
        }
        guard identifier != .trashContainer else {
            return Item.trashContainer(remoteInterface: remoteInterface, account: account)
        }

        guard let metadata = dbManager.itemMetadataFromFileProviderItemIdentifier(identifier) else {
            return nil
        }

        var parentItemIdentifier: NSFileProviderItemIdentifier?
        if metadata.isTrashed {
            parentItemIdentifier = .trashContainer
        } else {
            parentItemIdentifier = dbManager.parentItemIdentifierFromMetadata(metadata)
        }
        guard let parentItemIdentifier else { return nil }

        return Item(
            metadata: metadata,
            parentItemIdentifier: parentItemIdentifier,
            account: account,
            remoteInterface: remoteInterface
        )
    }
}
