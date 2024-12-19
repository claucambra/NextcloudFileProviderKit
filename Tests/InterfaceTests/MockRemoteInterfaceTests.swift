//
//  MockRemoteInterfaceTests.swift
//
//
//  Created by Claudio Cambra on 13/5/24.
//

import XCTest
@testable import NextcloudFileProviderKit
@testable import TestInterface

final class MockRemoteInterfaceTests: XCTestCase {
    static let account = Account(
        user: "testUser", id: "testUserId", serverUrl: "https://mock.nc.com", password: "abcd"
    )
    lazy var rootItem = MockRemoteItem(
        identifier: "root",
        versionIdentifier: "root",
        name: "root",
        remotePath: Self.account.davFilesUrl,
        directory: true,
        account: Self.account.ncKitAccount,
        username: Self.account.username,
        userId: Self.account.id,
        serverUrl: Self.account.serverUrl
    )
    lazy var rootTrashItem = MockRemoteItem(
        identifier: "root",
        versionIdentifier: "root",
        name: "root",
        remotePath: Self.account.trashUrl,
        directory: true,
        account: Self.account.ncKitAccount,
        username: Self.account.username,
        userId: Self.account.id,
        serverUrl: Self.account.serverUrl
    )

    override func tearDown() {
        rootItem.children = []
        rootTrashItem.children = []
    }

    func testItemForRemotePath() {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let itemA = MockRemoteItem(
            identifier: "a", 
            versionIdentifier: "a",
            name: "a",
            remotePath: Self.account.davFilesUrl + "/a",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemB = MockRemoteItem(
            identifier: "b", 
            versionIdentifier: "b", 
            name: "b",
            remotePath: Self.account.davFilesUrl + "/b",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemA_B = MockRemoteItem(
            identifier: "b", 
            versionIdentifier: "b",
            name: "b",
            remotePath: Self.account.davFilesUrl + "/a/b",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let targetItem = MockRemoteItem(
            identifier: "target", 
            versionIdentifier: "target",
            name: "target",
            remotePath: Self.account.davFilesUrl + "/a/b/target",
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )

        remoteInterface.rootItem?.children = [itemA, itemB]
        itemA.parent = remoteInterface.rootItem
        itemB.parent = remoteInterface.rootItem
        itemA.children = [itemA_B]
        itemA_B.parent = itemA
        itemA_B.children = [targetItem]
        targetItem.parent = itemA_B

        XCTAssertEqual(
            remoteInterface.item(
                remotePath: Self.account.davFilesUrl + "/a/b/target", account: Self.account
            ), targetItem
        )
    }

    func testItemForRootPath() {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        XCTAssertEqual(
            remoteInterface.item(remotePath: Self.account.davFilesUrl, account: Self.account), rootItem
        )
    }

    func testPathParentPath() {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let testPath = Self.account.davFilesUrl + "/a/B/c/d"
        let expectedPath = Self.account.davFilesUrl + "/a/B/c"

        XCTAssertEqual(
            remoteInterface.parentPath(path: testPath, account: Self.account), expectedPath
        )
    }

    func testRootPathParentPath() {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let testPath = Self.account.davFilesUrl + "/"
        let expectedPath = Self.account.davFilesUrl + "/"

        XCTAssertEqual(
            remoteInterface.parentPath(path: testPath, account: Self.account), expectedPath
        )
    }

    func testNameFromPath() throws {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let testPath = Self.account.davFilesUrl + "/a/b/c/d"
        let expectedName = "d"
        let name = try remoteInterface.name(from: testPath)
        XCTAssertEqual(name, expectedName)
    }

    func testCreateFolder() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let newFolderAPath = Self.account.davFilesUrl + "/A"
        let newFolderA_BPath = Self.account.davFilesUrl + "/A/B/"

        let resultA = await remoteInterface.createFolder(
            remotePath: newFolderAPath, account: Self.account
        )
        XCTAssertEqual(resultA.error, .success)

        let resultA_B = await remoteInterface.createFolder(
            remotePath: newFolderA_BPath, account: Self.account
        )
        XCTAssertEqual(resultA_B.error, .success)

        let itemA = remoteInterface.item(remotePath: newFolderAPath, account: Self.account)
        XCTAssertNotNil(itemA)
        XCTAssertEqual(itemA?.name, "A")
        XCTAssertTrue(itemA?.directory ?? false)

        let itemA_B = remoteInterface.item(remotePath: newFolderA_BPath, account: Self.account)
        XCTAssertNotNil(itemA_B)
        XCTAssertEqual(itemA_B?.name, "B")
        XCTAssertTrue(itemA_B?.directory ?? false)
    }

    func testUpload() async throws {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let fileUrl = URL.temporaryDirectory.appendingPathComponent("file.txt", conformingTo: .text)
        let fileData = Data("Hello, World!".utf8)
        let fileSize = Int64(fileData.count)
        try fileData.write(to: fileUrl)

        let result = await remoteInterface.upload(
            remotePath: Self.account.davFilesUrl, localPath: fileUrl.path, account: Self.account
        )
        XCTAssertEqual(result.remoteError, .success)

        let remoteItem = remoteInterface.item(
            remotePath: Self.account.davFilesUrl + "/file.txt", account: Self.account
        )
        XCTAssertNotNil(remoteItem)

        XCTAssertEqual(remoteItem?.name, "file.txt")
        XCTAssertEqual(remoteItem?.size, fileSize)
        XCTAssertEqual(remoteItem?.data, fileData)
        XCTAssertEqual(result.size, fileSize)

        // TODO: Add test for overwriting existing file
    }

    func testMove() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let itemA = MockRemoteItem(
            identifier: "a",
            name: "a",
            remotePath: Self.account.davFilesUrl + "/a",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemB = MockRemoteItem(
            identifier: "b", 
            name: "b",
            remotePath: Self.account.davFilesUrl + "/b",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemC = MockRemoteItem(
            identifier: "c", 
            name: "c",
            remotePath: Self.account.davFilesUrl + "/a/c",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let targetItem = MockRemoteItem(
            identifier: "target", 
            name: "target",
            remotePath: Self.account.davFilesUrl + "/a/c/target",
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )

        remoteInterface.rootItem?.children = [itemA, itemB]
        itemA.parent = remoteInterface.rootItem
        itemA.children = [itemC]
        itemC.parent = itemA
        itemB.parent = remoteInterface.rootItem

        itemC.children = [targetItem]
        targetItem.parent = itemC

        let result = await remoteInterface.move(
            remotePathSource: Self.account.davFilesUrl + "/a/c/target",
            remotePathDestination: Self.account.davFilesUrl + "/b/targetRenamed",
            account: Self.account
        )
        XCTAssertEqual(result.error, .success)
        XCTAssertEqual(itemB.children, [targetItem])
        XCTAssertEqual(itemC.children, [])
        XCTAssertEqual(targetItem.parent, itemB)
        XCTAssertEqual(targetItem.name, "targetRenamed")
        XCTAssertEqual(targetItem.remotePath, Self.account.davFilesUrl + "/b/targetRenamed")
    }

    func testDownload() async throws {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let fileUrl = FileManager.default.temporaryDirectory.appendingPathComponent(
            "file.txt", conformingTo: .text
        )
        if !FileManager.default.isWritableFile(atPath: fileUrl.path) {
            print("WARNING: TEMP NOT WRITEABLE. SKIPPING TEST")
            return
        }
        let fileData = Data("Hello, World!".utf8)
        let _ = await remoteInterface.upload(
            remotePath: Self.account.davFilesUrl, localPath: fileUrl.path, account: Self.account
        )

        let result = await remoteInterface.download(
            remotePath: Self.account.davFilesUrl + "/file.txt",
            localPath: fileUrl.path,
            account: Self.account
        )
        XCTAssertEqual(result.remoteError, .success)

        let downloadedData = try Data(contentsOf: fileUrl)
        XCTAssertEqual(downloadedData, fileData)
    }

    func testEnumerate() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let itemA = MockRemoteItem(
            identifier: "a", 
            name: "a",
            remotePath: Self.account.davFilesUrl + "/a",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemB = MockRemoteItem(
            identifier: "b", 
            name: "b",
            remotePath: Self.account.davFilesUrl + "/b",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemC = MockRemoteItem(
            identifier: "c", 
            name: "c",
            remotePath: Self.account.davFilesUrl + "/c",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemA_A = MockRemoteItem(
            identifier: "a_a",
            name: "a",
            remotePath: Self.account.davFilesUrl + "/a/a",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemA_B = MockRemoteItem(
            identifier: "a_b", 
            name: "b",
            remotePath: Self.account.davFilesUrl + "/a/b",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemC_A = MockRemoteItem(
            identifier: "c_a", 
            name: "a",
            remotePath: Self.account.davFilesUrl + "/c/a",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemC_A_A = MockRemoteItem(
            identifier: "c_a_a", 
            name: "a",
            remotePath: Self.account.davFilesUrl + "/c/a/a",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )

        remoteInterface.rootItem?.children = [itemA, itemB, itemC]
        itemA.parent = remoteInterface.rootItem
        itemB.parent = remoteInterface.rootItem
        itemC.parent = remoteInterface.rootItem

        itemA.children = [itemA_A, itemA_B]
        itemA_A.parent = itemA
        itemA_B.parent = itemA

        itemC.children = [itemC_A]
        itemC_A.parent = itemC

        itemC_A.children = [itemC_A_A]
        itemC_A_A.parent = itemC_A

        let result = await remoteInterface.enumerate(
            remotePath: Self.account.davFilesUrl, depth: .target, account: Self.account
        )
        XCTAssertEqual(result.error, .success)
        XCTAssertEqual(result.files.count, 1)
        let targetRootFile = result.files.first
        let expectedRoot = remoteInterface.rootItem
        XCTAssertEqual(targetRootFile?.ocId, expectedRoot?.identifier)
        XCTAssertEqual(targetRootFile?.fileName, expectedRoot?.name)
        XCTAssertEqual(targetRootFile?.date, expectedRoot?.creationDate)
        XCTAssertEqual(targetRootFile?.etag, expectedRoot?.versionIdentifier)

        let resultChildren = await remoteInterface.enumerate(
            remotePath: Self.account.davFilesUrl,
            depth: .targetAndDirectChildren,
            account: Self.account
        )
        XCTAssertEqual(resultChildren.error, .success)
        XCTAssertEqual(resultChildren.files.count, 4)
        XCTAssertEqual(
            resultChildren.files.map(\.ocId),
            [
                remoteInterface.rootItem?.identifier,
                itemA.identifier,
                itemB.identifier,
                itemC.identifier,
            ]
        )

        let resultAChildren = await remoteInterface.enumerate(
            remotePath: Self.account.davFilesUrl + "/a",
            depth: .targetAndDirectChildren,
            account: Self.account
        )
        XCTAssertEqual(resultAChildren.error, .success)
        XCTAssertEqual(resultAChildren.files.count, 3)
        XCTAssertEqual(
            resultAChildren.files.map(\.ocId),
            [itemA.identifier, itemA_A.identifier, itemA_B.identifier]
        )

        let resultCChildren = await remoteInterface.enumerate(
            remotePath: Self.account.davFilesUrl + "/c",
            depth: .targetAndDirectChildren,
            account: Self.account
        )
        XCTAssertEqual(resultCChildren.error, .success)
        XCTAssertEqual(resultCChildren.files.count, 2)
        XCTAssertEqual(
            resultCChildren.files.map(\.ocId),
            [itemC.identifier, itemC_A.identifier]
        )

        let resultCRecursiveChildren = await remoteInterface.enumerate(
            remotePath: Self.account.davFilesUrl + "/c",
            depth: .targetAndAllChildren,
            account: Self.account
        )
        XCTAssertEqual(resultCRecursiveChildren.error, .success)
        XCTAssertEqual(resultCRecursiveChildren.files.count, 3)
        XCTAssertEqual(
            resultCRecursiveChildren.files.map(\.ocId),
            [itemC.identifier, itemC_A.identifier, itemC_A_A.identifier]
        )
    }

    func testDelete() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem, rootTrashItem: rootTrashItem)
        let itemA = MockRemoteItem(
            identifier: "a", 
            name: "a",
            remotePath: Self.account.davFilesUrl + "/a",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemB = MockRemoteItem(
            identifier: "b", 
            name: "b",
            remotePath: Self.account.davFilesUrl + "/b",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemA_C = MockRemoteItem(
            identifier: "c",
            name: "c",
            remotePath: Self.account.davFilesUrl + "/a/c",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemA_C_D = MockRemoteItem(
            identifier: "d",
            name: "d",
            remotePath: Self.account.davFilesUrl + "/a/c/d",
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )

        remoteInterface.rootItem?.children = [itemA, itemB]
        itemA.parent = remoteInterface.rootItem
        itemA.children = [itemA_C]
        itemA_C.parent = itemA
        itemB.parent = remoteInterface.rootItem

        itemA_C.children = [itemA_C_D]
        itemA_C_D.parent = itemA_C

        let itemA_C_predeleteName = itemA_C.name

        let result = await remoteInterface.delete(
            remotePath: Self.account.davFilesUrl + "/a/c", account: Self.account
        )
        XCTAssertEqual(result.error, .success)
        XCTAssertEqual(itemA.children, [])
        XCTAssertEqual(remoteInterface.rootTrashItem?.children.contains(itemA_C), true)
        XCTAssertEqual(itemA_C.name, itemA_C_predeleteName + " (trashed)")
        XCTAssertEqual(itemA_C.remotePath, Self.account.trashUrl + "/c (trashed)")
        XCTAssertEqual(itemA_C_D.trashbinOriginalLocation, "a/c/d")
        XCTAssertEqual(itemA_C_D.remotePath, Self.account.trashUrl + "/c (trashed)/d")
    }

    func testTrashedItems() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem, rootTrashItem: rootTrashItem)
        let itemA = MockRemoteItem(
            identifier: "a",
            name: "a (trashed)",
            remotePath: Self.account.trashUrl + "/a (trashed)",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl,
            trashbinOriginalLocation: "a"
        )
        let itemB = MockRemoteItem(
            identifier: "b",
            name: "b (trashed)",
            remotePath: Self.account.trashUrl + "/b (trashed)",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl,
            trashbinOriginalLocation: "b"
        )
        rootTrashItem.children = [itemA, itemB]
        itemA.parent = rootTrashItem
        itemB.parent = rootTrashItem

        let (_, items, _, error) = await remoteInterface.trashedItems(account: Self.account)
        XCTAssertEqual(error, .success)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].fileName, "a (trashed)")
        XCTAssertEqual(items[1].fileName, "b (trashed)")
        XCTAssertEqual(items[0].trashbinFileName, "a")
        XCTAssertEqual(items[1].trashbinFileName, "b")
        XCTAssertEqual(items[0].ocId, itemA.identifier)
        XCTAssertEqual(items[1].ocId, itemB.identifier)
    }

    func testRestoreFromTrash() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem, rootTrashItem: rootTrashItem)
        let itemA = MockRemoteItem(
            identifier: "a",
            name: "a (trashed)",
            remotePath: Self.account.trashUrl + "/a (trashed)",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl,
            trashbinOriginalLocation: "a"
        )
        rootTrashItem.children = [itemA]
        itemA.parent = rootTrashItem

        let (_, _, error) =
            await remoteInterface.restoreFromTrash(filename: itemA.name, account: Self.account)
        XCTAssertEqual(error, .success)
        XCTAssertEqual(rootTrashItem.children.count, 0)
        XCTAssertEqual(rootItem.children.count, 1)
        XCTAssertEqual(rootItem.children[0].identifier, "a")
        XCTAssertEqual(itemA.identifier, "a")
        XCTAssertEqual(itemA.remotePath, Self.account.davFilesUrl + "/a")
        XCTAssertEqual(itemA.name, "a")
        XCTAssertNil(itemA.trashbinOriginalLocation)
    }

    func testNoDirectMoveFromTrash() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem, rootTrashItem: rootTrashItem)
        let folder = MockRemoteItem(
            identifier: "folder",
            name: "folder",
            remotePath: Self.account.davFilesUrl + "/folder",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl
        )
        let itemA = MockRemoteItem(
            identifier: "a",
            name: "a (trashed)",
            remotePath: Self.account.trashUrl + "/a (trashed)",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl,
            trashbinOriginalLocation: "a"
        )
        rootTrashItem.children = [itemA]
        itemA.parent = rootTrashItem
        rootItem.children = [folder]
        folder.parent = rootItem

        let newPath = folder.remotePath + "/" + itemA.name
        let (_, _, directMoveError) = await remoteInterface.move(
            remotePathSource: itemA.remotePath,
            remotePathDestination: newPath,
            overwrite: true,
            account: Self.account
        )
        XCTAssertNotEqual(directMoveError, .success) // Should fail as we need to restore first

        let expectedRestoreRemotePath =
            Self.account.davFilesUrl + "/" + itemA.trashbinOriginalLocation!
        let (_, _, restoreError) =
            await remoteInterface.restoreFromTrash(filename: itemA.name, account: Self.account)
        XCTAssertEqual(restoreError, .success)
        XCTAssertEqual(itemA.remotePath, expectedRestoreRemotePath)

        let (_, _, postRestoreMoveError) = await remoteInterface.move(
            remotePathSource: itemA.remotePath,
            remotePathDestination: newPath,
            overwrite: true,
            account: Self.account
        )
        XCTAssertEqual(postRestoreMoveError, .success)
    }

    func testEnforceOverwriteOnRestore() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem, rootTrashItem: rootTrashItem)
        let itemA = MockRemoteItem(
            identifier: "a",
            name: "a (trashed)",
            remotePath: Self.account.trashUrl + "/a (trashed)",
            directory: true,
            account: Self.account.ncKitAccount,
            username: Self.account.username,
            userId: Self.account.id,
            serverUrl: Self.account.serverUrl,
            trashbinOriginalLocation: "a"
        )
        rootTrashItem.children = [itemA]
        itemA.parent = rootTrashItem

        let restorePath = Self.account.trashRestoreUrl + "/" + itemA.name
        let (_, _, noOverwriteError) = await remoteInterface.move(
            remotePathSource: itemA.remotePath,
            remotePathDestination: restorePath,
            overwrite: false,
            account: Self.account
        )
        XCTAssertNotEqual(noOverwriteError, .success) // Should fail as we enforce overwrite

        let (_, _, overwriteError) = await remoteInterface.move(
            remotePathSource: itemA.remotePath,
            remotePathDestination: restorePath,
            overwrite: true,
            account: Self.account
        )
        XCTAssertEqual(overwriteError, .success)
    }

    func testFetchUserProfile() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let (account, profile, _, error) = await remoteInterface.fetchUserProfile(
            account: Self.account
        )
        XCTAssertEqual(error, .success)
        XCTAssertEqual(account, Self.account.ncKitAccount)
        XCTAssertNotNil(profile)
    }

    func testTryAuthenticationAttempt() async {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let state = await remoteInterface.tryAuthenticationAttempt(account: Self.account)
        XCTAssertEqual(state, .success)
        let failState = await remoteInterface.tryAuthenticationAttempt(
            account: Account(user: "", id: "", serverUrl: "", password: "")
        )
        XCTAssertEqual(failState, .authenticationError)
    }
}
