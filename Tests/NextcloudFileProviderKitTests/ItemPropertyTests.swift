//
//  ItemPropertyTests.swift
//
//
//  Created by Claudio Cambra on 24/7/24.
//

import FileProvider
import NextcloudKit
import RealmSwift
import TestInterface
import UniformTypeIdentifiers
import XCTest
@testable import NextcloudFileProviderKit

final class ItemPropertyTests: XCTestCase {
    static let account = Account(
        user: "testUser", id: "testUserId", serverUrl: "https://mock.nc.com", password: "abcd"
    )

    func testMetadataContentType() {
        let metadata = ItemMetadata()
        metadata.ocId = "test-id"
        metadata.etag = "test-etag"
        metadata.name = "test.txt"
        metadata.fileName = "test.txt"
        metadata.fileNameView = "test.txt"
        metadata.serverUrl = Self.account.davFilesUrl
        metadata.urlBase = Self.account.serverUrl
        metadata.userId = Self.account.username
        metadata.user = Self.account.username
        metadata.date = .init()
        metadata.contentType = UTType.text.identifier
        metadata.size = 12

        let item = Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: MockRemoteInterface()
        )
        XCTAssertEqual(item.contentType, UTType.text)
    }

    func testMetadataExtensionContentType() {
        let metadata = ItemMetadata()
        metadata.ocId = "test-id"
        metadata.etag = "test-etag"
        metadata.name = "test.pdf"
        metadata.fileName = "test.pdf"
        metadata.fileNameView = "test.pdf"
        metadata.serverUrl = Self.account.davFilesUrl
        metadata.urlBase = Self.account.serverUrl
        metadata.userId = Self.account.username
        metadata.user = Self.account.username
        metadata.date = .init()
        metadata.size = 12
        // Don't set the content type in metadata, test the extension uttype discovery

        let item = Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: MockRemoteInterface()
        )
        XCTAssertEqual(item.contentType, UTType.pdf)
    }

    func testMetadataFolderContentType() {
        let metadata = ItemMetadata()
        metadata.ocId = "test-id"
        metadata.etag = "test-etag"
        metadata.name = "test"
        metadata.fileName = "test"
        metadata.fileNameView = "test"
        metadata.serverUrl = Self.account.davFilesUrl
        metadata.urlBase = Self.account.serverUrl
        metadata.userId = Self.account.username
        metadata.user = Self.account.username
        metadata.date = .init()
        metadata.size = 12
        metadata.directory = true

        let item = Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: MockRemoteInterface()
        )
        XCTAssertEqual(item.contentType, UTType.folder)
    }

    func testMetadataPackageContentType() {
        let metadata = ItemMetadata()
        metadata.ocId = "test-id"
        metadata.etag = "test-etag"
        metadata.name = "test.zip"
        metadata.fileName = "test.zip"
        metadata.fileNameView = "test.zip"
        metadata.serverUrl = Self.account.davFilesUrl
        metadata.urlBase = Self.account.serverUrl
        metadata.userId = Self.account.username
        metadata.user = Self.account.username
        metadata.date = .init()
        metadata.size = 12
        metadata.directory = true
        metadata.contentType = UTType.package.identifier

        let item = Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: MockRemoteInterface()
        )
        XCTAssertEqual(item.contentType, UTType.package)
    }

    func testMetadataBundleContentType() {
        let metadata = ItemMetadata()
        metadata.ocId = "test-id"
        metadata.etag = "test-etag"
        metadata.name = "test.app"
        metadata.fileName = "test.key"
        metadata.fileNameView = "test.key"
        metadata.serverUrl = Self.account.davFilesUrl
        metadata.urlBase = Self.account.serverUrl
        metadata.userId = Self.account.username
        metadata.user = Self.account.username
        metadata.date = .init()
        metadata.size = 12
        metadata.directory = true
        metadata.contentType = UTType.bundle.identifier

        let item = Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: MockRemoteInterface()
        )
        XCTAssertEqual(item.contentType, UTType.bundle)
    }

    func testMetadataUnixFolderContentType() {
        let metadata = ItemMetadata()
        metadata.ocId = "test-id"
        metadata.etag = "test-etag"
        metadata.name = "test"
        metadata.fileName = "test"
        metadata.fileNameView = "test"
        metadata.serverUrl = Self.account.davFilesUrl
        metadata.urlBase = Self.account.serverUrl
        metadata.userId = Self.account.username
        metadata.user = Self.account.username
        metadata.date = .init()
        metadata.size = 12
        metadata.directory = true
        metadata.contentType = "httpd/unix-directory"

        let item = Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: MockRemoteInterface()
        )
        XCTAssertEqual(item.contentType, UTType.folder)
    }

    func testPredictedBundleContentType() {
        let metadata = ItemMetadata()
        metadata.ocId = "test-id"
        metadata.etag = "test-etag"
        metadata.name = "test.app"
        metadata.fileName = "test.app"
        metadata.fileNameView = "test.app"
        metadata.serverUrl = Self.account.davFilesUrl
        metadata.urlBase = Self.account.serverUrl
        metadata.userId = Self.account.username
        metadata.user = Self.account.username
        metadata.date = .init()
        metadata.size = 12
        metadata.directory = true
        metadata.contentType = "httpd/unix-directory"

        let item = Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: MockRemoteInterface()
        )
        XCTAssertTrue(item.contentType.conforms(to: .bundle))
    }

    func testItemUserInfoLockingPropsFileLocked() {
        let metadata = ItemMetadata()
        metadata.ocId = "test-id"
        metadata.etag = "test-etag"
        metadata.account = Self.account.ncKitAccount
        metadata.name = "test.txt"
        metadata.fileName = "test.txt"
        metadata.fileNameView = "test.txt"
        metadata.serverUrl = Self.account.davFilesUrl
        metadata.urlBase = Self.account.serverUrl
        metadata.userId = Self.account.username
        metadata.user = Self.account.username
        metadata.date = .init()
        metadata.size = 12
        metadata.lock = true
        metadata.lockOwner = Self.account.username
        metadata.lockOwnerEditor = "testEditor"
        metadata.lockTime = .init()
        metadata.lockTimeOut = .init().addingTimeInterval(6_000_000)

        let item = Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: MockRemoteInterface()
        )

        XCTAssertNotNil(item.userInfo?["locked"])

        let fileproviderItems = ["fileproviderItems": [item]]
        let lockPredicate = NSPredicate(
            format: "SUBQUERY ( fileproviderItems, $fileproviderItem, $fileproviderItem.userInfo.locked != nil ).@count > 0"
        )
        XCTAssertTrue(lockPredicate.evaluate(with: fileproviderItems))
    }

    func testItemUserInfoLockingPropsFileUnlocked() {
        let metadata = ItemMetadata()
        metadata.ocId = "test-id"
        metadata.etag = "test-etag"
        metadata.account = Self.account.ncKitAccount
        metadata.name = "test.txt"
        metadata.fileName = "test.txt"
        metadata.fileNameView = "test.txt"
        metadata.serverUrl = Self.account.davFilesUrl
        metadata.urlBase = Self.account.serverUrl
        metadata.userId = Self.account.username
        metadata.user = Self.account.username
        metadata.date = .init()
        metadata.size = 12

        let item = Item(
            metadata: metadata,
            parentItemIdentifier: .rootContainer,
            account: Self.account,
            remoteInterface: MockRemoteInterface()
        )

        XCTAssertNil(item.userInfo?["locked"])

        let fileproviderItems = ["fileproviderItems": [item]]
        let lockPredicate = NSPredicate(
            format: "SUBQUERY ( fileproviderItems, $fileproviderItem, $fileproviderItem.userInfo.locked == nil ).@count > 0"
        )
        XCTAssertTrue(lockPredicate.evaluate(with: fileproviderItems))
    }
}
