//
//  ItemMetadata+Array.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-23.
//

import Foundation

extension Array<SendableItemMetadata> {
    func toFileProviderItems(
        account: Account, remoteInterface: RemoteInterface, dbManager: FilesDatabaseManager
    ) async -> [Item] {
        return await concurrentChunkedCompactMap { itemMetadata in
            guard !itemMetadata.e2eEncrypted else {
                return nil
            }

            if let parentItemIdentifier = dbManager.parentItemIdentifierFromMetadata(
                itemMetadata
            ) {
                let item = Item(
                    metadata: itemMetadata,
                    parentItemIdentifier: parentItemIdentifier,
                    account: account,
                    remoteInterface: remoteInterface
                )
                return item
            } else {
            }
            return nil
        }
    }
}
