//
//  NKFile+Extensions.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-02.
//

import Foundation
import NextcloudKit
import RealmSwift

extension NKFile {
    func toItemMetadata(uploaded: Bool = true) -> SendableItemMetadata {
        let creationDate = creationDate ?? date
        let uploadDate = uploadDate ?? date
        let classFile = (contentType == "text/markdown" || contentType == "text/x-markdown")
            && classFile == NKCommon.TypeClassFile.unknow.rawValue
                ? NKCommon.TypeClassFile.document.rawValue
                : classFile
        // Support for finding the correct filename for e2ee files should go here

        return SendableItemMetadata(
            ocId: ocId,
            account: account,
            checksums: checksums,
            classFile: classFile,
            commentsUnread: commentsUnread,
            contentType: contentType,
            creationDate: creationDate as Date,
            dataFingerprint: dataFingerprint,
            date: date as Date,
            directory: directory,
            downloadURL: downloadURL,
            e2eEncrypted: e2eEncrypted,
            etag: etag,
            favorite: favorite,
            fileId: fileId,
            fileName: fileName,
            fileNameView: fileName,
            hasPreview: hasPreview,
            hidden: hidden,
            iconName: iconName,
            livePhotoFile: livePhotoFile,
            mountType: mountType,
            name: name,
            note: note,
            ownerId: ownerId,
            ownerDisplayName: ownerDisplayName,
            lock: lock,
            lockOwner: lockOwner,
            lockOwnerEditor: lockOwnerEditor,
            lockOwnerType: lockOwnerType,
            lockOwnerDisplayName: lockOwnerDisplayName,
            lockTime: lockTime,
            lockTimeOut: lockTimeOut,
            path: path,
            permissions: permissions,
            quotaUsedBytes: quotaUsedBytes,
            quotaAvailableBytes: quotaAvailableBytes,
            resourceType: resourceType,
            richWorkspace: richWorkspace,
            serverUrl: serverUrl,
            sharePermissionsCollaborationServices: sharePermissionsCollaborationServices,
            sharePermissionsCloudMesh: sharePermissionsCloudMesh,
            shareType: shareType,
            size: size,
            tags: tags,
            uploaded: uploaded,
            trashbinFileName: trashbinFileName,
            trashbinOriginalLocation: trashbinOriginalLocation,
            trashbinDeletionTime: trashbinDeletionTime,
            uploadDate: uploadDate as Date,
            urlBase: urlBase,
            user: user,
            userId: userId
        )
    }
}



extension Array<NKFile> {
    private final actor DirectoryReadConversionActor: Sendable {
        let directoryMetadata: SendableItemMetadata
        var childDirectoriesMetadatas: [SendableItemMetadata] = []
        var metadatas: [SendableItemMetadata] = []

        func convertedMetadatas() -> (
            SendableItemMetadata, [SendableItemMetadata], [SendableItemMetadata]
        ) {
            (directoryMetadata, childDirectoriesMetadatas, metadatas)
        }

        init(target: SendableItemMetadata) {
            self.directoryMetadata = target
        }

        func add(metadata: SendableItemMetadata) {
            metadatas.append(metadata)
            if metadata.directory {
                childDirectoriesMetadatas.append(metadata)
            }
        }
    }

    func toDirectoryReadMetadatas(account: Account) async -> (
        directoryMetadata: SendableItemMetadata,
        childDirectoriesMetadatas: [SendableItemMetadata],
        metadatas: [SendableItemMetadata]
    )? {
        guard let targetDirectoryMetadata = first?.toItemMetadata() else {
            return nil
        }
        let conversionActor = DirectoryReadConversionActor(target: targetDirectoryMetadata)
        await concurrentChunkedForEach { file in
            guard file.ocId != targetDirectoryMetadata.ocId else { return }
            await conversionActor.add( metadata: file.toItemMetadata())
        }
        return await conversionActor.convertedMetadatas()
    }
}
