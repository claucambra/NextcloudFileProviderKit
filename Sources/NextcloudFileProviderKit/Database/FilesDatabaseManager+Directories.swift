/*
 * Copyright (C) 2023 by Claudio Cambra <claudio.cambra@nextcloud.com>
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

extension FilesDatabaseManager {
    private func fullServerPathUrl(for metadata: any ItemMetadata) -> String {
        if metadata.ocId == NSFileProviderItemIdentifier.rootContainer.rawValue {
            metadata.serverUrl
        } else {
            metadata.serverUrl + "/" + metadata.fileName
        }
    }

    public func childItems(directoryMetadata: SendableItemMetadata) -> [SendableItemMetadata] {
        let directoryServerUrl = fullServerPathUrl(for: directoryMetadata)
        return itemMetadatas
            .where({ $0.serverUrl.starts(with: directoryServerUrl) })
            .toUnmanagedResults()
    }

    public func childItemCount(directoryMetadata: SendableItemMetadata) -> Int {
        let directoryServerUrl = fullServerPathUrl(for: directoryMetadata)
        return itemMetadatas
            .where({ $0.serverUrl.starts(with: directoryServerUrl) })
            .count
    }

    public func parentDirectoryMetadataForItem(
        _ itemMetadata: SendableItemMetadata
    ) -> SendableItemMetadata? {
        self.itemMetadata(
            account: itemMetadata.account, locatedAtRemoteUrl: itemMetadata.serverUrl
        )
    }

    public func directoryMetadata(ocId: String) -> SendableItemMetadata? {
        if let metadata = itemMetadatas.where({ $0.ocId == ocId && $0.directory }).first {
            return SendableItemMetadata(value: metadata)
        }

        return nil
    }

    // Deletes all metadatas related to the info of the directory provided
    public func deleteDirectoryAndSubdirectoriesMetadata(
        ocId: String
    ) -> [SendableItemMetadata]? {
        guard let directoryMetadata = itemMetadatas
            .where({ $0.ocId == ocId && $0.directory })
            .first
        else {
            return nil
        }

        let directoryMetadataCopy = SendableItemMetadata(value: directoryMetadata)
        let directoryOcId = directoryMetadata.ocId
        let directoryUrlPath = directoryMetadata.serverUrl + "/" + directoryMetadata.fileName
        let directoryAccount = directoryMetadata.account
        let directoryEtag = directoryMetadata.etag

        let database = ncDatabase()
        do {
            try database.write { database.delete(directoryMetadata) }
        } catch {
            return nil
        }

        var deletedMetadatas: [SendableItemMetadata] = [directoryMetadataCopy]

        let results = itemMetadatas.where {
            $0.account == directoryAccount && $0.serverUrl.starts(with: directoryUrlPath)
        }

        for result in results {
            let inactiveItemMetadata = SendableItemMetadata(value: result)
            do {
                try database.write { database.delete(result) }
                deletedMetadatas.append(inactiveItemMetadata)
            } catch {
            }
        }

        return deletedMetadatas
    }

    public func renameDirectoryAndPropagateToChildren(
        ocId: String, newServerUrl: String, newFileName: String
    ) -> [SendableItemMetadata]? {
        guard let directoryMetadata = itemMetadatas
            .where({ $0.ocId == ocId && $0.directory })
            .first
        else {
            return nil
        }

        let oldItemServerUrl = directoryMetadata.serverUrl
        let oldItemFilename = directoryMetadata.fileName
        let oldDirectoryServerUrl = oldItemServerUrl + "/" + oldItemFilename
        let newDirectoryServerUrl = newServerUrl + "/" + newFileName
        let childItemResults = itemMetadatas.where {
            $0.account == directoryMetadata.account &&
            $0.serverUrl.starts(with: oldDirectoryServerUrl)
        }

        renameItemMetadata(ocId: ocId, newServerUrl: newServerUrl, newFileName: newFileName)

        do {
            let database = ncDatabase()
            try database.write {
                for childItem in childItemResults {
                    let oldServerUrl = childItem.serverUrl
                    let movedServerUrl = oldServerUrl.replacingOccurrences(
                        of: oldDirectoryServerUrl, with: newDirectoryServerUrl)
                    childItem.serverUrl = movedServerUrl
                    database.add(childItem, update: .all)
                }
            }
        } catch {
            return nil
        }

        return itemMetadatas
            .where {
                $0.account == directoryMetadata.account &&
                $0.serverUrl.starts(with: newDirectoryServerUrl)
            }
            .toUnmanagedResults()
    }
}
