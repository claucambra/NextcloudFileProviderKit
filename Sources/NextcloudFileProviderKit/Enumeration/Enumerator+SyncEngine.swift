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
    static func handlePagedReadResults(
        files: [NKFile], pageIndex: Int, dbManager: FilesDatabaseManager
    ) -> (metadatas: [SendableItemMetadata]?, error: NKError?) {
        // First PROPFIND contains the target item, but we do not want to report this in the
        // retrieved metadatas (the enumeration observers don't expect you to enumerate the
        // target item, hence why we always strip the target item out)
        let startIndex = pageIndex > 0 ? 0 : 1
        if pageIndex == 0 {
            guard let firstFile = files.first else { return (nil, .invalidResponseError) }
            // Do not ingest metadata for the root container
            if !firstFile.fullUrlMatches(dbManager.account.davFilesUrl),
               !firstFile.fullUrlMatches(dbManager.account.davFilesUrl + "/."),
               !(firstFile.fileName == "." && firstFile.serverUrl == "..")
            {
                var metadata = firstFile.toItemMetadata()
                if metadata.directory {
                    metadata.visitedDirectory = true
                    if let existingMetadata = dbManager.itemMetadata(ocId: metadata.ocId) {
                        metadata.downloaded = existingMetadata.downloaded
                    }
                }
                dbManager.addItemMetadata(metadata)
            }
        }
        let metadatas = files[startIndex..<files.count].map { $0.toItemMetadata() }
        metadatas.forEach { dbManager.addItemMetadata($0) }
        return (metadatas, nil)
    }

    // With paginated requests, you do not have a way to know what has changed remotely when
    // handling the result of an individual PROPFIND request. When handling a paginated read this
    // therefore only returns the acquired metadatas.
    static func handleDepth1ReadFileOrFolder(
        serverUrl: String,
        account: Account,
        dbManager: FilesDatabaseManager,
        files: [NKFile],
        pageIndex: Int?
    ) async -> (
        metadatas: [SendableItemMetadata]?,
        newMetadatas: [SendableItemMetadata]?,
        updatedMetadatas: [SendableItemMetadata]?,
        deletedMetadatas: [SendableItemMetadata]?,
        readError: NKError?
    ) {
        Self.logger.debug(
            """
            Starting async conversion of NKFiles for serverUrl: \(serverUrl, privacy: .public)
                for user: \(account.ncKitAccount, privacy: .public)
            """
        )

        if let pageIndex {
            let (metadatas, error) =
                handlePagedReadResults(files: files, pageIndex: pageIndex, dbManager: dbManager)
            return (metadatas, nil, nil, nil, error)
        }

        guard var (directoryMetadata, _, metadatas) =
            await files.toDirectoryReadMetadatas(account: account)
        else {
            Self.logger.error("Could not convert NKFiles to DirectoryReadMetadatas!")
            return (nil, nil, nil, nil, .invalidData)
        }

        // STORE DATA FOR CURRENTLY SCANNED DIRECTORY
        if serverUrl != account.davFilesUrl {
            if let existingMetadata = dbManager.itemMetadata(ocId: directoryMetadata.ocId) {
                directoryMetadata.downloaded = existingMetadata.downloaded
            }
            directoryMetadata.visitedDirectory = true
        }

        metadatas.insert(directoryMetadata, at: 0)

        let changedMetadatas = dbManager.depth1ReadUpdateItemMetadatas(
            account: account.ncKitAccount,
            serverUrl: serverUrl,
            updatedMetadatas: metadatas,
            keepExistingDownloadState: true
        )

        return (
            metadatas,
            changedMetadatas.newMetadatas,
            changedMetadatas.updatedMetadatas,
            changedMetadatas.deletedMetadatas,
            nil
        )
    }

    // READ THIS CAREFULLY.
    //
    // This method supports paginated and non-paginated reads. Handled by the pageSettings argument.
    // Paginated reads is used by enumerateItems, non-paginated reads is used by enumerateChanges.
    //
    // Paginated reads WILL NOT HANDLE REMOVAL OF REMOTELY DELETED ITEMS FROM THE LOCAL DATABASE.
    // Paginated reads WILL ONLY REPORT THE FILES DISCOVERED REMOTELY.
    // This means that if you decide to use this method to implement change enumeration, you will
    // have to collect the full results of all the pages before proceeding with discovering what
    // has changed relative to the state of the local database -- manually!
    //
    // Non-paginated reads will update the database with all of the discovered files and folders
    // that have been found to be created, updated, and deleted. No extra work required.
    static func readServerUrl(
        _ serverUrl: String,
        pageSettings: (page: NSFileProviderPage?, index: Int, size: Int)? = nil,
        account: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        domain: NSFileProviderDomain? = nil,
        enumeratedItemIdentifier: NSFileProviderItemIdentifier? = nil,
        depth: EnumerateDepth = .targetAndDirectChildren
    ) async -> (
        metadatas: [SendableItemMetadata]?,
        newMetadatas: [SendableItemMetadata]?,
        updatedMetadatas: [SendableItemMetadata]?,
        deletedMetadatas: [SendableItemMetadata]?,
        nextPage: EnumeratorPageResponse?,
        readError: NKError?
    ) {
        let ncKitAccount = account.ncKitAccount

        Self.logger.debug(
            """
            Starting to read serverUrl: \(serverUrl, privacy: .public)
                for user: \(ncKitAccount, privacy: .public)
                at depth \(depth.rawValue, privacy: .public).
                username: \(account.username, privacy: .public),
                password is empty: \(account.password == "" ? "EMPTY" : "NOT EMPTY"),
                pageToken: \(String(data: pageSettings?.page?.rawValue ?? Data(), encoding: .utf8) ?? "NIL", privacy: .public)
                pageIndex: \(pageSettings?.index ?? -1, privacy: .public)
                pageSize: \(pageSettings?.size ?? -1, privacy: .public)
                serverUrl: \(account.serverUrl, privacy: .public)
            """
        )

        let options: NKRequestOptions
        if let pageSettings {
            options = .init(
                page: pageSettings.page,
                offset: pageSettings.index * pageSettings.size,
                count: pageSettings.size
            )
        } else {
            options = .init()
        }

        let (_, files, data, error) = await remoteInterface.enumerate(
            remotePath: serverUrl,
            depth: depth,
            showHiddenFiles: true,
            includeHiddenFiles: [],
            requestBody: nil,
            account: account,
            options: options,
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
            return (nil, nil, nil, nil, nil, error)
        }

        guard let data else {
            Self.logger.error(
                """
                \(depth.rawValue, privacy: .public) depth read of url \(serverUrl, privacy: .public)
                    did not return data.
                """
            )
            return (nil, nil, nil, nil, nil, error)
        }

        // This will be nil if the page settings were also nil, as the server will not give us the
        // pagination-related headers.
        let nextPage = EnumeratorPageResponse(
            nkResponseData: data, index: (pageSettings?.index ?? 0) + 1
        )

        guard let receivedFile = files.first else {
            Self.logger.error(
                """
                Received no items from readFileOrFolder of \(serverUrl, privacy: .public),
                    not much we can do...
                """
            )
            // This is technically possible when doing a paginated request with the index too high.
            // It's technically not an error reply.
            return ([], nil, nil, nil, nextPage, nil)
        }

        // Generally speaking a PROPFIND will provide the target of the PROPFIND as the first result
        // That is NOT the case for paginated results with offsets
        let isFollowUpPaginatedRequest = (pageSettings?.page != nil && pageSettings?.index ?? 0 > 0)
        if !isFollowUpPaginatedRequest {
            guard receivedFile.directory ||
                  serverUrl == dbManager.account.davFilesUrl ||
                  receivedFile.fullUrlMatches(dbManager.account.davFilesUrl + "/.") ||
                  (receivedFile.fileName == "." && receivedFile.serverUrl == "..")
            else {
                Self.logger.debug(
                    """
                    Read item is a file.
                        Converting NKfile for serverUrl: \(serverUrl, privacy: .public)
                        for user: \(account.ncKitAccount, privacy: .public)
                    """
                )
                var metadata = receivedFile.toItemMetadata()
                let existing = dbManager.itemMetadata(ocId: metadata.ocId)
                let isNew = existing == nil
                let newItems: [SendableItemMetadata] = isNew ? [metadata] : []
                let updatedItems: [SendableItemMetadata] = isNew ? [] : [metadata]
                metadata.downloaded = existing?.downloaded == true
                dbManager.addItemMetadata(metadata)
                return ([metadata], newItems, updatedItems, nil, nextPage, nil)
            }
        }

        if depth == .target {
            if serverUrl == account.davFilesUrl {
                return (nil, nil, nil, nil, nextPage, nil)
            } else {
                var metadata = receivedFile.toItemMetadata()
                let existing = dbManager.itemMetadata(ocId: metadata.ocId)
                let isNew = existing == nil
                let updatedMetadatas = isNew ? [] : [metadata]
                let newMetadatas = isNew ? [metadata] : []

                metadata.downloaded = existing?.downloaded == true
                dbManager.addItemMetadata(metadata)

                return ([metadata], newMetadatas, updatedMetadatas, nil, nextPage, nil)
            }
        } else if depth == .targetAndDirectChildren {
            let (
                allMetadatas, newMetadatas, updatedMetadatas, deletedMetadatas, readError
            ) = await handleDepth1ReadFileOrFolder(
                serverUrl: serverUrl, 
                account: account,
                dbManager: dbManager,
                files: files,
                pageIndex: pageSettings?.index
            )

            return (allMetadatas, newMetadatas, updatedMetadatas, deletedMetadatas, nextPage, readError)
        } else if let pageIndex = pageSettings?.index {
            let (metadatas, error) = handlePagedReadResults(
                files: files, pageIndex: pageIndex, dbManager: dbManager
            )
            return (metadatas, nil, nil, nil, nextPage, error)
        } else {
            // Infinite depth unpaged reads are a bad idea
            return (nil, nil, nil, nil, nil, .invalidResponseError)
        }
    }
}
