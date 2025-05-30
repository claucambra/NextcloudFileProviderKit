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
        account: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        numPage: Int,
        trashItems: [NKTrash]
    ) {
        var metadatas = [SendableItemMetadata]()
        for trashItem in trashItems {
            let metadata = trashItem.toItemMetadata(account: account)
            dbManager.addItemMetadata(metadata)
            metadatas.append(metadata)
        }

        Task { [metadatas] in
            let items = await metadatas.toFileProviderItems(
                account: account, remoteInterface: remoteInterface, dbManager: dbManager
            )

            Task { @MainActor in
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: fileProviderPageforNumPage(numPage))
            }
        }
    }

    static func completeChangesObserver(
        _ observer: NSFileProviderChangeObserver,
        anchor: NSFileProviderSyncAnchor,
        account: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        trashItems: [NKTrash]
    ) {
        var newTrashedItems = [NSFileProviderItem]()

        // NKTrash items do not have an etag ; we assume they cannot be modified while they are in
        // the trash, so we will just check by ocId
        var existingTrashedItems = dbManager.trashedItemMetadatas(account: account)

        for trashItem in trashItems {
            if let existingTrashItemIndex = existingTrashedItems.firstIndex(
                where: { $0.ocId == trashItem.ocId }
            ) {
                existingTrashedItems.remove(at: existingTrashItemIndex)
                continue
            }

            let metadata = trashItem.toItemMetadata(account: account)
            dbManager.addItemMetadata(metadata)

            let item = Item(
                metadata: metadata,
                parentItemIdentifier: .trashContainer,
                account: account,
                remoteInterface: remoteInterface
            )
            newTrashedItems.append(item)

        }

        let deletedTrashedItemsIdentifiers = existingTrashedItems.map {
            NSFileProviderItemIdentifier($0.ocId)
        }
        if !deletedTrashedItemsIdentifiers.isEmpty {
            for itemIdentifier in deletedTrashedItemsIdentifiers {
                dbManager.deleteItemMetadata(ocId: itemIdentifier.rawValue)
            }
            observer.didDeleteItems(withIdentifiers: deletedTrashedItemsIdentifiers)
        }

        if !newTrashedItems.isEmpty {
            observer.didUpdate(newTrashedItems)
        }
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
}
