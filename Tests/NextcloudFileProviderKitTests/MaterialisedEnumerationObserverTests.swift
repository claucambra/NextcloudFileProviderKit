//
//  MaterialisedEnumerationObserverTests.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-20.
//

import FileProvider
import Foundation
import NextcloudKit
import NextcloudFileProviderKit
import RealmSwift
import TestInterface
import XCTest

final class MaterialisedEnumerationObserverTests: XCTestCase {
    static let account = Account(
        user: "testUser", id: "testUserId", serverUrl: "https://mock.nc.com", password: "abcd"
    )

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration.inMemoryIdentifier = name
    }

    func testMaterialisedObserverWithNoPreexistingState() async {
        let dbManager = FilesDatabaseManager(
            realmConfig: .defaultConfiguration, account: Self.account
        )
        // The database is intentionally left empty.

        let remoteInterface = MockRemoteInterface()

        let enumeratedFile =
            SendableItemMetadata(ocId: "file1", fileName: "file1.txt", account: Self.account)
        var enumeratedDir =
            SendableItemMetadata(ocId: "dir1", fileName: "dir1", account: Self.account)
        enumeratedDir.directory = true

        let expect = XCTestExpectation(description: "Enumerator completion handler called")

        // The observer's logic requires metadata to exist in the DB to update it.
        let observer = MaterialisedEnumerationObserver(
            ncKitAccount: Self.account.ncKitAccount, dbManager: dbManager
        ) { newlyMaterialisedIds, unmaterialisedIds in
            XCTAssertTrue(
                unmaterialisedIds.isEmpty,
                "Unmaterialised set should be empty when DB starts empty."
            )

            // The items are correctly identified as newly materialised because they weren't in the
            // DB's materialised list (which was empty).
            XCTAssertEqual(
                newlyMaterialisedIds.count,
                2,
                "Both enumerated items should be identified as newly materialised."
            )
            XCTAssertTrue(newlyMaterialisedIds.contains("file1"))
            XCTAssertTrue(newlyMaterialisedIds.contains("dir1"))

            // Verify that the database state is NOT updated
            let fileMetadata = dbManager.itemMetadata(ocId: "file1")
            XCTAssertNil(
                fileMetadata,
                "Metadata should NOT be in the DB, as the observer does not add missing items."
            )

            let dirMetadata = dbManager.itemMetadata(ocId: "dir1")
            XCTAssertNil(
                dirMetadata,
                "Metadata should NOT be in the DB, as the observer does not add missing items."
            )

            expect.fulfill()
        }

        let enumerator = MockEnumerator(
            account: Self.account, dbManager: dbManager, remoteInterface: remoteInterface
        )
        enumerator.enumeratorItems = [enumeratedFile, enumeratedDir]
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data(count: 1)))

        await fulfillment(of: [expect], timeout: 1)
    }

    func testMaterialisedObserverWithMixedState() async {
        // Setup a DB with a mix of materialised and non-materialised items.
        var itemA = SendableItemMetadata(ocId: "itemA", fileName: "itemA", account: Self.account)
        itemA.downloaded = true // Was materialised

        var itemB = SendableItemMetadata(ocId: "itemB", fileName: "itemB", account: Self.account)
        itemB.downloaded = false // Was NOT materialised

        var itemC = SendableItemMetadata(ocId: "itemC", fileName: "itemC", account: Self.account)
        itemC.downloaded = true // Was materialised

        var dirD = SendableItemMetadata(ocId: "dirD", fileName: "dirD", account: Self.account)
        dirD.directory = true
        dirD.visitedDirectory = true // Was materialised

        let dbManager = FilesDatabaseManager(
            realmConfig: .defaultConfiguration, account: Self.account
        )
        dbManager.addItemMetadata(itemA)
        dbManager.addItemMetadata(itemB)
        dbManager.addItemMetadata(itemC)
        dbManager.addItemMetadata(dirD)

        let remoteInterface = MockRemoteInterface()
        let expect = XCTestExpectation(description: "Enumerator completion handler called")
        let enumeratorItemsToReturn = [itemB, itemC]

        let observer = MaterialisedEnumerationObserver(
            ncKitAccount: Self.account.ncKitAccount, dbManager: dbManager
        ) { newlyMaterialisedIds, unmaterialisedIds in
            // Unmaterialised: itemA and dirD were materialised but not in the latest enumeration.
            XCTAssertEqual(
                unmaterialisedIds.count, 2, "itemA and dirD should be reported as unmaterialised."
            )
            XCTAssertTrue(unmaterialisedIds.contains("itemA"))
            XCTAssertTrue(unmaterialisedIds.contains("dirD"))

            // Newly Materialised: itemB was NOT materialised but WAS in the latest enumeration.
            XCTAssertEqual(
                newlyMaterialisedIds.count, 1, "itemB should be reported as newly materialised."
            )
            XCTAssertEqual(newlyMaterialisedIds.first, "itemB")

            // Check final database state
            let finalItemA = dbManager.itemMetadata(ocId: "itemA")
            XCTAssertFalse(
                finalItemA?.downloaded ?? true, "itemA should now be marked as not downloaded."
            )

            let finalItemB = dbManager.itemMetadata(ocId: "itemB")
            XCTAssertTrue(
                finalItemB?.downloaded ?? false, "itemB should now be marked as downloaded."
            )

            let finalItemC = dbManager.itemMetadata(ocId: "itemC")
            XCTAssertTrue(finalItemC?.downloaded ?? false, "itemC should remain downloaded.")

            let finalDirD = dbManager.itemMetadata(ocId: "dirD")
            XCTAssertFalse(
                finalDirD?.visitedDirectory ?? true, "dirD should now be marked as not visited."
            )

            expect.fulfill()
        }

        let enumerator = MockEnumerator(
            account: Self.account, dbManager: dbManager, remoteInterface: remoteInterface
        )
        enumerator.enumeratorItems = enumeratorItemsToReturn
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data(count: 1)))

        await fulfillment(of: [expect], timeout: 1)
    }
}
