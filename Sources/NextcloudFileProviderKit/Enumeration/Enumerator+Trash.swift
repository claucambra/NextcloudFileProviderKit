//
//  Enumerator+Trash.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-02.
//

import FileProvider
import NextcloudKit

extension Enumerator {
    static func completeEnumerationObserver(
        _ observer: NSFileProviderEnumerationObserver,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        numPage: Int,
        trashItems: [NKTrash]
    ) {
        var metadatas = [ItemMetadata]()
        for trashItem in trashItems {
            let metadata = trashItem.toItemMetadata(account: remoteInterface.account)
            dbManager.addItemMetadata(metadata)
            metadatas.append(metadata)
        }

        Self.metadatasToFileProviderItems(
            metadatas, remoteInterface: remoteInterface, dbManager: dbManager
        ) { items in
            observer.didEnumerate(items)
            Self.logger.info("Did enumerate \(items.count) trash items")
            observer.finishEnumerating(upTo: fileProviderPageforNumPage(numPage))
        }
    }

    static func completeChangesObserver(
        _ observer: NSFileProviderChangeObserver,
        anchor: NSFileProviderSyncAnchor,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        trashItems: [NKTrash]
    ) {
        var newTrashedItems = [NSFileProviderItem]()

        // NKTrash items do not have an etag ; we assume they cannot be modified while they are in
        // the trash, so we will just check by ocId
        var existingTrashedItems =
            dbManager.trashedItemMetadatas(account: remoteInterface.account.ncKitAccount)

        for trashItem in trashItems {
            guard let existingTrashItemIndex = existingTrashedItems.firstIndex(
                where: { $0.ocId == trashItem.ocId }
            ) else { continue }

            existingTrashedItems.remove(at: existingTrashItemIndex)

            let metadata = trashItem.toItemMetadata(account: remoteInterface.account)
            dbManager.addItemMetadata(metadata)

            let item = Item(
                metadata: metadata,
                parentItemIdentifier: .trashContainer,
                remoteInterface: remoteInterface
            )
            newTrashedItems.append(item)

            Self.logger.debug(
                """
                Will enumerate trashed item with ocId: \(metadata.ocId, privacy: .public)
                and name: \(metadata.fileName, privacy: .public)
                """
            )
        }

        let deletedTrashedItemsIdentifiers = existingTrashedItems.map {
            NSFileProviderItemIdentifier($0.ocId)
        }
        if !deletedTrashedItemsIdentifiers.isEmpty {
            observer.didDeleteItems(withIdentifiers: deletedTrashedItemsIdentifiers)
        }

        if !newTrashedItems.isEmpty {
            observer.didUpdate(newTrashedItems)
        }
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
}