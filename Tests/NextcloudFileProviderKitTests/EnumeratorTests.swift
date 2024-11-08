//
//  EnumeratorTests.swift
//
//
//  Created by Claudio Cambra on 14/5/24.
//

import FileProvider
import NextcloudKit
import RealmSwift
import TestInterface
import XCTest
@testable import NextcloudFileProviderKit

final class EnumeratorTests: XCTestCase {
    static let account = Account(
        user: "testUser", id: "testUserId", serverUrl: "https://mock.nc.com", password: "abcd"
    )

    var rootItem: MockRemoteItem!
    var remoteFolder: MockRemoteItem!
    var remoteItemA: MockRemoteItem!
    var remoteItemB: MockRemoteItem!
    var remoteItemC: MockRemoteItem!

    static let dbManager = FilesDatabaseManager(realmConfig: .defaultConfiguration)

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration.inMemoryIdentifier = name

        rootItem = MockRemoteItem(
            identifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            name: "root",
            remotePath: Self.account.davFilesUrl,
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )

        remoteFolder = MockRemoteItem(
            identifier: "folder",
            versionIdentifier: "NEW",
            name: "folder",
            remotePath: Self.account.davFilesUrl + "/folder",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )

        remoteItemA = MockRemoteItem(
            identifier: "itemA",
            versionIdentifier: "NEW",
            name: "itemA",
            remotePath: Self.account.davFilesUrl + "/folder/itemA",
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )

        remoteItemB = MockRemoteItem(
            identifier: "itemB",
            name: "itemB",
            remotePath: Self.account.davFilesUrl + "/folder/itemB",
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )

        remoteItemC = MockRemoteItem(
            identifier: "itemC",
            name: "itemC",
            remotePath: Self.account.davFilesUrl + "/folder/itemC",
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )

        rootItem.children = [remoteFolder]
        remoteFolder.parent = rootItem
        remoteFolder.children = [remoteItemA, remoteItemB]
        remoteItemA.parent = remoteFolder
        remoteItemB.parent = remoteFolder
        remoteItemC.parent = nil
    }

    func testRootEnumeration() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db) // Avoid build-time warning about unused variable, ensure compiler won't free
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .rootContainer,
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager
        )
        let observer = MockEnumerationObserver(enumerator: enumerator)
        try await observer.enumerateItems()
        XCTAssertEqual(observer.items.count, 1)

        let retrievedFolderItem = try XCTUnwrap(observer.items.first)
        XCTAssertEqual(retrievedFolderItem.itemIdentifier.rawValue, remoteFolder.identifier)
        XCTAssertEqual(retrievedFolderItem.filename, remoteFolder.name)
        XCTAssertEqual(retrievedFolderItem.parentItemIdentifier.rawValue, rootItem.identifier)
        XCTAssertEqual(retrievedFolderItem.creationDate, remoteFolder.creationDate)
        XCTAssertEqual(
            Int(retrievedFolderItem.contentModificationDate??.timeIntervalSince1970 ?? 0),
            Int(remoteFolder.modificationDate.timeIntervalSince1970)
        )

        // Important to keep in mind. Default behaviour is fast enumeration, not deep enumeration
        let dbFolder = try XCTUnwrap(Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier))
        XCTAssertEqual(dbFolder.etag, "") // Folder is not visited yet, should not have etag
        XCTAssertEqual(dbFolder.fileName, remoteFolder.name)
        XCTAssertEqual(dbFolder.fileNameView, remoteFolder.name)
        XCTAssertEqual(dbFolder.serverUrl + "/" + dbFolder.fileName, remoteFolder.remotePath)
        XCTAssertEqual(dbFolder.account, Self.account.ncKitAccount)
        XCTAssertEqual(dbFolder.user, Self.account.username)
        XCTAssertEqual(dbFolder.userId, Self.account.id)
        XCTAssertEqual(dbFolder.urlBase, Self.account.serverUrl)

        let storedFolderItem = try XCTUnwrap(
            Item.storedItem(
                identifier: .init(remoteFolder.identifier),
                remoteInterface: remoteInterface,
                dbManager: Self.dbManager
            )
        )
        storedFolderItem.dbManager = Self.dbManager
        XCTAssertEqual(storedFolderItem.itemIdentifier.rawValue, remoteFolder.identifier)
        XCTAssertEqual(storedFolderItem.filename, remoteFolder.name)
        XCTAssertEqual(storedFolderItem.parentItemIdentifier.rawValue, rootItem.identifier)
        XCTAssertEqual(storedFolderItem.creationDate, remoteFolder.creationDate)
        XCTAssertEqual(
            Int(storedFolderItem.contentModificationDate?.timeIntervalSince1970 ?? 0),
            Int(remoteFolder.modificationDate.timeIntervalSince1970)
        )
        XCTAssertEqual(storedFolderItem.childItemCount?.intValue, 0) // Not visited yet, so no kids
    }

    func testWorkingSetEnumeration() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .workingSet,
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager
        )
        let observer = MockEnumerationObserver(enumerator: enumerator)
        try await observer.enumerateItems()
        XCTAssertEqual(observer.items.count, 1) // Should only get the folder in root

        let retrievedFolderItem = try XCTUnwrap(observer.items.first)
        XCTAssertEqual(retrievedFolderItem.itemIdentifier.rawValue, remoteFolder.identifier)
        XCTAssertEqual(retrievedFolderItem.filename, remoteFolder.name)
        XCTAssertEqual(retrievedFolderItem.parentItemIdentifier.rawValue, rootItem.identifier)
        XCTAssertEqual(retrievedFolderItem.creationDate, remoteFolder.creationDate)
        XCTAssertEqual(
            Int(retrievedFolderItem.contentModificationDate??.timeIntervalSince1970 ?? 0),
            Int(remoteFolder.modificationDate.timeIntervalSince1970)
        )

        // Ensure the newly discovered folder has no etag
        let dbFolder = try XCTUnwrap(Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier))
        XCTAssertTrue(dbFolder.etag.isEmpty)
    }

    func testWorkingSetFastChangeEnumeration() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .workingSet,
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager
        )
        let observer = MockChangeObserver(enumerator: enumerator)
        try await observer.enumerateChanges()
        XCTAssertEqual(observer.changedItems.count, 1) // Should only get the folder in root

        let retrievedFolderItem = try XCTUnwrap(observer.changedItems.first)
        XCTAssertEqual(retrievedFolderItem.itemIdentifier.rawValue, remoteFolder.identifier)
        XCTAssertEqual(retrievedFolderItem.filename, remoteFolder.name)
        XCTAssertEqual(retrievedFolderItem.parentItemIdentifier.rawValue, rootItem.identifier)
        XCTAssertEqual(retrievedFolderItem.creationDate, remoteFolder.creationDate)
        XCTAssertEqual(
            Int(retrievedFolderItem.contentModificationDate??.timeIntervalSince1970 ?? 0),
            Int(remoteFolder.modificationDate.timeIntervalSince1970)
        )

        // Ensure the newly discovered folder has no etag
        let dbFolder = try XCTUnwrap(Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier))
        XCTAssertTrue(dbFolder.etag.isEmpty)

        // Having an etag marks a folder as visited. 
        // We should get the two remaining files now, as the etag does not match the server but is
        // present, marking the folder as explored
        dbFolder.etag = "Not server etag"
        Self.dbManager.addItemMetadata(dbFolder)

        let newObserver = MockChangeObserver(enumerator: enumerator)
        try await newObserver.enumerateChanges()
        XCTAssertEqual(newObserver.changedItems.count, 3)

        let newNewObsever = MockChangeObserver(enumerator: enumerator)
        try await newNewObsever.enumerateChanges()
        XCTAssertEqual(newNewObsever.changedItems.count, 0)
    }

    func testWorkingSetSlowChangeEnumeration() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .workingSet,
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager,
            fastEnumeration: false
        )
        let observer = MockChangeObserver(enumerator: enumerator)
        try await observer.enumerateChanges()
        XCTAssertEqual(observer.changedItems.count, 3) // Should get all items

        let retrievedFolderItem = try XCTUnwrap(observer.changedItems.first)
        XCTAssertEqual(retrievedFolderItem.itemIdentifier.rawValue, remoteFolder.identifier)
        XCTAssertEqual(retrievedFolderItem.filename, remoteFolder.name)
        XCTAssertEqual(retrievedFolderItem.parentItemIdentifier.rawValue, rootItem.identifier)
        XCTAssertEqual(retrievedFolderItem.creationDate, remoteFolder.creationDate)
        XCTAssertEqual(
            Int(retrievedFolderItem.contentModificationDate??.timeIntervalSince1970 ?? 0),
            Int(remoteFolder.modificationDate.timeIntervalSince1970)
        )

        // Ensure the newly discovered folder has an etag
        let dbFolder = try XCTUnwrap(Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier))
        XCTAssertEqual(dbFolder.etag, remoteFolder.versionIdentifier)
    }

    func testFolderEnumeration() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        let oldEtag = "OLD"
        let folderMetadata = ItemMetadata()
        folderMetadata.ocId = remoteFolder.identifier
        folderMetadata.etag = oldEtag
        folderMetadata.name = remoteFolder.name
        folderMetadata.fileName = remoteFolder.name
        folderMetadata.fileNameView = remoteFolder.name
        folderMetadata.serverUrl = Self.account.davFilesUrl
        folderMetadata.account = Self.account.ncKitAccount
        folderMetadata.user = Self.account.username
        folderMetadata.userId = Self.account.id
        folderMetadata.urlBase = Self.account.serverUrl

        Self.dbManager.addItemMetadata(folderMetadata)
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier))

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .init(remoteFolder.identifier),
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager
        )
        let observer = MockEnumerationObserver(enumerator: enumerator)
        try await observer.enumerateItems()
        XCTAssertEqual(observer.items.count, 2)

        // A pass of enumerating a target should update the target too. Let's check.
        let dbFolderMetadata = try XCTUnwrap(
            Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier)
        )
        let storedFolderItem = try XCTUnwrap(
            Item.storedItem(
                identifier: .init(remoteFolder.identifier),
                remoteInterface: remoteInterface,
                dbManager: Self.dbManager
            )
        )
        storedFolderItem.dbManager = Self.dbManager
        XCTAssertEqual(dbFolderMetadata.etag, remoteFolder.versionIdentifier)
        XCTAssertNotEqual(dbFolderMetadata.etag, oldEtag)
        XCTAssertEqual(storedFolderItem.childItemCount?.intValue, remoteFolder.children.count)

        let retrievedItemA = try XCTUnwrap(
            observer.items.first(where: { $0.itemIdentifier.rawValue == remoteItemA.identifier })
        )
        XCTAssertEqual(retrievedItemA.itemIdentifier.rawValue, remoteItemA.identifier)
        XCTAssertEqual(retrievedItemA.filename, remoteItemA.name)
        XCTAssertEqual(retrievedItemA.parentItemIdentifier.rawValue, remoteFolder.identifier)
        XCTAssertEqual(retrievedItemA.creationDate, remoteItemA.creationDate)
        XCTAssertEqual(
            Int(retrievedItemA.contentModificationDate??.timeIntervalSince1970 ?? 0),
            Int(remoteItemA.modificationDate.timeIntervalSince1970)
        )
    }

    func testEnumerateFile() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        let folderMetadata = ItemMetadata()
        folderMetadata.ocId = remoteFolder.identifier
        folderMetadata.etag = remoteFolder.versionIdentifier
        folderMetadata.directory = true
        folderMetadata.name = remoteFolder.name
        folderMetadata.fileName = remoteFolder.name
        folderMetadata.fileNameView = remoteFolder.name
        folderMetadata.serverUrl = Self.account.davFilesUrl
        folderMetadata.account = Self.account.ncKitAccount
        folderMetadata.user = Self.account.username
        folderMetadata.userId = Self.account.username
        folderMetadata.urlBase = Self.account.serverUrl

        let itemAMetadata = ItemMetadata()
        itemAMetadata.ocId = remoteItemA.identifier
        itemAMetadata.etag = remoteItemA.versionIdentifier
        itemAMetadata.name = remoteItemA.name
        itemAMetadata.fileName = remoteItemA.name
        itemAMetadata.fileNameView = remoteItemA.name
        itemAMetadata.serverUrl = remoteFolder.remotePath
        itemAMetadata.account = Self.account.ncKitAccount
        itemAMetadata.user = Self.account.username
        itemAMetadata.userId = Self.account.id
        itemAMetadata.urlBase = Self.account.serverUrl

        Self.dbManager.addItemMetadata(folderMetadata)
        Self.dbManager.addItemMetadata(itemAMetadata)
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier))
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteItemA.identifier))

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .init(remoteItemA.identifier),
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager
        )
        let observer = MockEnumerationObserver(enumerator: enumerator)
        try await observer.enumerateItems()
        XCTAssertEqual(observer.items.count, 1)

        let retrievedItemAItem = try XCTUnwrap(observer.items.first)
        XCTAssertEqual(retrievedItemAItem.itemIdentifier.rawValue, remoteItemA.identifier)
        XCTAssertEqual(retrievedItemAItem.filename, remoteItemA.name)
        XCTAssertEqual(retrievedItemAItem.parentItemIdentifier.rawValue, remoteFolder.identifier)
        XCTAssertEqual(retrievedItemAItem.creationDate, remoteItemA.creationDate)
        XCTAssertEqual(
            Int(retrievedItemAItem.contentModificationDate??.timeIntervalSince1970 ?? 0),
            Int(remoteItemA.modificationDate.timeIntervalSince1970)
        )
    }

    func testFolderAndContentsChangeEnumeration() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        remoteFolder.children.removeAll(where: { $0.identifier == remoteItemB.identifier })
        remoteFolder.children.append(remoteItemC)
        remoteItemC.parent = remoteFolder

        let oldFolderEtag = "OLD"
        let folderMetadata = ItemMetadata()
        folderMetadata.ocId = remoteFolder.identifier
        folderMetadata.etag = oldFolderEtag
        folderMetadata.name = remoteFolder.name
        folderMetadata.fileName = remoteFolder.name
        folderMetadata.fileNameView = remoteFolder.name
        folderMetadata.serverUrl = Self.account.davFilesUrl
        folderMetadata.account = Self.account.ncKitAccount
        folderMetadata.user = Self.account.username
        folderMetadata.userId = Self.account.id
        folderMetadata.urlBase = Self.account.serverUrl

        let oldItemAEtag = "OLD"
        let itemAMetadata = ItemMetadata()
        itemAMetadata.ocId = remoteItemA.identifier
        itemAMetadata.etag = oldItemAEtag
        itemAMetadata.name = remoteItemA.name
        itemAMetadata.fileName = remoteItemA.name
        itemAMetadata.fileNameView = remoteItemA.name
        itemAMetadata.serverUrl = remoteFolder.remotePath
        itemAMetadata.account = Self.account.ncKitAccount
        itemAMetadata.user = Self.account.username
        itemAMetadata.userId = Self.account.id
        itemAMetadata.urlBase = Self.account.serverUrl

        let itemBMetadata = ItemMetadata()
        itemBMetadata.ocId = remoteItemB.identifier
        itemBMetadata.etag = remoteItemB.versionIdentifier
        itemBMetadata.name = remoteItemB.name
        itemBMetadata.fileName = remoteItemB.name
        itemBMetadata.fileNameView = remoteItemB.name
        itemBMetadata.serverUrl = remoteFolder.remotePath
        itemBMetadata.account = Self.account.ncKitAccount
        itemBMetadata.user = Self.account.username
        itemBMetadata.userId = Self.account.id
        itemBMetadata.urlBase = Self.account.serverUrl

        Self.dbManager.addItemMetadata(folderMetadata)
        Self.dbManager.addItemMetadata(itemAMetadata)
        Self.dbManager.addItemMetadata(itemBMetadata)
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier))
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteItemA.identifier))
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteItemB.identifier))

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .init(remoteFolder.identifier),
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager
        )
        let observer = MockChangeObserver(enumerator: enumerator)
        try await observer.enumerateChanges()
        // There are three changes: changed Item A, removed Item B, added Item C
        XCTAssertEqual(observer.changedItems.count, 2)
        XCTAssertTrue(observer.changedItems.contains(
            where: { $0.itemIdentifier.rawValue == remoteItemA.identifier }
        ))
        XCTAssertTrue(observer.changedItems.contains(
            where: { $0.itemIdentifier.rawValue == remoteItemC.identifier }
        ))
        XCTAssertEqual(observer.deletedItemIdentifiers.count, 1)
        XCTAssertTrue(observer.deletedItemIdentifiers.contains(
            where: { $0.rawValue == remoteItemB.identifier }
        ))

        // A pass of enumerating a target should update the target too. Let's check.
        let dbFolderMetadata = try XCTUnwrap(
            Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier)
        )
        let dbItemAMetadata = try XCTUnwrap(
            Self.dbManager.itemMetadataFromOcId(remoteItemA.identifier)
        )
        let dbItemCMetadata = try XCTUnwrap(
            Self.dbManager.itemMetadataFromOcId(remoteItemC.identifier)
        )
        XCTAssertNil(Self.dbManager.itemMetadataFromOcId(remoteItemB.identifier))
        XCTAssertEqual(dbFolderMetadata.etag, remoteFolder.versionIdentifier)
        XCTAssertNotEqual(dbFolderMetadata.etag, oldFolderEtag)
        XCTAssertEqual(dbItemAMetadata.etag, remoteItemA.versionIdentifier)
        XCTAssertNotEqual(dbItemAMetadata.etag, oldItemAEtag)
        XCTAssertEqual(dbItemCMetadata.ocId, remoteItemC.identifier)
        XCTAssertEqual(dbItemCMetadata.etag, remoteItemC.versionIdentifier)
        XCTAssertEqual(dbItemCMetadata.fileName, remoteItemC.name)
        XCTAssertEqual(dbItemCMetadata.fileNameView, remoteItemC.name)
        XCTAssertEqual(dbItemCMetadata.serverUrl, remoteFolder.remotePath)
        XCTAssertEqual(dbItemCMetadata.account, Self.account.ncKitAccount)
        XCTAssertEqual(dbItemCMetadata.user, Self.account.username)
        XCTAssertEqual(dbItemCMetadata.userId, Self.account.id)
        XCTAssertEqual(dbItemCMetadata.urlBase, Self.account.serverUrl)

        let storedFolderItem = try XCTUnwrap(
            Item.storedItem(
                identifier: .init(remoteFolder.identifier),
                remoteInterface: remoteInterface,
                dbManager: Self.dbManager
            )
        )
        storedFolderItem.dbManager = Self.dbManager

        let retrievedItemA = try XCTUnwrap(observer.changedItems.first(
            where: { $0.itemIdentifier.rawValue == remoteItemA.identifier }
        ))
        XCTAssertEqual(retrievedItemA.itemIdentifier.rawValue, remoteItemA.identifier)
        XCTAssertEqual(retrievedItemA.filename, remoteItemA.name)
        XCTAssertEqual(retrievedItemA.parentItemIdentifier.rawValue, remoteFolder.identifier)
        XCTAssertEqual(retrievedItemA.creationDate, remoteItemA.creationDate)
        XCTAssertEqual(
            Int(retrievedItemA.contentModificationDate??.timeIntervalSince1970 ?? 0),
            Int(remoteItemA.modificationDate.timeIntervalSince1970)
        )

        let retrievedItemC = try XCTUnwrap(observer.changedItems.first(
            where: { $0.itemIdentifier.rawValue == remoteItemC.identifier }
        ))
        XCTAssertEqual(retrievedItemC.itemIdentifier.rawValue, remoteItemC.identifier)
        XCTAssertEqual(retrievedItemC.filename, remoteItemC.name)
        XCTAssertEqual(retrievedItemC.parentItemIdentifier.rawValue, remoteFolder.identifier)
        XCTAssertEqual(retrievedItemC.creationDate, remoteItemC.creationDate)
        XCTAssertEqual(
            Int(retrievedItemC.contentModificationDate??.timeIntervalSince1970 ?? 0),
            Int(remoteItemC.modificationDate.timeIntervalSince1970)
        )
    }

    func testFileMoveChangeEnumeration() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        remoteFolder.children.removeAll(where: { $0.identifier == remoteItemA.identifier })
        rootItem.children.append(remoteItemA)
        remoteItemA.parent = rootItem
        remoteItemA.remotePath = rootItem.remotePath + "/\(remoteItemA.name)"

        let folderMetadata = ItemMetadata()
        folderMetadata.ocId = remoteFolder.identifier
        folderMetadata.etag = "OLD"
        folderMetadata.directory = true
        folderMetadata.name = remoteFolder.name
        folderMetadata.fileName = remoteFolder.name
        folderMetadata.fileNameView = remoteFolder.name
        folderMetadata.serverUrl = Self.account.davFilesUrl
        folderMetadata.account = Self.account.ncKitAccount
        folderMetadata.user = Self.account.username
        folderMetadata.userId = Self.account.id
        folderMetadata.urlBase = Self.account.serverUrl

        let oldEtag = "OLD"
        let oldServerUrl = remoteFolder.remotePath
        let oldName = "oldItemA"
        let itemAMetadata = ItemMetadata()
        itemAMetadata.ocId = remoteItemA.identifier
        itemAMetadata.etag = oldEtag
        itemAMetadata.name = oldName
        itemAMetadata.fileName = oldName
        itemAMetadata.fileNameView = oldName
        itemAMetadata.serverUrl = oldServerUrl
        itemAMetadata.account = Self.account.ncKitAccount
        itemAMetadata.user = Self.account.username
        itemAMetadata.userId = Self.account.id
        itemAMetadata.urlBase = Self.account.serverUrl

        let itemBMetadata = ItemMetadata()
        itemBMetadata.ocId = remoteItemB.identifier
        itemBMetadata.etag = remoteItemB.versionIdentifier
        itemBMetadata.name = remoteItemB.name
        itemBMetadata.fileName = remoteItemB.name
        itemBMetadata.fileNameView = remoteItemB.name
        itemBMetadata.serverUrl = remoteFolder.remotePath
        itemBMetadata.account = Self.account.ncKitAccount
        itemBMetadata.user = Self.account.username
        itemBMetadata.userId = Self.account.id
        itemBMetadata.urlBase = Self.account.serverUrl

        Self.dbManager.addItemMetadata(folderMetadata)
        Self.dbManager.addItemMetadata(itemAMetadata)
        Self.dbManager.addItemMetadata(itemBMetadata)
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier))
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteItemA.identifier))
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteItemB.identifier))

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .rootContainer,
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager
        )
        let observer = MockChangeObserver(enumerator: enumerator)
        try await observer.enumerateChanges()
        // rootContainer has changed, folder has changed, itemA has changed
        XCTAssertEqual(observer.changedItems.count, 2) // Not including target (TODO)
        XCTAssertTrue(observer.deletedItemIdentifiers.isEmpty)

        let retrievedItemA = try XCTUnwrap(observer.changedItems.first(
            where: { $0.itemIdentifier.rawValue == remoteItemA.identifier }
        ))
        XCTAssertEqual(retrievedItemA.itemIdentifier.rawValue, remoteItemA.identifier)
        XCTAssertEqual(retrievedItemA.filename, remoteItemA.name)
        XCTAssertEqual(retrievedItemA.parentItemIdentifier.rawValue, rootItem.identifier)
        XCTAssertEqual(retrievedItemA.creationDate, remoteItemA.creationDate)
        XCTAssertEqual(
            Int(retrievedItemA.contentModificationDate??.timeIntervalSince1970 ?? 0),
            Int(remoteItemA.modificationDate.timeIntervalSince1970)
        )

        let storedItemA = try XCTUnwrap(
            Item.storedItem(
                identifier: .init(remoteItemA.identifier),
                remoteInterface: remoteInterface,
                dbManager: Self.dbManager
            )
        )
        storedItemA.dbManager = Self.dbManager
        XCTAssertEqual(storedItemA.itemIdentifier.rawValue, remoteItemA.identifier)
        XCTAssertEqual(storedItemA.filename, remoteItemA.name)
        XCTAssertEqual(storedItemA.parentItemIdentifier.rawValue, rootItem.identifier)
        XCTAssertEqual(storedItemA.creationDate, remoteItemA.creationDate)
        XCTAssertEqual(
            Int(storedItemA.contentModificationDate?.timeIntervalSince1970 ?? 0),
            Int(remoteItemA.modificationDate.timeIntervalSince1970)
        )

        let storedRootItem = Item.rootContainer(remoteInterface: remoteInterface)
        print(storedRootItem.metadata.serverUrl)
        storedRootItem.dbManager = Self.dbManager
        XCTAssertEqual(storedRootItem.childItemCount?.intValue, 3) // All items

        let storedFolder = try XCTUnwrap(
            Item.storedItem(
                identifier: .init(remoteFolder.identifier),
                remoteInterface: remoteInterface,
                dbManager: Self.dbManager
            )
        )
        storedFolder.dbManager = Self.dbManager
        XCTAssertEqual(storedFolder.childItemCount?.intValue, remoteFolder.children.count)
    }

    func testFileLockStateEnumeration() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        remoteFolder.children.append(remoteItemC)
        remoteItemC.parent = remoteFolder

        remoteItemA.locked = true
        remoteItemA.lockOwner = Self.account.username
        remoteItemA.lockTimeOut = Date.now.advanced(by: 1_000_000_000_000)

        remoteItemB.locked = true
        remoteItemB.lockOwner = "other different account"
        remoteItemB.lockTimeOut = Date.now.advanced(by: 1_000_000_000_000)

        remoteItemC.locked = true
        remoteItemC.lockOwner = "other different account"
        remoteItemC.lockTimeOut = Date.now.advanced(by: -1_000_000_000_000)

        let folderMetadata = ItemMetadata()
        folderMetadata.ocId = remoteFolder.identifier
        folderMetadata.etag = "OLD"
        folderMetadata.directory = true
        folderMetadata.name = remoteFolder.name
        folderMetadata.fileName = remoteFolder.name
        folderMetadata.fileNameView = remoteFolder.name
        folderMetadata.serverUrl = Self.account.davFilesUrl
        folderMetadata.account = Self.account.ncKitAccount
        folderMetadata.user = Self.account.username
        folderMetadata.userId = Self.account.id
        folderMetadata.urlBase = Self.account.serverUrl

        Self.dbManager.addItemMetadata(folderMetadata)
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(remoteFolder.identifier))

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .init(remoteFolder.identifier),
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager
        )
        let observer = MockChangeObserver(enumerator: enumerator)
        try await observer.enumerateChanges()
        XCTAssertEqual(observer.changedItems.count, 3)

        let dbItemAMetadata = try XCTUnwrap(
            Self.dbManager.itemMetadataFromOcId(remoteItemA.identifier)
        )
        let dbItemBMetadata = try XCTUnwrap(
            Self.dbManager.itemMetadataFromOcId(remoteItemB.identifier)
        )
        let dbItemCMetadata = try XCTUnwrap(
            Self.dbManager.itemMetadataFromOcId(remoteItemC.identifier)
        )

        XCTAssertEqual(dbItemAMetadata.lock, remoteItemA.locked)
        XCTAssertEqual(dbItemAMetadata.lockOwner, remoteItemA.lockOwner)
        XCTAssertEqual(dbItemAMetadata.lockTimeOut, remoteItemA.lockTimeOut)

        XCTAssertEqual(dbItemBMetadata.lock, remoteItemB.locked)
        XCTAssertEqual(dbItemBMetadata.lockOwner, remoteItemB.lockOwner)
        XCTAssertEqual(dbItemBMetadata.lockTimeOut, remoteItemB.lockTimeOut)

        XCTAssertEqual(dbItemCMetadata.lock, remoteItemC.locked)
        XCTAssertEqual(dbItemCMetadata.lockOwner, remoteItemC.lockOwner)
        XCTAssertEqual(dbItemCMetadata.lockTimeOut, remoteItemC.lockTimeOut)

        let storedItemA = try XCTUnwrap(
            Item.storedItem(
                identifier: .init(remoteItemA.identifier),
                remoteInterface: remoteInterface,
                dbManager: Self.dbManager
            )
        )
        let storedItemB = try XCTUnwrap(
            Item.storedItem(
                identifier: .init(remoteItemB.identifier),
                remoteInterface: remoteInterface,
                dbManager: Self.dbManager
            )
        )
        let storedItemC = try XCTUnwrap(
            Item.storedItem(
                identifier: .init(remoteItemC.identifier),
                remoteInterface: remoteInterface,
                dbManager: Self.dbManager
            )
        )

        // Should be able to write to files locked by self
        XCTAssertTrue(storedItemA.fileSystemFlags.contains(.userWritable))
        // Should not be able to write to files locked by someone else
        XCTAssertFalse(storedItemB.fileSystemFlags.contains(.userWritable))
        // Should be able to write to files with an expired lock
        XCTAssertTrue(storedItemC.fileSystemFlags.contains(.userWritable))
    }

    // File Provider system will panic if we give it an NSFileProviderItem with an empty filename.
    // Test that we have a fallback to avoid this, even if something catastrophic happens in the
    // server and the file has no filename
    func testEnsureNoEmptyItemNameEnumeration() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db) // Avoid build-time warning about unused variable, ensure compiler won't free
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)

        remoteItemA.name = ""
        remoteItemA.parent = remoteInterface.rootItem
        rootItem.children = [remoteItemA]

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .rootContainer,
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager
        )
        let observer = MockChangeObserver(enumerator: enumerator)
        try await observer.enumerateChanges()
        // rootContainer has changed, itemA has changed
        XCTAssertEqual(observer.changedItems.count, 1)
        print(Self.dbManager.ncDatabase().objects(ItemMetadata.self).count)

        let dbItemAMetadata = try XCTUnwrap(
            Self.dbManager.itemMetadataFromOcId(remoteItemA.identifier)
        )
        XCTAssertEqual(dbItemAMetadata.ocId, remoteItemA.identifier)
        XCTAssertEqual(dbItemAMetadata.fileName, remoteItemA.name)

        let storedItemA = try XCTUnwrap(
            Item.storedItem(
                identifier: .init(remoteItemA.identifier),
                remoteInterface: remoteInterface,
                dbManager: Self.dbManager
            )
        )
        storedItemA.dbManager = Self.dbManager
        XCTAssertEqual(storedItemA.itemIdentifier.rawValue, remoteItemA.identifier)
        XCTAssertNotEqual(storedItemA.filename, remoteItemA.name)
        XCTAssertFalse(storedItemA.filename.isEmpty)
    }

    func testListenerInvocations() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)
        let remoteInterface = MockRemoteInterface(account: Self.account, rootItem: rootItem)
        let listener = MockEnumerationListener()

        let enumerator = Enumerator(
            enumeratedItemIdentifier: .workingSet,
            remoteInterface: remoteInterface,
            dbManager: Self.dbManager,
            listener: listener
        )
        let observer = MockEnumerationObserver(enumerator: enumerator)
        try await observer.enumerateItems()
        XCTAssertEqual(observer.items.count, 1) // Should only get the folder in root

        // Check enumeration actions
        XCTAssertEqual(listener.startActions.count, 1)
        XCTAssertEqual(listener.finishActions.count, 1)
        XCTAssertTrue(listener.errorActions.isEmpty)
        XCTAssertTrue(listener.startActions.first!.value < listener.finishActions.first!.value)
    }
}
