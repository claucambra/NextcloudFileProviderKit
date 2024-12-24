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
    private func fetchDirectoryContents(
        directoryLocalPath: String,
        directoryRemotePath: String,
        domain: NSFileProviderDomain?,
        progress: Progress
    ) async throws {
        progress.totalUnitCount = 1 // Add 1 for final procedures

        // Download *everything* within this directory. What we do:
        // 1. Enumerate the contents of the directory
        // 2. Download everything within this directory
        // 3. Detect child directories
        // 4. Repeat 1 -> 3 for each child directory
        var remoteDirectoryPaths = [directoryRemotePath]
        while !remoteDirectoryPaths.isEmpty {
            let remoteDirectoryPath = remoteDirectoryPaths.removeFirst()
            let (metadatas, _, _, _, readError) = await Enumerator.readServerUrl(
                remoteDirectoryPath,
                account: account,
                remoteInterface: remoteInterface,
                dbManager: dbManager
            )

            if let readError, readError != .success {
                Self.logger.error(
                    """
                    Could not enumerate directory contents for
                    \(self.metadata.fileName, privacy: .public)
                    at \(remoteDirectoryPath, privacy: .public)
                    error: \(readError.errorCode, privacy: .public)
                    \(readError.errorDescription, privacy: .public)
                    """
                )
                throw readError.fileProviderError ?? NSFileProviderError(.cannotSynchronize)
            }

            guard let metadatas else {
                Self.logger.error(
                    """
                    Could not fetch directory contents for
                    \(self.metadata.fileName, privacy: .public)
                    at \(remoteDirectoryPath, privacy: .public), received nil metadatas
                    """
                )
                throw NSFileProviderError(.cannotSynchronize)
            }

            progress.totalUnitCount += Int64(metadatas.count)

            for metadata in metadatas {
                let remotePath = metadata.serverUrl + "/" + metadata.fileName
                let relativePath =
                    remotePath.replacingOccurrences(of: directoryRemotePath, with: "")
                let childLocalPath = directoryLocalPath + relativePath

                if metadata.directory {
                    remoteDirectoryPaths.append(remotePath)
                    try FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: childLocalPath),
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } else {
                    let (_, _, _, _, _, _, error) = await remoteInterface.download(
                        remotePath: remotePath,
                        localPath: childLocalPath,
                        account: account,
                        options: .init(),
                        requestHandler: { progress.setHandlersFromAfRequest($0) },
                        taskHandler: { task in
                            if let domain {
                                NSFileProviderManager(for: domain)?.register(
                                    task,
                                    forItemWithIdentifier: 
                                        NSFileProviderItemIdentifier(metadata.ocId),
                                    completionHandler: { _ in }
                                )
                            }
                        },
                        progressHandler: { _ in }
                    )

                    guard error == .success else {
                        Self.logger.error(
                        """
                        Could not acquire contents of item: \(metadata.fileName, privacy: .public)
                        at \(remotePath, privacy: .public)
                        error: \(error.errorCode, privacy: .public)
                        \(error.errorDescription, privacy: .public)
                        """
                        )
                        metadata.status = ItemMetadata.Status.downloadError.rawValue
                        metadata.sessionError = error.errorDescription
                        dbManager.addItemMetadata(metadata)
                        throw error.fileProviderError ?? NSFileProviderError(.cannotSynchronize)
                    }
                }

                metadata.status = ItemMetadata.Status.normal.rawValue
                metadata.downloaded = true
                metadata.sessionError = ""
                dbManager.addItemMetadata(metadata)

                progress.completedUnitCount += 1
            }
        }

        progress.completedUnitCount += 1 // Finish off
    }

    func fetchContents(
        domain: NSFileProviderDomain? = nil,
        progress: Progress = .init(),
        dbManager: FilesDatabaseManager = .shared
    ) async -> (URL?, Item?, Error?) {
        let ocId = itemIdentifier.rawValue
        let serverUrlFileName = metadata.serverUrl + "/" + metadata.fileName

        Self.logger.debug(
            """
            Fetching item with name \(self.filename, privacy: .public)
            at URL: \(serverUrlFileName, privacy: .public)
            """
        )

        let localPath = FileManager.default.temporaryDirectory.appendingPathComponent(metadata.ocId)
        guard let managedMetadata = dbManager.itemMetadata(ocId: ocId),
              let db = managedMetadata.realm
        else {
            Self.logger.error(
                """
                Could not acquire updated metadata of item \(ocId, privacy: .public),
                unable to update item status to downloading
                """
            )
            return (nil, nil, NSFileProviderError(.noSuchItem))
        }
        dbManager.applyStatus(on: managedMetadata, status: .downloading)

        func finaliseDownloadErrorState(message: String) {
            do {
                try db.write {
                    managedMetadata.status = ItemMetadata.Status.downloadError.rawValue
                    managedMetadata.sessionError = message
                }
            } catch let error {
                Self.logger.error(
                    """
                    Could not set download error status on item.
                        \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }

        if contentType.conforms(to: .directory) {
            Self.logger.debug(
                """
                Item with identifier: \(ocId, privacy: .public)
                and filename: \(self.filename, privacy: .public)
                is a directory, creating dir locally and fetching its contents
                """
            )

            do {
                try FileManager.default.createDirectory(
                    at: localPath,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch let error {
                Self.logger.error(
                    """
                    Could not create directory for item with identifier: \(ocId, privacy: .public)
                    and fileName: \(self.filename, privacy: .public)
                    at \(localPath, privacy: .public)
                    error: \(error.localizedDescription, privacy: .public)
                    """
                )

                finaliseDownloadErrorState(message: error.localizedDescription)
                return (nil, nil, error)
            }

            do {
                try await fetchDirectoryContents(
                    directoryLocalPath: localPath.path,
                    directoryRemotePath: serverUrlFileName,
                    domain: domain,
                    progress: progress
                )
            } catch let error {
                Self.logger.error(
                    """
                    Could not fetch directory contents for \(ocId, privacy: .public)
                    and fileName: \(self.filename, privacy: .public)
                    at \(serverUrlFileName, privacy: .public)
                    error: \(error.localizedDescription, privacy: .public)
                    """
                )

                finaliseDownloadErrorState(message: error.localizedDescription)
                return (nil, nil, error)
            }

        } else {
            let (_, _, _, _, _, _, error) = await remoteInterface.download(
                remotePath: serverUrlFileName,
                localPath: localPath.path,
                account: account,
                options: .init(),
                requestHandler: { _ in },
                taskHandler: { _ in },
                progressHandler: { _ in }
            )

            if error != .success {
                Self.logger.error(
                    """
                    Could not acquire contents of item with identifier: \(ocId, privacy: .public)
                    and fileName: \(self.filename, privacy: .public)
                    at \(serverUrlFileName, privacy: .public)
                    error: \(error.errorCode, privacy: .public)
                    \(error.errorDescription, privacy: .public)
                    """
                )

                finaliseDownloadErrorState(message: error.errorDescription)
                return (nil, nil, error.fileProviderError)
            }
        }

        Self.logger.debug(
            """
            Acquired contents of item with identifier: \(ocId, privacy: .public)
            and filename: \(self.filename, privacy: .public)
            """
        )

        do {
            try db.write {
                managedMetadata.status = ItemMetadata.Status.normal.rawValue
                managedMetadata.downloaded = true
                managedMetadata.sessionError = ""
            }
        } catch let error {
            Self.logger.error(
                """
                Could not set successful download state on item.
                    ocId: \(ocId, privacy: .public)
                    filename: \(self.filename, privacy: .public)
                    error: \(error.localizedDescription, privacy: .public)
                """
            )
        }

        guard let parentItemIdentifier = dbManager.parentItemIdentifierFromMetadata(
            managedMetadata
        ) else {
            Self.logger.error(
                """
                Could not find parent item id for file \(self.metadata.fileName, privacy: .public)
                """
            )
            return (nil, nil, NSFileProviderError(.noSuchItem))
        }

        let fpItem = Item(
            metadata: managedMetadata,
            parentItemIdentifier: parentItemIdentifier,
            account: account,
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
            url: thumbnailUrl, account: account, options: .init(), taskHandler: { task in
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
