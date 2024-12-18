//
//  ItemDeleteTests.swift
//
//
//  Created by Claudio Cambra on 13/5/24.
//

import FileProvider
import NextcloudKit
import RealmSwift
import TestInterface
import XCTest
@testable import NextcloudFileProviderKit

final class ItemDeleteTests: XCTestCase {
    static let account = Account(
        user: "testUser", id: "testUserId", serverUrl: "https://mock.nc.com", password: "abcd"
    )
    lazy var rootItem = MockRemoteItem(
        identifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
        name: "root",
        remotePath: Self.account.davFilesUrl,
        directory: true,
        account: Self.account.ncKitAccount,
        username: Self.account.username,
        userId: Self.account.id,
        serverUrl: Self.account.serverUrl
    )
    lazy var rootTrashItem = MockRemoteItem(
        identifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
        name: "trash",
        remotePath: Self.account.trashUrl,
        directory: true,
        account: Self.account.ncKitAccount,
        username: Self.account.username,
        userId: Self.account.id,
        serverUrl: Self.account.serverUrl
    )
    static let dbManager = FilesDatabaseManager(realmConfig: .defaultConfiguration)

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration.inMemoryIdentifier = name
    }

    override func tearDown() {
        rootItem.children = []
        rootTrashItem.children = []
    }

    func testDeleteFile() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem, rootTrashItem: rootTrashItem)
        let itemIdentifier = "file"
        let remoteItem = MockRemoteItem(
            identifier: itemIdentifier, 
            name: "file",
            remotePath: Self.account.davFilesUrl + "/file",
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        remoteItem.parent = rootItem
        rootItem.children = [remoteItem]

        XCTAssertFalse(rootItem.children.isEmpty)

        let itemMetadata = ItemMetadata()
        itemMetadata.ocId = itemIdentifier
        itemMetadata.fileName = remoteItem.name
        itemMetadata.fileNameView = remoteItem.name
        itemMetadata.serverUrl = Self.account.davFilesUrl
        itemMetadata.urlBase = Self.account.serverUrl
        itemMetadata.account = Self.account.ncKitAccount
        itemMetadata.user = Self.account.username
        itemMetadata.userId = Self.account.id

        Self.dbManager.addItemMetadata(itemMetadata)
        XCTAssertNotNil(Self.dbManager.itemMetadata(ocId: itemIdentifier))

        let item = Item(
            metadata: itemMetadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: remoteInterface
        )

        let (error) = await item.delete(dbManager: Self.dbManager)
        XCTAssertNil(error)
        XCTAssertTrue(rootItem.children.isEmpty)

        XCTAssertNil(Self.dbManager.itemMetadata(ocId: itemIdentifier))
    }

    func testDeleteFolderAndContents() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem, rootTrashItem: rootTrashItem)
        let remoteFolder = MockRemoteItem(
            identifier: "folder",
            name: "folder",
            remotePath: Self.account.davFilesUrl + "/folder",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let remoteItem = MockRemoteItem(
            identifier: "file", 
            name: "file",
            remotePath: Self.account.davFilesUrl + "/folder/file",
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        rootItem.children = [remoteFolder]
        remoteFolder.parent = rootItem
        remoteFolder.children = [remoteItem]
        remoteItem.parent = remoteFolder

        XCTAssertFalse(rootItem.children.isEmpty)
        XCTAssertFalse(remoteFolder.children.isEmpty)

        let folderMetadata = ItemMetadata()
        folderMetadata.ocId = remoteFolder.identifier
        folderMetadata.fileName = remoteFolder.name
        folderMetadata.directory = true
        folderMetadata.serverUrl = Self.account.davFilesUrl

        let remoteItemMetadata = ItemMetadata()
        remoteItemMetadata.ocId = remoteItem.identifier
        remoteItemMetadata.fileName = remoteItem.name
        remoteItemMetadata.serverUrl = remoteFolder.remotePath

        Self.dbManager.addItemMetadata(folderMetadata)
        Self.dbManager.addItemMetadata(remoteItemMetadata)
        XCTAssertNotNil(Self.dbManager.itemMetadata(ocId: remoteFolder.identifier))
        XCTAssertNotNil(Self.dbManager.itemMetadata(ocId: remoteItem.identifier))

        let folder = Item(
            metadata: folderMetadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: remoteInterface
        )

        let (error) = await folder.delete(dbManager: Self.dbManager)
        XCTAssertNil(error)
        XCTAssertTrue(rootItem.children.isEmpty)

        XCTAssertNil(Self.dbManager.itemMetadata(ocId: remoteFolder.identifier))
        XCTAssertNil(Self.dbManager.itemMetadata(ocId: remoteItem.identifier))
    }

    func testDeleteWithTrashing() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem, rootTrashItem: rootTrashItem)
        let itemIdentifier = "file"
        let remoteItem = MockRemoteItem(
            identifier: itemIdentifier,
            name: "file",
            remotePath: Self.account.davFilesUrl + "/file",
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        remoteItem.parent = rootItem
        rootItem.children = [remoteItem]

        XCTAssertFalse(rootItem.children.isEmpty)

        let itemMetadata = ItemMetadata()
        itemMetadata.ocId = itemIdentifier
        itemMetadata.fileName = remoteItem.name
        itemMetadata.fileNameView = remoteItem.name
        itemMetadata.account = Self.account.ncKitAccount
        itemMetadata.user = Self.account.username
        itemMetadata.userId = Self.account.id
        itemMetadata.serverUrl = Self.account.davFilesUrl
        itemMetadata.urlBase = Self.account.serverUrl

        XCTAssertEqual(itemMetadata.isTrashed, false)

        Self.dbManager.addItemMetadata(itemMetadata)
        XCTAssertNotNil(Self.dbManager.itemMetadataFromOcId(itemIdentifier))

        let item = Item(
            metadata: itemMetadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: remoteInterface
        )

        let (error) = await item.delete(trashing: true, dbManager: Self.dbManager)
        XCTAssertNil(error)
        XCTAssertTrue(rootItem.children.isEmpty)

        let postTrashingMetadata = Self.dbManager.itemMetadataFromOcId(itemIdentifier);
        XCTAssertNotNil(postTrashingMetadata)
        XCTAssertEqual(postTrashingMetadata?.serverUrl, Self.account.trashUrl)
        XCTAssertEqual(
            Self.dbManager.parentItemIdentifierFromMetadata(postTrashingMetadata!), .trashContainer
        )
        XCTAssertEqual(postTrashingMetadata?.isTrashed, true)
        XCTAssertEqual(postTrashingMetadata?.trashbinFileName, "file") // Remember we need to sync
        XCTAssertEqual(postTrashingMetadata?.trashbinOriginalLocation, "file")
    }
}
