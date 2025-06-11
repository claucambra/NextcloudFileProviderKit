//
//  SendableItemMetadata+Array.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-23.
//

import Foundation

extension Array<SendableItemMetadata> {
    func toFileProviderItems(
        account: Account, remoteInterface: RemoteInterface, dbManager: FilesDatabaseManager
    ) async throws -> [Item] {
        let logger = NCFPKLogger(category: "itemMetadataToFileProviderItems")
        let remoteSupportsTrash = await remoteInterface.supportsTrash(account: account)

        return try await concurrentChunkedCompactMap { itemMetadata in
            guard !itemMetadata.e2eEncrypted else {
                logger.warning(
                    """
                    Skipping encrypted metadata in enumeration:
                        ocId: \(itemMetadata.ocId) fileName: \(itemMetadata.fileName)
                    """
                )
                return nil
            }

            guard !isLockFileName(itemMetadata.fileName) else {
                logger.warning(
                    """
                    Skipping remote lock file item metadata in enumeration:
                        ocId: \(itemMetadata.ocId) fileName: \(itemMetadata.fileName)
                    """
                )
                return nil
            }

            guard let parentItemIdentifier = dbManager.parentItemIdentifierFromMetadata(
                itemMetadata
            ) else {
                logger.error(
                    """
                    Could not get valid parentItemIdentifier for item with ocId:
                        \(itemMetadata.ocId) and name: \(itemMetadata.fileName)
                    """
                )
                let targetUrl = itemMetadata.serverUrl
                throw FilesDatabaseManager.parentMetadataNotFoundError(itemUrl: targetUrl)
            }
            let item = Item(
                metadata: itemMetadata,
                parentItemIdentifier: parentItemIdentifier,
                account: account,
                remoteInterface: remoteInterface,
                dbManager: dbManager,
                remoteSupportsTrash: remoteSupportsTrash
            )
            logger.debug(
                """
                Will enumerate item with ocId: \(itemMetadata.ocId)
                    and name: \(itemMetadata.fileName)
                """
            )

            return item
        }
    }
}
