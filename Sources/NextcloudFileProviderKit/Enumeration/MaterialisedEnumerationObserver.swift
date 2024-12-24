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
import OSLog

public class MaterialisedEnumerationObserver: NSObject, NSFileProviderEnumerationObserver {
    static let logger = Logger(subsystem: Logger.subsystem, category: "materialisedobservation")
    public let ncKitAccount: String
    let dbManager: FilesDatabaseManager
    private let completionHandler: (_ deletedOcIds: Set<String>) -> Void
    private var allEnumeratedItemIds: Set<String> = .init()

    public required init(
        ncKitAccount: String,
        dbManager: FilesDatabaseManager = FilesDatabaseManager.shared,
        completionHandler: @escaping (_ deletedOcIds: Set<String>) -> Void
    ) {
        self.ncKitAccount = ncKitAccount
        self.dbManager = dbManager
        self.completionHandler = completionHandler
        super.init()
    }

    public func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        let updatedItemsIds = Array(updatedItems.map(\.itemIdentifier.rawValue))

        for updatedItemsId in updatedItemsIds {
            allEnumeratedItemIds.insert(updatedItemsId)
        }
    }

    public func finishEnumerating(upTo _: NSFileProviderPage?) {
        Self.logger.debug("Handling enumerated materialised items.")
        Self.handleEnumeratedItems(
            allEnumeratedItemIds,
            account: ncKitAccount,
            dbManager: dbManager,
            completionHandler: completionHandler
        )
    }

    public func finishEnumeratingWithError(_ error: Error) {
        Self.logger.error(
            "Ran into error when enumerating materialised items: \(error.localizedDescription, privacy: .public). Handling items enumerated so far"
        )
        Self.handleEnumeratedItems(
            allEnumeratedItemIds,
            account: ncKitAccount,
            dbManager: dbManager,
            completionHandler: completionHandler
        )
    }

    static func handleEnumeratedItems(
        _ itemIds: Set<String>,
        account: String,
        dbManager: FilesDatabaseManager,
        completionHandler: @escaping (_ deletedOcIds: Set<String>) -> Void
    ) {
        DispatchQueue.global(qos: .background).async {
            var noLongerMaterialisedIds = Set<String>()
            for localFile in dbManager.itemMetadatas(account: account).filter({ $0.downloaded }) {
                let localFileOcId = localFile.ocId
                guard itemIds.contains(localFileOcId) else {
                    noLongerMaterialisedIds.insert(localFileOcId)
                    continue
                }
            }

            DispatchQueue.main.async {
                Self.logger.info("Cleaning up local file metadatas for unmaterialised items")
                for itemId in noLongerMaterialisedIds {
                    guard let itemMetadata = dbManager.itemMetadata(ocId: itemId) else { continue }
                    let database = dbManager.ncDatabase()
                    do {
                        try database.write { itemMetadata.downloaded = false }
                    } catch let error {
                        Self.logger.error(
                            """
                            Error updating downloaded status for \(itemId, privacy: .public)
                                received error: \(error.localizedDescription)
                            """
                        )
                    }
                }

                completionHandler(noLongerMaterialisedIds)
            }
        }
    }
}
