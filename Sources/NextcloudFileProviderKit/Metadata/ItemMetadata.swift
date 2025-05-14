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

import Foundation

public enum Status: Int {
    case downloadError = -4
    case downloading = -3
    case inDownload = -2

    case normal = 0

    case inUpload = 2
    case uploading = 3
    case uploadError = 4
}

public enum SharePermissions: Int {
    case readShare = 1
    case updateShare = 2
    case createShare = 4
    case deleteShare = 8
    case shareShare = 16

    case maxFileShare = 19
    case maxFolderShare = 31
}

public protocol ItemMetadata: Equatable {
    var ocId: String { get set }
    var account: String { get set }
    var checksums: String { get set }
    var chunkUploadId: String? { get set }
    var classFile: String { get set }
    var commentsUnread: Bool { get set }
    var contentType: String { get set }
    var creationDate: Date { get set }
    var dataFingerprint: String { get set }
    var date: Date { get set }
    var directory: Bool { get set }
    var downloadURL: String { get set }
    var e2eEncrypted: Bool { get set }
    var etag: String { get set }
    var favorite: Bool { get set }
    var fileId: String { get set }
    var fileName: String { get set } // What the file's real file name is
    var fileNameView: String { get set } // What the user sees (usually same as fileName)
    var hasPreview: Bool { get set }
    var hidden: Bool { get set }
    var iconName: String { get set }
    var iconUrl: String { get set }
    var mountType: String { get set }
    var name: String { get set }  // for unifiedSearch is the provider.id
    var note: String { get set }
    var ownerId: String { get set }
    var ownerDisplayName: String { get set }
    var livePhotoFile: String? { get set }
    var lock: Bool { get set }
    var lockOwner: String? { get set }
    var lockOwnerEditor: String? { get set }
    var lockOwnerType: Int? { get set }
    var lockOwnerDisplayName: String? { get set }
    var lockTime: Date? { get set } // Time the file was locked
    var lockTimeOut: Date? { get set } // Time the file's lock will expire
    var path: String { get set }
    var permissions: String { get set }
    var shareType: [Int] { get set }
    var quotaUsedBytes: Int64 { get set }
    var quotaAvailableBytes: Int64 { get set }
    var resourceType: String { get set }
    var richWorkspace: String? { get set }
    var serverUrl: String { get set }  // For parent folder! Build remote url by adding fileName
    var session: String? { get set }
    var sessionError: String? { get set }
    var sessionTaskIdentifier: Int? { get set }
    var sharePermissionsCollaborationServices: Int { get set }
    // TODO: Find a way to compare these two below in remote state check
    var sharePermissionsCloudMesh: [String] { get set }
    var size: Int64 { get set }
    var status: Int { get set }
    var tags: [String] { get set }
    var downloaded: Bool { get set }
    var uploaded: Bool { get set }
    var keepDownloaded: Bool { get set }
    var trashbinFileName: String { get set }
    var trashbinOriginalLocation: String { get set }
    var trashbinDeletionTime: Date { get set }
    var uploadDate: Date { get set }
    var urlBase: String { get set }
    var user: String { get set } // The user who owns the file (Nextcloud username)
    var userId: String { get set } // The user who owns the file (backend user id)
                                   // (relevant for alt. backends like LDAP)
}

public extension ItemMetadata {
    var livePhoto: Bool {
        livePhotoFile != nil && livePhotoFile?.isEmpty == false
    }

    var isDownloadUpload: Bool {
        status == Status.inDownload.rawValue || status == Status.downloading.rawValue
            || status == Status.inUpload.rawValue || status == Status.uploading.rawValue
    }

    var isDownload: Bool {
        status == Status.inDownload.rawValue || status == Status.downloading.rawValue
    }

    var isUpload: Bool {
        status == Status.inUpload.rawValue || status == Status.uploading.rawValue
    }

    var isTrashed: Bool {
        serverUrl.hasPrefix(urlBase + Account.webDavTrashUrlSuffix + userId + "/trash")
    }

    mutating func apply(fileName: String) {
        self.fileName = fileName
        fileNameView = fileName
        name = fileName
    }

    mutating func apply(account: Account) {
        self.account = account.ncKitAccount
        user = account.username
        userId = account.id
        urlBase = account.serverUrl
    }

    func isInSameDatabaseStoreableRemoteState(_ comparingMetadata: any ItemMetadata)
        -> Bool
    {
        comparingMetadata.etag == etag
            && comparingMetadata.fileNameView == fileNameView
            && comparingMetadata.date == date
            && comparingMetadata.permissions == permissions
            && comparingMetadata.hasPreview == hasPreview
            && comparingMetadata.note == note
            && comparingMetadata.lock == lock
            && comparingMetadata.sharePermissionsCollaborationServices
                == sharePermissionsCollaborationServices
            && comparingMetadata.favorite == favorite
    }

    /// Returns false if the user is lokced out of the file. I.e. The file is locked but by someone else
    func canUnlock(as user: String) -> Bool {
        !lock || (lockOwner == user && lockOwnerType == 0)
    }

    func thumbnailUrl(size: CGSize) -> URL? {
        guard hasPreview else {
            return nil
        }

        let urlBase = urlBase.urlEncoded!
        // Leave the leading slash in webdavUrl
        let webdavUrl = urlBase + Account.webDavFilesUrlSuffix + user
        let serverFileRelativeUrl =
            serverUrl.replacingOccurrences(of: webdavUrl, with: "") + "/" + fileName

        let urlString =
            "\(urlBase)/index.php/core/preview.png?file=\(serverFileRelativeUrl)&x=\(size.width)&y=\(size.height)&a=1&mode=cover"
        return URL(string: urlString)
    }
}
