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
import Foundation
import RealmSwift

fileprivate let stable1_0SchemaVersion: UInt64 = 100
fileprivate let stable2_0SchemaVersion: UInt64 = 200 // Major change: deleted LocalFileMetadata type

public final class FilesDatabaseManager: Sendable {
    public static let shared = FilesDatabaseManager()!

    private static let relativeDatabaseFolderPath = "Database/"
    private static let databaseFilename = "fileproviderextdatabase.realm"
    private static let schemaVersion = stable2_0SchemaVersion

    var itemMetadatas: Results<RealmItemMetadata> { ncDatabase().objects(RealmItemMetadata.self) }

    public init(realmConfig: Realm.Configuration = Realm.Configuration.defaultConfiguration) {
        Realm.Configuration.defaultConfiguration = realmConfig

        do {
            _ = try Realm()
        } catch {
        }
    }

    public convenience init?() {
        let relativeDatabaseFilePath = Self.relativeDatabaseFolderPath + Self.databaseFilename
        guard let fileProviderDataDirUrl = pathForFileProviderExtData() else { return nil }
        let databasePath = fileProviderDataDirUrl.appendingPathComponent(relativeDatabaseFilePath)

        // Disable file protection for directory DB
        // https://docs.mongodb.com/realm/sdk/ios/examples/configure-and-open-a-realm/
        let dbFolder = fileProviderDataDirUrl.appendingPathComponent(
            Self.relativeDatabaseFolderPath
        )
        let dbFolderPath = dbFolder.path
        do {
            try FileManager.default.createDirectory(at: dbFolder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: dbFolderPath
            )
        } catch {
        }

        let config = Realm.Configuration(
            fileURL: databasePath,
            schemaVersion: Self.schemaVersion,
            migrationBlock: { migration, oldSchemaVersion in
                if oldSchemaVersion == stable1_0SchemaVersion {
                    var localFileMetadataOcIds = Set<String>()
                    migration.enumerateObjects(ofType: "LocalFileMetadata") { oldObject, _ in
                        guard let oldObject, let lfmOcId = oldObject["ocId"] as? String else {
                            return
                        }
                        localFileMetadataOcIds.insert(lfmOcId)
                    }

                    migration.enumerateObjects(ofType: RealmItemMetadata.className()) { _, newObject in
                        guard let newObject,
                              let imOcId = newObject["ocId"] as? String,
                              localFileMetadataOcIds.contains(imOcId)
                        else { return }
                        newObject["downloaded"] = true
                        newObject["uploaded"] = true
                    }
                }

            },
            objectTypes: [RealmItemMetadata.self, RemoteFileChunk.self]
        )
        self.init(realmConfig: config)
    }

    func ncDatabase() -> Realm {
        let realm = try! Realm()
        realm.refresh()
        return realm
    }

    public func anyItemMetadatasForAccount(_ account: String) -> Bool {
        !itemMetadatas.where({ $0.account == account }).isEmpty
    }

    public func itemMetadata(ocId: String) -> SendableItemMetadata? {
        // Realm objects are live-fire, i.e. they will be changed and invalidated according to
        // changes in the db.
        //
        // Let's therefore create a copy
        if let itemMetadata = itemMetadatas.where({ $0.ocId == ocId }).first {
            return SendableItemMetadata(value: itemMetadata)
        }
        return nil
    }

    public func itemMetadata(
        account: String, locatedAtRemoteUrl remoteUrl: String // Is the URL for the actual item
    ) -> SendableItemMetadata? {
        guard let actualRemoteUrl = URL(string: remoteUrl) else { return nil }
        let fileName = actualRemoteUrl.lastPathComponent
        guard var serverUrl = actualRemoteUrl
            .deletingLastPathComponent()
            .absoluteString
            .removingPercentEncoding
        else { return nil }
        if serverUrl.hasSuffix("/") {
            serverUrl.removeLast()
        }
        if let metadata = itemMetadatas.where({
            $0.account == account && $0.serverUrl == serverUrl && $0.fileName == fileName
        }).first {
            return SendableItemMetadata(value: metadata)
        }
        return nil
    }

    public func itemMetadatas(account: String) -> [SendableItemMetadata] {
        itemMetadatas
            .where { $0.account == account }
            .toUnmanagedResults()
    }

    public func itemMetadatas(
        account: String, underServerUrl serverUrl: String
    ) -> [SendableItemMetadata] {
        itemMetadatas
            .where { $0.account == account && $0.serverUrl.starts(with: serverUrl) }
            .toUnmanagedResults()
    }

    public func itemMetadataFromFileProviderItemIdentifier(
        _ identifier: NSFileProviderItemIdentifier
    ) -> SendableItemMetadata? {
        itemMetadata(ocId: identifier.rawValue)
    }

    private func processItemMetadatasToDelete(
        existingMetadatas: Results<RealmItemMetadata>,
        updatedMetadatas: [SendableItemMetadata]
    ) -> [RealmItemMetadata] {
        var deletedMetadatas: [RealmItemMetadata] = []

        for existingMetadata in existingMetadatas {
            guard !updatedMetadatas.contains(where: { $0.ocId == existingMetadata.ocId }),
                  let metadataToDelete = itemMetadatas.where({ $0.ocId == existingMetadata.ocId }).first
            else { continue }

            deletedMetadatas.append(metadataToDelete)

        }

        return deletedMetadatas
    }

    private func processItemMetadatasToUpdate(
        existingMetadatas: Results<RealmItemMetadata>,
        updatedMetadatas: [SendableItemMetadata],
        updateDirectoryEtags: Bool
    ) -> (
        newMetadatas: [SendableItemMetadata],
        updatedMetadatas: [SendableItemMetadata],
        directoriesNeedingRename: [SendableItemMetadata]
    ) {
        var returningNewMetadatas: [SendableItemMetadata] = []
        var returningUpdatedMetadatas: [SendableItemMetadata] = []
        var directoriesNeedingRename: [SendableItemMetadata] = []

        for var updatedMetadata in updatedMetadatas {
            if let existingMetadata = existingMetadatas.first(where: {
                $0.ocId == updatedMetadata.ocId
            }) {
                if existingMetadata.status == Status.normal.rawValue,
                    !existingMetadata.isInSameDatabaseStoreableRemoteState(updatedMetadata)
                {
                    if updatedMetadata.directory {
                        if updatedMetadata.serverUrl != existingMetadata.serverUrl
                            || updatedMetadata.fileName != existingMetadata.fileName
                        {
                            directoriesNeedingRename.append(updatedMetadata)
                            updatedMetadata.etag = ""  // Renaming doesn't change the etag so reset

                        } else if !updateDirectoryEtags {
                            updatedMetadata.etag = existingMetadata.etag
                        }
                    }

                    returningUpdatedMetadatas.append(updatedMetadata)

                } else {
                }

            } else {  // This is a new metadata
                if !updateDirectoryEtags, updatedMetadata.directory {
                    updatedMetadata.etag = ""
                }

                returningNewMetadatas.append(updatedMetadata)

            }
        }

        return (returningNewMetadatas, returningUpdatedMetadatas, directoriesNeedingRename)
    }

    public func updateItemMetadatas(
        account: String,
        serverUrl: String,
        updatedMetadatas: [SendableItemMetadata],
        updateDirectoryEtags: Bool
    ) -> (
        newMetadatas: [SendableItemMetadata]?,
        updatedMetadatas: [SendableItemMetadata]?,
        deletedMetadatas: [SendableItemMetadata]?
    ) {
        let database = ncDatabase()

        do {
            let existingMetadatas = database
                .objects(RealmItemMetadata.self)
                .where {
                    $0.account == account &&
                    $0.serverUrl == serverUrl &&
                    $0.status == Status.normal.rawValue
                }

            // NOTE: These metadatas are managed -- be careful!
            let metadatasToDelete = processItemMetadatasToDelete(
                existingMetadatas: existingMetadatas,
                updatedMetadatas: updatedMetadatas)
            let metadatasToDeleteCopy = metadatasToDelete.map { SendableItemMetadata(value: $0) }

            let metadatasToChange = processItemMetadatasToUpdate(
                existingMetadatas: existingMetadatas,
                updatedMetadatas: updatedMetadatas,
                updateDirectoryEtags: updateDirectoryEtags)

            var metadatasToUpdate = metadatasToChange.updatedMetadatas
            let metadatasToCreate = metadatasToChange.newMetadatas
            let directoriesNeedingRename = metadatasToChange.directoriesNeedingRename

            for metadata in directoriesNeedingRename {
                if let updatedDirectoryChildren = renameDirectoryAndPropagateToChildren(
                    ocId: metadata.ocId, 
                    newServerUrl: metadata.serverUrl,
                    newFileName: metadata.fileName)
                {
                    metadatasToUpdate += updatedDirectoryChildren
                }
            }

            try database.write {
                database.delete(metadatasToDelete)
                database.add(metadatasToUpdate.map { RealmItemMetadata(value: $0) }, update: .modified)
                database.add(metadatasToCreate.map { RealmItemMetadata(value: $0) }, update: .all)
            }

            return (metadatasToCreate, metadatasToUpdate, metadatasToDeleteCopy)
        } catch {
            return (nil, nil, nil)
        }
    }

    // If setting a downloading or uploading status, also modified the relevant boolean properties
    // of the item metadata object
    public func setStatusForItemMetadata(
        _ metadata: SendableItemMetadata, status: Status
    ) -> SendableItemMetadata? {
        guard let result = itemMetadatas.where({ $0.ocId == metadata.ocId }).first else {
            return nil
        }
        
        do {
            let database = ncDatabase()
            try database.write {
                result.status = status.rawValue
                if result.isDownload {
                    result.downloaded = false
                } else if result.isUpload {
                    result.uploaded = false
                    result.chunkUploadId = UUID().uuidString
                } else if status == .normal, metadata.isUpload {
                    result.chunkUploadId = nil
                }

            }
            return SendableItemMetadata(value: result)
        } catch {
        }
        
        return nil
    }

    public func addItemMetadata(_ metadata: SendableItemMetadata) {
        let database = ncDatabase()

        do {
            try database.write {
                database.add(RealmItemMetadata(value: metadata), update: .all)
            }
        } catch {
        }
    }

    @discardableResult public func deleteItemMetadata(ocId: String) -> Bool {
        do {
            let results = itemMetadatas.where { $0.ocId == ocId }
            let database = ncDatabase()
            try database.write {
                database.delete(results)
            }
            return true
        } catch {
            return false
        }
    }

    public func renameItemMetadata(ocId: String, newServerUrl: String, newFileName: String) {
        guard let itemMetadata = itemMetadatas.where({ $0.ocId == ocId }).first else {
            return
        }

        do {
            let database = ncDatabase()
            try database.write {
                itemMetadata.fileName = newFileName
                itemMetadata.fileNameView = newFileName
                itemMetadata.serverUrl = newServerUrl

                database.add(itemMetadata, update: .all)

            }
        } catch {
        }
    }

    public func parentItemIdentifierFromMetadata(
        _ metadata: SendableItemMetadata
    ) -> NSFileProviderItemIdentifier? {
        let homeServerFilesUrl = metadata.urlBase + Account.webDavFilesUrlSuffix + metadata.userId
        let trashServerFilesUrl = metadata.urlBase + Account.webDavTrashUrlSuffix + metadata.userId + "/trash"

        if metadata.serverUrl == homeServerFilesUrl {
            return .rootContainer
        } else if metadata.serverUrl == trashServerFilesUrl {
            return .trashContainer
        }

        guard let itemParentDirectory = parentDirectoryMetadataForItem(metadata) else {
            return nil
        }

        if let parentDirectoryMetadata = itemMetadata(ocId: itemParentDirectory.ocId) {
            return NSFileProviderItemIdentifier(parentDirectoryMetadata.ocId)
        }

        return nil
    }
}
