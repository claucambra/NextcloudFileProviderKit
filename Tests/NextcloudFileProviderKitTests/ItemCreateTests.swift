//
//  ItemCreateTests.swift
//
//
//  Created by Claudio Cambra on 13/5/24.
//

import FileProvider
import NextcloudKit
import RealmSwift
import TestInterface
import UniformTypeIdentifiers
import XCTest
@testable import NextcloudFileProviderKit

final class ItemCreateTests: XCTestCase {
    static let account = Account(
        user: "testUser", id: "testUserId", serverUrl: "https://mock.nc.com", password: "abcd"
    )

    var rootItem: MockRemoteItem!
    static let dbManager = FilesDatabaseManager(realmConfig: .defaultConfiguration)

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration.inMemoryIdentifier = name
        rootItem = MockRemoteItem.rootItem(account: Self.account)
    }

    override func tearDown() {
        rootItem.children = []
    }

    func testCreateFolder() async throws {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let folderItemMetadata = SendableItemMetadata()
        folderItemMetadata.name = "folder"
        folderItemMetadata.fileName = "folder"
        folderItemMetadata.fileNameView = "folder"
        folderItemMetadata.directory = true
        folderItemMetadata.classFile = NKCommon.TypeClassFile.directory.rawValue
        folderItemMetadata.serverUrl = Self.account.davFilesUrl

        let folderItemTemplate = Item(
            metadata: folderItemMetadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: remoteInterface
        )
        let (createdItemMaybe, error) = await Item.create(
            basedOn: folderItemTemplate,
            contents: nil,
            account: Self.account,
            remoteInterface: remoteInterface,
            progress: Progress(),
            dbManager: Self.dbManager
        )
        let createdItem = try XCTUnwrap(createdItemMaybe)

        XCTAssertNil(error)
        XCTAssertNotNil(createdItem)
        XCTAssertEqual(createdItem.metadata.fileName, folderItemMetadata.fileName)
        XCTAssertEqual(createdItem.metadata.directory, true)

        XCTAssertNotNil(rootItem.children.first { $0.name == folderItemMetadata.name })
        XCTAssertNotNil(
            rootItem.children.first { $0.identifier == createdItem.itemIdentifier.rawValue }
        )
        let remoteItem = rootItem.children.first { $0.name == folderItemMetadata.name }
        XCTAssertTrue(remoteItem?.directory ?? false)

        let dbItem = try XCTUnwrap(
            Self.dbManager.itemMetadata(ocId: createdItem.itemIdentifier.rawValue)
        )
        XCTAssertEqual(dbItem.fileName, folderItemMetadata.fileName)
        XCTAssertEqual(dbItem.fileNameView, folderItemMetadata.fileNameView)
        XCTAssertEqual(dbItem.directory, folderItemMetadata.directory)
        XCTAssertEqual(dbItem.serverUrl, folderItemMetadata.serverUrl)
        XCTAssertEqual(dbItem.ocId, createdItem.itemIdentifier.rawValue)
    }

    func testCreateFile() async throws {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let fileItemMetadata = SendableItemMetadata()
        fileItemMetadata.fileName = "file"
        fileItemMetadata.fileNameView = "file"
        fileItemMetadata.directory = false
        fileItemMetadata.classFile = NKCommon.TypeClassFile.document.rawValue
        fileItemMetadata.serverUrl = Self.account.davFilesUrl

        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("file")
        try Data("Hello world".utf8).write(to: tempUrl)

        let fileItemTemplate = Item(
            metadata: fileItemMetadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: remoteInterface
        )
        let (createdItemMaybe, error) = await Item.create(
            basedOn: fileItemTemplate,
            contents: tempUrl,
            account: Self.account,
            remoteInterface: remoteInterface,
            progress: Progress(),
            dbManager: Self.dbManager
        )
        let createdItem = try XCTUnwrap(createdItemMaybe)

        XCTAssertNil(error)
        XCTAssertNotNil(createdItem)
        XCTAssertEqual(createdItem.metadata.fileName, fileItemMetadata.fileName)
        XCTAssertEqual(createdItem.metadata.directory, fileItemMetadata.directory)

        let remoteItem = try XCTUnwrap(
            rootItem.children.first { $0.identifier == createdItem.itemIdentifier.rawValue }
        )
        XCTAssertEqual(remoteItem.name, fileItemMetadata.fileName)
        XCTAssertEqual(remoteItem.directory, fileItemMetadata.directory)

        let dbItem = try XCTUnwrap(
            Self.dbManager.itemMetadata(ocId: createdItem.itemIdentifier.rawValue)
        )
        XCTAssertEqual(dbItem.fileName, fileItemMetadata.fileName)
        XCTAssertEqual(dbItem.fileNameView, fileItemMetadata.fileNameView)
        XCTAssertEqual(dbItem.directory, fileItemMetadata.directory)
        XCTAssertEqual(dbItem.serverUrl, fileItemMetadata.serverUrl)
        XCTAssertEqual(dbItem.ocId, createdItem.itemIdentifier.rawValue)
    }

    func testCreateFileIntoFolder() async throws {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)

        let folderItemMetadata = SendableItemMetadata()
        folderItemMetadata.name = "folder"
        folderItemMetadata.fileName = "folder"
        folderItemMetadata.fileNameView = "folder"
        folderItemMetadata.directory = true
        folderItemMetadata.serverUrl = Self.account.davFilesUrl
        folderItemMetadata.classFile = NKCommon.TypeClassFile.directory.rawValue

        let folderItemTemplate = Item(
            metadata: folderItemMetadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: remoteInterface
        )

        let (createdFolderItemMaybe, folderError) = await Item.create(
            basedOn: folderItemTemplate,
            contents: nil,
            account: Self.account,
            remoteInterface: remoteInterface,
            progress: Progress(),
            dbManager: Self.dbManager
        )

        XCTAssertNil(folderError)
        let createdFolderItem = try XCTUnwrap(createdFolderItemMaybe)

        let fileRelativeRemotePath = "/folder"
        let fileItemMetadata = SendableItemMetadata()
        fileItemMetadata.name = "file"
        fileItemMetadata.fileName = "file"
        fileItemMetadata.fileNameView = "file"
        fileItemMetadata.directory = false
        fileItemMetadata.serverUrl = Self.account.davFilesUrl + fileRelativeRemotePath
        fileItemMetadata.classFile = NKCommon.TypeClassFile.document.rawValue

        let fileItemTemplate = Item(
            metadata: fileItemMetadata,
            parentItemIdentifier: createdFolderItem.itemIdentifier,
            account: Self.account,
            remoteInterface: remoteInterface
        )

        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("file")
        try Data("Hello world".utf8).write(to: tempUrl)

        let (createdFileItemMaybe, fileError) = await Item.create(
            basedOn: fileItemTemplate,
            contents: tempUrl,
            account: Self.account,
            remoteInterface: remoteInterface,
            progress: Progress(),
            dbManager: Self.dbManager
        )
        let createdFileItem = try XCTUnwrap(createdFileItemMaybe)

        XCTAssertNil(fileError)
        XCTAssertNotNil(createdFileItem)

        let remoteFolderItem = rootItem.children.first { $0.name == "folder" }
        XCTAssertNotNil(remoteFolderItem)
        XCTAssertFalse(remoteFolderItem?.children.isEmpty ?? true)

        let dbItem = try XCTUnwrap(
            Self.dbManager.itemMetadata(ocId: createdFileItem.itemIdentifier.rawValue)
        )
        XCTAssertEqual(dbItem.fileName, fileItemMetadata.fileName)
        XCTAssertEqual(dbItem.fileNameView, fileItemMetadata.fileNameView)
        XCTAssertEqual(dbItem.directory, fileItemMetadata.directory)
        XCTAssertEqual(dbItem.serverUrl, fileItemMetadata.serverUrl)
        XCTAssertEqual(dbItem.ocId, createdFileItem.itemIdentifier.rawValue)

        let parentDbItem = try XCTUnwrap(
            Self.dbManager.itemMetadata(ocId: createdFolderItem.itemIdentifier.rawValue)
        )
        XCTAssertEqual(parentDbItem.fileName, folderItemMetadata.fileName)
        XCTAssertEqual(parentDbItem.fileNameView, folderItemMetadata.fileNameView)
        XCTAssertEqual(parentDbItem.directory, folderItemMetadata.directory)
        XCTAssertEqual(parentDbItem.serverUrl, folderItemMetadata.serverUrl)
    }

    func testCreateBundle() async throws {
        let db = Self.dbManager.ncDatabase() // Strong ref for in memory test db
        debugPrint(db)

        let keynoteBundleFilename = "test.key"

        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let bundleItemMetadata = SendableItemMetadata()
        bundleItemMetadata.name = keynoteBundleFilename
        bundleItemMetadata.fileName = keynoteBundleFilename
        bundleItemMetadata.fileNameView = keynoteBundleFilename
        bundleItemMetadata.directory = true
        bundleItemMetadata.serverUrl = Self.account.davFilesUrl
        bundleItemMetadata.classFile = NKCommon.TypeClassFile.directory.rawValue
        bundleItemMetadata.contentType = UTType.bundle.identifier

        let fm = FileManager.default
        let tempUrl = fm.temporaryDirectory.appendingPathComponent(keynoteBundleFilename)
        try fm.createDirectory(at: tempUrl, withIntermediateDirectories: true, attributes: nil)
        let keynoteIndexZipPath = tempUrl.appendingPathComponent("Index.zip")
        try Data("This is a fake zip!".utf8).write(to: keynoteIndexZipPath)
        let keynoteDataDir = tempUrl.appendingPathComponent("Data")
        try fm.createDirectory(
            at: keynoteDataDir, withIntermediateDirectories: true, attributes: nil
        )
        let keynoteMetadataDir = tempUrl.appendingPathComponent("Metadata")
        try fm.createDirectory(
            at: keynoteMetadataDir, withIntermediateDirectories: true, attributes: nil
        )
        let keynoteDocIdentifierPath =
            keynoteMetadataDir.appendingPathComponent("DocumentIdentifier")
        try Data("8B0C6C1F-4DA4-4DE8-8510-0C91FDCE7D01".utf8).write(to: keynoteDocIdentifierPath)
        let keynoteBuildVersionPlistPath =
            keynoteMetadataDir.appendingPathComponent("BuildVersionHistory.plist")
        try Data(
"""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <string>Template: 35_DynamicWavesDark (14.1)</string>
    <string>M14.1-7040.0.73-4</string>
</array>
</plist>
"""
            .utf8).write(to: keynoteBuildVersionPlistPath)
        let keynotePropertiesPlistPath = keynoteMetadataDir.appendingPathComponent("Properties.plist")
        try Data(
"""
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>revision</key>
    <string>0::5B42B84E-6F62-4E53-9E71-7DD24FA7E2EA</string>
    <key>documentUUID</key>
    <string>8B0C6C1F-4DA4-4DE8-8510-0C91FDCE7D01</string>
    <key>versionUUID</key>
    <string>5B42B84E-6F62-4E53-9E71-7DD24FA7E2EA</string>
    <key>privateUUID</key>
    <string>637C846B-6146-40C2-8EF8-26996E598E49</string>
    <key>isMultiPage</key>
    <false/>
    <key>stableDocumentUUID</key>
    <string>8B0C6C1F-4DA4-4DE8-8510-0C91FDCE7D01</string>
    <key>fileFormatVersion</key>
    <string>14.1.1</string>
    <key>shareUUID</key>
    <string>8B0C6C1F-4DA4-4DE8-8510-0C91FDCE7D01</string>
</dict>
</plist>
"""
            .utf8).write(to: keynotePropertiesPlistPath)

        let bundleItemTemplate = Item(
            metadata: bundleItemMetadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: remoteInterface
        )

        // TODO: Add fail test with no contents
        let (createdBundleItemMaybe, bundleError) = await Item.create(
            basedOn: bundleItemTemplate,
            contents: tempUrl,
            account: Self.account,
            remoteInterface: remoteInterface,
            progress: Progress(),
            dbManager: Self.dbManager
        )

        let createdBundleItem = try XCTUnwrap(createdBundleItemMaybe)

        XCTAssertNil(bundleError)
        XCTAssertNotNil(createdBundleItem)
        XCTAssertEqual(createdBundleItem.metadata.fileName, bundleItemMetadata.fileName)
        XCTAssertEqual(createdBundleItem.metadata.directory, true)

        // Below: this is an upstream issue (which we should fix)
        // XCTAssertTrue(createdBundleItem.contentType.conforms(to: .bundle))

        XCTAssertNotNil(rootItem.children.first { $0.name == bundleItemMetadata.name })
        XCTAssertNotNil(
            rootItem.children.first { $0.identifier == createdBundleItem.itemIdentifier.rawValue }
        )
        let remoteItem = rootItem.children.first { $0.name == bundleItemMetadata.name }
        XCTAssertTrue(remoteItem?.directory ?? false)

        let dbItem = try XCTUnwrap(
            Self.dbManager.itemMetadata(ocId: createdBundleItem.itemIdentifier.rawValue)
        )
        XCTAssertEqual(dbItem.fileName, bundleItemMetadata.fileName)
        XCTAssertEqual(dbItem.fileNameView, bundleItemMetadata.fileNameView)
        XCTAssertEqual(dbItem.directory, bundleItemMetadata.directory)
        XCTAssertEqual(dbItem.serverUrl, bundleItemMetadata.serverUrl)
        XCTAssertEqual(dbItem.ocId, createdBundleItem.itemIdentifier.rawValue)

        let remoteBundleItem = rootItem.children.first { $0.name == keynoteBundleFilename }
        XCTAssertNotNil(remoteBundleItem)
        XCTAssertEqual(remoteBundleItem?.children.count, 3)

        XCTAssertNotNil(remoteBundleItem?.children.first { $0.name == "Data" })
        XCTAssertNotNil(remoteBundleItem?.children.first { $0.name == "Index.zip" })

        let remoteMetadataItem = remoteBundleItem?.children.first { $0.name == "Metadata" }
        XCTAssertNotNil(remoteMetadataItem)
        XCTAssertEqual(remoteMetadataItem?.children.count, 3)
        XCTAssertNotNil(remoteMetadataItem?.children.first { $0.name == "DocumentIdentifier" })
        XCTAssertNotNil(remoteMetadataItem?.children.first { $0.name == "Properties.plist" })
        XCTAssertNotNil(remoteMetadataItem?.children.first {
            $0.name == "BuildVersionHistory.plist"
        })

        let childrenCount = Self.dbManager.childItemCount(directoryMetadata: dbItem)
        XCTAssertEqual(childrenCount, 6) // Ensure all children recorded to database
    }

    func testCreateFileChunked() async throws {
        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        let fileItemMetadata = SendableItemMetadata()
        fileItemMetadata.fileName = "file"
        fileItemMetadata.fileNameView = "file"
        fileItemMetadata.directory = false
        fileItemMetadata.classFile = NKCommon.TypeClassFile.document.rawValue
        fileItemMetadata.serverUrl = Self.account.davFilesUrl

        let chunkSize = 2
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("file")
        let tempData = Data(repeating: 1, count: chunkSize * 3)
        try tempData.write(to: tempUrl)

        let fileItemTemplate = Item(
            metadata: fileItemMetadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: remoteInterface
        )
        let (createdItemMaybe, error) = await Item.create(
            basedOn: fileItemTemplate,
            contents: tempUrl,
            account: Self.account,
            remoteInterface: remoteInterface,
            forcedChunkSize: chunkSize,
            progress: Progress(),
            dbManager: Self.dbManager
        )
        let createdItem = try XCTUnwrap(createdItemMaybe)

        XCTAssertNil(error)
        XCTAssertNotNil(createdItem)
        XCTAssertEqual(createdItem.metadata.fileName, fileItemMetadata.fileName)
        XCTAssertEqual(createdItem.metadata.directory, fileItemMetadata.directory)

        let remoteItem = try XCTUnwrap(
            rootItem.children.first { $0.identifier == createdItem.itemIdentifier.rawValue }
        )
        XCTAssertEqual(remoteItem.name, fileItemMetadata.fileName)
        XCTAssertEqual(remoteItem.directory, fileItemMetadata.directory)
        XCTAssertEqual(remoteItem.data, tempData)

        let dbItem = try XCTUnwrap(
            Self.dbManager.itemMetadata(ocId: createdItem.itemIdentifier.rawValue)
        )
        XCTAssertEqual(dbItem.fileName, fileItemMetadata.fileName)
        XCTAssertEqual(dbItem.fileNameView, fileItemMetadata.fileNameView)
        XCTAssertEqual(dbItem.directory, fileItemMetadata.directory)
        XCTAssertEqual(dbItem.serverUrl, fileItemMetadata.serverUrl)
        XCTAssertEqual(dbItem.ocId, createdItem.itemIdentifier.rawValue)
    }

    func testCreateFileChunkedResumed() async throws {
        let chunkSize = 2
        let expectedChunkUploadId = UUID().uuidString // Check if illegal characters are stripped
        let illegalChunkUploadId = expectedChunkUploadId + "/" // Check if illegal characters are stripped
        let previousUploadedChunkNum = 1
        let preexistingChunk = RemoteFileChunk(
            fileName: String(previousUploadedChunkNum),
            size: Int64(chunkSize),
            remoteChunkStoreFolderName: expectedChunkUploadId
        )

        let db = Self.dbManager.ncDatabase()
        try db.write {
            db.add([
                RemoteFileChunk(
                    fileName: String(previousUploadedChunkNum + 1),
                    size: Int64(chunkSize),
                    remoteChunkStoreFolderName: expectedChunkUploadId
                ),
                RemoteFileChunk(
                    fileName: String(previousUploadedChunkNum + 2),
                    size: Int64(chunkSize),
                    remoteChunkStoreFolderName: expectedChunkUploadId
                )
            ])
        }

        let remoteInterface = MockRemoteInterface(rootItem: rootItem)
        remoteInterface.currentChunks = [expectedChunkUploadId: [preexistingChunk]]

        // With real new item uploads we do not have an associated ItemMetadata as the template is
        // passed onto us by the OS. We cannot rely on the chunkUploadId property we usually use
        // during modified item uploads.
        //
        // We therefore can only use the system-provided item template's itemIdentifier as the
        // chunked upload identifier during new item creation.
        //
        // To test this situation we set the ocId of the metadata used to construct the item
        // template to the chunk upload id.
        let fileItemMetadata = SendableItemMetadata()
        fileItemMetadata.ocId = illegalChunkUploadId
        fileItemMetadata.fileName = "file"
        fileItemMetadata.fileNameView = "file"
        fileItemMetadata.directory = false
        fileItemMetadata.classFile = NKCommon.TypeClassFile.document.rawValue
        fileItemMetadata.serverUrl = Self.account.davFilesUrl

        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("file")
        let tempData = Data(repeating: 1, count: chunkSize * 3)
        try tempData.write(to: tempUrl)

        let fileItemTemplate = Item(
            metadata: fileItemMetadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: remoteInterface
        )
        let (createdItemMaybe, error) = await Item.create(
            basedOn: fileItemTemplate,
            contents: tempUrl,
            account: Self.account,
            remoteInterface: remoteInterface,
            forcedChunkSize: chunkSize,
            progress: Progress(),
            dbManager: Self.dbManager
        )
        let createdItem = try XCTUnwrap(createdItemMaybe)

        XCTAssertNil(error)
        XCTAssertNotNil(createdItem)
        XCTAssertEqual(createdItem.metadata.fileName, fileItemMetadata.fileName)
        XCTAssertEqual(createdItem.metadata.directory, fileItemMetadata.directory)

        let remoteItem = try XCTUnwrap(
            rootItem.children.first { $0.identifier == createdItem.itemIdentifier.rawValue }
        )
        XCTAssertEqual(remoteItem.name, fileItemMetadata.fileName)
        XCTAssertEqual(remoteItem.directory, fileItemMetadata.directory)
        XCTAssertEqual(remoteItem.data, tempData)
        XCTAssertEqual(
            remoteInterface.completedChunkTransferSize[expectedChunkUploadId],
            Int64(tempData.count) - preexistingChunk.size
        )

        let dbItem = try XCTUnwrap(
            Self.dbManager.itemMetadata(ocId: createdItem.itemIdentifier.rawValue)
        )
        XCTAssertEqual(dbItem.fileName, fileItemMetadata.fileName)
        XCTAssertEqual(dbItem.fileNameView, fileItemMetadata.fileNameView)
        XCTAssertEqual(dbItem.directory, fileItemMetadata.directory)
        XCTAssertEqual(dbItem.serverUrl, fileItemMetadata.serverUrl)
        XCTAssertEqual(dbItem.ocId, createdItem.itemIdentifier.rawValue)
        XCTAssertTrue(dbItem.chunkUploadId.isEmpty)
    }
}
