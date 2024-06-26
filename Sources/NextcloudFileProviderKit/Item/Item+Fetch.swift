//
//  Item+Fetch.swift
//
//
//  Created by Claudio Cambra on 16/4/24.
//

import FileProvider
import Foundation
import NextcloudKit
import OSLog

public extension Item {
    
    func fetchContents(
        domain: NSFileProviderDomain? = nil,
        progress: Progress = .init(),
        dbManager: FilesDatabaseManager = .shared
    ) async -> (URL?, Item?, Error?) {
        let ocId = itemIdentifier.rawValue
        let serverUrlFileName = metadata.serverUrl + "/" + metadata.fileName

        Self.logger.debug(
            """
            Fetching file with name \(self.metadata.fileName, privacy: .public)
            at URL: \(serverUrlFileName, privacy: .public)
            """
        )

        let localPath = FileManager.default.temporaryDirectory.appendingPathComponent(metadata.ocId)
        let updatedMetadata = await withCheckedContinuation { continuation in
            dbManager.setStatusForItemMetadata(metadata, status: .downloading) { updatedMeta in
                continuation.resume(returning: updatedMeta)
            }
        }

        guard let updatedMetadata = updatedMetadata else {
            Self.logger.error(
                """
                Could not acquire updated metadata of item \(ocId, privacy: .public),
                unable to update item status to downloading
                """
            )
            return (nil, nil, NSFileProviderError(.noSuchItem))
        }

        let (_, etag, date, _, _, _, error) = await remoteInterface.download(
            remotePath: serverUrlFileName,
            localPath: localPath.path,
            options: .init(),
            requestHandler: { progress.setHandlersFromAfRequest($0) },
            taskHandler: { task in
                if let domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: self.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }, progressHandler: { $0.copyCurrentStateToProgress(progress) }
        )

        if error != .success {
            Self.logger.error(
                """
                Could not acquire contents of item with identifier: \(ocId, privacy: .public)
                and fileName: \(updatedMetadata.fileName, privacy: .public)
                at \(serverUrlFileName, privacy: .public)
                error: \(error.errorCode, privacy: .public)
                \(error.errorDescription, privacy: .public)
                """
            )

            updatedMetadata.status = ItemMetadata.Status.downloadError.rawValue
            updatedMetadata.sessionError = error.errorDescription
            dbManager.addItemMetadata(updatedMetadata)
            return (nil, nil, error.fileProviderError)
        }

        Self.logger.debug(
            """
            Acquired contents of item with identifier: \(ocId, privacy: .public)
            and filename: \(updatedMetadata.fileName, privacy: .public)
            """
        )

        updatedMetadata.status = ItemMetadata.Status.normal.rawValue
        updatedMetadata.sessionError = ""
        updatedMetadata.date = (date ?? NSDate()) as Date
        updatedMetadata.etag = etag ?? ""

        dbManager.addLocalFileMetadataFromItemMetadata(updatedMetadata)
        dbManager.addItemMetadata(updatedMetadata)

        guard let parentItemIdentifier = dbManager.parentItemIdentifierFromMetadata(
            updatedMetadata
        ) else {
            Self.logger.error(
                """
                Could not find parent item id for file \(self.metadata.fileName, privacy: .public)
                """
            )
            return (nil, nil, NSFileProviderError(.noSuchItem))
        }

        let fpItem = Item(
            metadata: updatedMetadata,
            parentItemIdentifier: parentItemIdentifier,
            remoteInterface: remoteInterface
        )

        return (localPath, fpItem, nil)
    }

    func fetchThumbnail(
        size: CGSize, domain: NSFileProviderDomain? = nil
    ) async -> (Data?, Error?) {
        guard let thumbnailUrl = metadata.thumbnailUrl(size: size) else {
            Self.logger.debug(
                """
                Unknown thumbnail URL for: \(self.itemIdentifier.rawValue, privacy: .public)
                fileName: \(self.filename, privacy: .public)
                """
            )
            return (nil, NSFileProviderError(.noSuchItem))
        }

        Self.logger.debug(
            """
            Fetching thumbnail for: \(self.filename, privacy: .public)
            at (\(thumbnailUrl, privacy: .public))
            """
        )

        let (_, data, error) = await remoteInterface.downloadThumbnail(
            url: thumbnailUrl, options: .init(), taskHandler: { task in
                if let domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: self.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }
        )

        if error != .success {
            Self.logger.error(
                """
                Could not acquire thumbnail for item with identifier: 
                \(self.itemIdentifier.rawValue, privacy: .public)
                and fileName: \(self.filename, privacy: .public)
                at \(thumbnailUrl, privacy: .public)
                error: \(error.errorCode, privacy: .public)
                \(error.errorDescription, privacy: .public)
                """
            )
        }

        return (data, error.fileProviderError)
    }
}
