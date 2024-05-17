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

import FileProvider
import NextcloudKit
import OSLog

extension Enumerator {
    func fullRecursiveScan(
        ncAccount: Account, 
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        scanChangesOnly: Bool
    ) async -> (
        metadatas: [ItemMetadata],
        newMetadatas: [ItemMetadata],
        updatedMetadatas: [ItemMetadata],
        deletedMetadatas: [ItemMetadata],
        error: NKError?
    ) {
        let rootContainerDirectoryMetadata = ItemMetadata()
        rootContainerDirectoryMetadata.directory = true
        rootContainerDirectoryMetadata.ocId = NSFileProviderItemIdentifier.rootContainer.rawValue

        let results = await self.scanRecursively(
            rootContainerDirectoryMetadata,
            ncAccount: ncAccount,
            remoteInterface: remoteInterface,
            dbManager: dbManager,
            scanChangesOnly: scanChangesOnly
        )

        // Run a check to ensure files deleted in one location are not updated in another
        // (e.g. when moved)
        // The recursive scan provides us with updated/deleted metadatas only on a folder by
        // folder basis; so we need to check we are not simultaneously marking a moved file as
        // deleted and updated
        var checkedDeletedMetadatas = results.deletedMetadatas

        for updatedMetadata in results.updatedMetadatas {
            guard let matchingDeletedMetadataIdx = checkedDeletedMetadatas.firstIndex(
                where: { $0.ocId == updatedMetadata.ocId }
            ) else { continue }

            checkedDeletedMetadatas.remove(at: matchingDeletedMetadataIdx)
        }

        return (
            results.metadatas,
            results.newMetadatas,
            results.updatedMetadatas,
            checkedDeletedMetadatas, 
            results.error
        )
    }

    private func scanRecursively(
        _ directoryMetadata: ItemMetadata,
        ncAccount: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        scanChangesOnly: Bool
    ) async -> (
        metadatas: [ItemMetadata],
        newMetadatas: [ItemMetadata],
        updatedMetadatas: [ItemMetadata],
        deletedMetadatas: [ItemMetadata],
        error: NKError?
    ) {
        if isInvalidated {
            return ([], [], [], [], nil)
        }

        assert(directoryMetadata.directory, "Can only recursively scan a directory.")

        // Will include results of recursive calls
        var allMetadatas: [ItemMetadata] = []
        var allNewMetadatas: [ItemMetadata] = []
        var allUpdatedMetadatas: [ItemMetadata] = []
        var allDeletedMetadatas: [ItemMetadata] = []

        let itemServerUrl =
            directoryMetadata.ocId == NSFileProviderItemIdentifier.rootContainer.rawValue
                ? ncAccount.davFilesUrl
                : directoryMetadata.serverUrl + "/" + directoryMetadata.fileName

        Self.logger.debug("About to read: \(itemServerUrl, privacy: .public)")

        let (
            metadatas, newMetadatas, updatedMetadatas, deletedMetadatas, readError
        ) = await Self.readServerUrl(
            itemServerUrl,
            ncAccount: ncAccount,
            remoteInterface: remoteInterface,
            dbManager: dbManager,
            domain: domain,
            enumeratedItemIdentifier: enumeratedItemIdentifier,
            stopAtMatchingEtags: scanChangesOnly
        )

        if let readError, readError != .success {
            // Is the error is that we have found matching etags on this item, then ignore it
            // if we are doing a full rescan
            if readError.isNoChangesError && scanChangesOnly {
                Self.logger.info("No changes in \(self.serverUrl) and only scanning changes.")
            } else {
                Self.logger.error(
                    """
                    Finishing enumeration of changes at \(itemServerUrl, privacy: .public)
                    with \(readError.errorDescription, privacy: .public)
                    """
                )

                if readError.isNotFoundError {
                    Self.logger.info(
                        """
                        404 error means item no longer exists.
                        Deleting metadata and reporting as deletion without error
                        """
                    )

                    if let deletedMetadatas = dbManager.deleteDirectoryAndSubdirectoriesMetadata(
                        ocId: directoryMetadata.ocId
                    ) {
                        allDeletedMetadatas += deletedMetadatas
                    } else {
                        Self.logger.error(
                            """
                            An error occurred while trying to delete directory in database,
                            children not found in recursive scan
                            """
                        )
                    }

                } else if readError.isNoChangesError {  // All is well, just no changed etags
                    Self.logger.info(
                        "Error was to say no changed files, not bad error. Won't check children."
                    )

                } else if readError.isUnauthenticatedError || readError.isCouldntConnectError {
                    Self.logger.error(
                        "Error will affect next enumerated items, so stopping enumeration."
                    )
                    return ([], [] , [], [], readError)
                }
            }
        }

        Self.logger.info(
            """
            Finished reading serverUrl: \(itemServerUrl, privacy: .public)
            for user: \(ncAccount.ncKitAccount, privacy: .public)
            """
        )

        if let metadatas {
            allMetadatas += metadatas
        } else {
            Self.logger.warning(
                """
                Nil metadatas received in change read at \(itemServerUrl, privacy: .public)
                for user: \(ncAccount.ncKitAccount, privacy: .public)
                """
            )
        }

        if let newMetadatas {
            allNewMetadatas += newMetadatas
        } else {
            Self.logger.warning(
                """
                Nil new metadatas received in change read at \(itemServerUrl, privacy: .public)
                for user: \(ncAccount.ncKitAccount, privacy: .public)
                """
            )
        }

        if let updatedMetadatas {
            allUpdatedMetadatas += updatedMetadatas
        } else {
            Self.logger.warning(
                """
                Nil updated metadatas received in change read at \(itemServerUrl, privacy: .public)
                for user: \(ncAccount.ncKitAccount, privacy: .public)
                """
            )
        }

        if let deletedMetadatas {
            allDeletedMetadatas += deletedMetadatas
        } else {
            Self.logger.warning(
                """
                Nil deleted metadatas received in change read at \(itemServerUrl, privacy: .public)
                for user: \(ncAccount.ncKitAccount, privacy: .public)
                """
            )
        }

        var childDirectoriesToScan: [ItemMetadata] = []
        var candidateMetadatas: [ItemMetadata]

        if scanChangesOnly, fastEnumeration {
            candidateMetadatas = allUpdatedMetadatas
        } else if scanChangesOnly {
            candidateMetadatas = allUpdatedMetadatas + allNewMetadatas
        } else {
            candidateMetadatas = allMetadatas
        }

        for candidateMetadata in candidateMetadatas where candidateMetadata.directory {
            childDirectoriesToScan.append(candidateMetadata)
        }

        Self.logger.debug(
            "Candidate metadatas for further scan: \(candidateMetadatas, privacy: .public)"
        )

        if childDirectoriesToScan.isEmpty {
            return (
                metadatas: allMetadatas, 
                newMetadatas: allNewMetadatas,
                updatedMetadatas: allUpdatedMetadatas, 
                deletedMetadatas: allDeletedMetadatas,
                nil
            )
        }

        for childDirectory in childDirectoriesToScan {
            Self.logger.debug(
                """
                About to recursively scan: \(childDirectory.urlBase, privacy: .public)
                with etag: \(childDirectory.etag, privacy: .public)
                """
            )
            let childScanResult = await scanRecursively(
                childDirectory,
                ncAccount: ncAccount,
                remoteInterface: remoteInterface,
                dbManager: dbManager,
                scanChangesOnly: scanChangesOnly
            )

            allMetadatas += childScanResult.metadatas
            allNewMetadatas += childScanResult.newMetadatas
            allUpdatedMetadatas += childScanResult.updatedMetadatas
            allDeletedMetadatas += childScanResult.deletedMetadatas
        }

        return (
            metadatas: allMetadatas, newMetadatas: allNewMetadatas,
            updatedMetadatas: allUpdatedMetadatas,
            deletedMetadatas: allDeletedMetadatas, nil
        )
    }

    static func handleDepth1ReadFileOrFolder(
        serverUrl: String,
        ncAccount: Account,
        dbManager: FilesDatabaseManager,
        files: [NKFile]
    ) async -> (
        metadatas: [ItemMetadata]?,
        newMetadatas: [ItemMetadata]?,
        updatedMetadatas: [ItemMetadata]?,
        deletedMetadatas: [ItemMetadata]?,
        readError: NKError?
    ) {
        Self.logger.debug(
            """
            Starting async conversion of NKFiles for serverUrl: \(serverUrl, privacy: .public)
            for user: \(ncAccount.ncKitAccount, privacy: .public)
            """
        )


        let (directoryMetadata, metadatas) = await withCheckedContinuation { continuation in
            ItemMetadata.metadatasFromDirectoryReadNKFiles(
                files, account: ncAccount.ncKitAccount
            ) { directoryMetadata, _, metadatas in
                continuation.resume(returning: (directoryMetadata, metadatas))
            }
        }

        // STORE DATA FOR CURRENTLY SCANNED DIRECTORY
        // We have now scanned this directory's contents, so update with etag in order to not check 
        // again if not needed unless it's the root container
        if serverUrl != ncAccount.davFilesUrl {
            dbManager.addItemMetadata(directoryMetadata)
        }

        // Don't update the etags for folders as we haven't checked their contents.
        // When we do a recursive check, if we update the etags now, we will think
        // that our local copies are up to date -- instead, leave them as the old.
        // They will get updated when they are the subject of a readServerUrl call.
        // (See above)
        let changedMetadatas = dbManager.updateItemMetadatas(
            account: ncAccount.ncKitAccount,
            serverUrl: serverUrl,
            updatedMetadatas: metadatas,
            updateDirectoryEtags: false
        )

        return (
            metadatas,
            changedMetadatas.newMetadatas,
            changedMetadatas.updatedMetadatas,
            changedMetadatas.deletedMetadatas,
            nil
        )
    }

    static func readServerUrl(
        _ serverUrl: String,
        ncAccount: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        domain: NSFileProviderDomain? = nil,
        enumeratedItemIdentifier: NSFileProviderItemIdentifier? = nil,
        stopAtMatchingEtags: Bool = false,
        depth: EnumerateDepth = .targetAndDirectChildren
    ) async -> (
        metadatas: [ItemMetadata]?,
        newMetadatas: [ItemMetadata]?,
        updatedMetadatas: [ItemMetadata]?,
        deletedMetadatas: [ItemMetadata]?,
        readError: NKError?
    ) {
        let ncKitAccount = ncAccount.ncKitAccount

        Self.logger.debug(
            """
            Starting to read serverUrl: \(serverUrl, privacy: .public)
            for user: \(ncAccount.ncKitAccount, privacy: .public)
            at depth \(depth.rawValue, privacy: .public).
            username: \(ncAccount.username, privacy: .public),
            password is empty: \(ncAccount.password == "" ? "EMPTY" : "NOT EMPTY"),
            serverUrl: \(ncAccount.serverUrl, privacy: .public)
            """
        )

        let (_, files, _, error) = await remoteInterface.enumerate(
            remotePath: serverUrl,
            depth: depth,
            showHiddenFiles: true,
            includeHiddenFiles: [],
            requestBody: nil,
            options: .init(),
            taskHandler: { task in
                if let domain, let enumeratedItemIdentifier {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: enumeratedItemIdentifier,
                        completionHandler: { _ in }
                    )
                }
            }
        )

        guard error == .success else {
            Self.logger.error(
                """
                \(depth.rawValue, privacy: .public) depth read of url \(serverUrl, privacy: .public)
                did not complete successfully, error: \(error.errorDescription, privacy: .public)
                """
            )
            return (nil, nil, nil, nil, error)
        }

        guard let receivedFile = files.first else {
            Self.logger.error(
                """
                Received no items from readFileOrFolder of \(serverUrl, privacy: .public),
                not much we can do...
                """
            )
            return (nil, nil, nil, nil, error)
        }

        guard receivedFile.directory else {
            Self.logger.debug(
                """
                Read item is a file. Converting NKfile for serverUrl: \(serverUrl, privacy: .public)
                for user: \(ncAccount.ncKitAccount, privacy: .public)
                """
            )
            let itemMetadata = ItemMetadata.fromNKFile(receivedFile, account: ncKitAccount)
            dbManager.addItemMetadata(itemMetadata)  // TODO: Return some value when it is an update
            let inactiveItemMetadataCopy = ItemMetadata(value: itemMetadata)
            return ([inactiveItemMetadataCopy], nil, nil, nil, error)
        }

        if stopAtMatchingEtags, let directoryMetadata = dbManager.directoryMetadata(
            account: ncKitAccount, serverUrl: serverUrl
        ) {
            let directoryEtag = directoryMetadata.etag

            guard directoryEtag == "" || directoryEtag != receivedFile.etag else {
                Self.logger.debug(
                    """
                    Read server url called with flag to stop enumerating at matching etags.
                    Returning and providing soft error.
                    """
                )

                let description = "Fetched directory etag same as local copy. Ignoring child items."
                let nkError = NKError(
                    errorCode: NKError.noChangesErrorCode, errorDescription: description
                )
                let metadatas = dbManager.itemMetadatas(account: ncKitAccount, serverUrl: serverUrl)

                return (metadatas, nil, nil, nil, nkError)
            }
        }

        if depth == .target {
            if serverUrl == ncAccount.davFilesUrl {
                return (nil, nil, nil, nil, nil)
            } else {
                let metadata = ItemMetadata.fromNKFile(receivedFile, account: ncKitAccount)
                let isNew = dbManager.itemMetadataFromOcId(metadata.ocId) == nil
                let updatedMetadatas = isNew ? [] : [metadata]
                let newMetadatas = isNew ? [metadata] : []

                dbManager.addItemMetadata(metadata)

                return ([metadata], newMetadatas, updatedMetadatas, nil, nil)
            }
        } else {
            let (
                allMetadatas, newMetadatas, updatedMetadatas, deletedMetadatas, readError
            ) = await handleDepth1ReadFileOrFolder(
                serverUrl: serverUrl, 
                ncAccount: ncAccount,
                dbManager: dbManager,
                files: files
            )

            return (allMetadatas, newMetadatas, updatedMetadatas, deletedMetadatas, readError)
        }
    }
}
