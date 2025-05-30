//
//  MockEnumerator.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-20.
//

import Foundation
import FileProvider
import NextcloudFileProviderKit

public class MockEnumerator: NSObject, NSFileProviderEnumerator {
    let account: Account
    let dbManager: FilesDatabaseManager
    let remoteInterface: MockRemoteInterface
    public var enumeratorItems: [SendableItemMetadata] = []

    public init(
        account: Account, dbManager: FilesDatabaseManager, remoteInterface: MockRemoteInterface
    ) {
        self.account = account
        self.dbManager = dbManager
        self.remoteInterface = remoteInterface
    }

    public func enumerateItems(
        for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        let remoteSupportsTrash = remoteInterface.directMockCapabilities()?.files?.undelete ?? false
        var items: [Item] = []
        for item in enumeratorItems {
            guard let parentItemIdentifier = dbManager.parentItemIdentifierFromMetadata(item) else {
                print("Could not get parent item identifier for \(item)")
                continue
            }
            let item = Item(
                metadata: item,
                parentItemIdentifier: parentItemIdentifier,
                account: account,
                remoteInterface: remoteInterface,
                dbManager: dbManager,
                remoteSupportsTrash: remoteSupportsTrash
            )
            items.append(item)
        }
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    public func invalidate() {
        print("MockEnumerator invalidated")
    }
}
