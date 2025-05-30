/*
 * Copyright (C) 2022 by Claudio Cambra <claudio.cambra@nextcloud.com>
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

public class Enumerator: NSObject, NSFileProviderEnumerator {
    let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private var enumeratedItemMetadata: SendableItemMetadata?
    private var enumeratingSystemIdentifier: Bool {
        Self.isSystemIdentifier(enumeratedItemIdentifier)
    }
    let domain: NSFileProviderDomain?
    let dbManager: FilesDatabaseManager

    // TODO: actually use this in NCKit and server requests
    private let anchor = NSFileProviderSyncAnchor(Date().description.data(using: .utf8)!)
    private static let maxItemsPerFileProviderPage = 100
    let account: Account
    let remoteInterface: RemoteInterface
    let fastEnumeration: Bool
    var serverUrl: String = ""
    var isInvalidated = false
    weak var listener: EnumerationListener?

    private static func isSystemIdentifier(_ identifier: NSFileProviderItemIdentifier) -> Bool {
        identifier == .rootContainer || identifier == .trashContainer || identifier == .workingSet
    }

    public init(
        enumeratedItemIdentifier: NSFileProviderItemIdentifier,
        account: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager = .shared,
        domain: NSFileProviderDomain? = nil,
        fastEnumeration: Bool = true,
        listener: EnumerationListener? = nil
    ) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.remoteInterface = remoteInterface
        self.account = account
        self.dbManager = dbManager
        self.domain = domain
        self.fastEnumeration = fastEnumeration
        self.listener = listener

        if Self.isSystemIdentifier(enumeratedItemIdentifier) {
            serverUrl = account.davFilesUrl
        } else {
            enumeratedItemMetadata = dbManager.itemMetadataFromFileProviderItemIdentifier(
                enumeratedItemIdentifier)
            if let enumeratedItemMetadata {
                serverUrl =
                    enumeratedItemMetadata.serverUrl + "/" + enumeratedItemMetadata.fileName
            } else {
            }
        }

        super.init()
    }

    public func invalidate() {
        isInvalidated = true
    }

    // MARK: - Protocol methods

    public func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        let actionId = UUID()
        listener?.enumerationActionStarted(actionId: actionId)

        /*
         - inspect the page to determine whether this is an initial or a follow-up request (TODO)

         If this is an enumerator for a directory, the root container or all directories:
         - perform a server request to fetch directory contents
         If this is an enumerator for the working set:
         - perform a server request to update your local database
         - fetch the working set from your local database

         - inform the observer about the items returned by the server (possibly multiple times)
         - inform the observer that you are finished with this page
         */

        if enumeratedItemIdentifier == .trashContainer {
            Task {
                let (_, trashedItems, _, trashReadError) = await remoteInterface.trashedItems(
                    account: account,
                    options: .init(),
                    taskHandler: { task in
                        if let domain = self.domain {
                            NSFileProviderManager(for: domain)?.register(
                                task,
                                forItemWithIdentifier: self.enumeratedItemIdentifier,
                                completionHandler: { _ in }
                            )
                        }
                    }
                )

                guard trashReadError == .success else {
                    let error =
                        trashReadError.fileProviderError ?? NSFileProviderError(.cannotSynchronize)
                    listener?.enumerationActionFailed(actionId: actionId, error: error)
                    observer.finishEnumeratingWithError(error)
                    return
                }

                Self.completeEnumerationObserver(
                    observer,
                    account: account,
                    remoteInterface: remoteInterface,
                    dbManager: dbManager,
                    numPage: 1,
                    trashItems: trashedItems
                )
                listener?.enumerationActionFinished(actionId: actionId)
            }
            return
        }

        // Handle the working set as if it were the root container
        // If we do a full server scan per the recommendations of the File Provider documentation,
        // we will be stuck for a huge period of time without being able to access files as the
        // entire server gets scanned. Instead, treat the working set as the root container here.
        // Then, when we enumerate changes, we'll go through everything -- while we can still
        // navigate a little bit in Finder, file picker, etc

        guard serverUrl != "" else {
            listener?.enumerationActionFailed(
                actionId: actionId, error: NSFileProviderError(.noSuchItem)
            )
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }

        // TODO: Make better use of pagination and handle paging properly
        if page == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage
            || page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        {
            Task {
                let (metadatas, _, _, _, readError) = await Self.readServerUrl(
                    serverUrl,
                    account: account,
                    remoteInterface: remoteInterface,
                    dbManager: dbManager
                )

                guard readError == nil else {
                    // TODO: Refactor for conciseness
                    let error =
                        readError?.fileProviderError ?? NSFileProviderError(.cannotSynchronize)
                    listener?.enumerationActionFailed(actionId: actionId, error: error)
                    observer.finishEnumeratingWithError(error)
                    return
                }

                guard let metadatas else {
                    listener?.enumerationActionFailed(
                        actionId: actionId, error: NSFileProviderError(.cannotSynchronize)
                    )
                    observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize))
                    return
                }

                Self.completeEnumerationObserver(
                    observer,
                    account: account,
                    remoteInterface: remoteInterface,
                    dbManager: dbManager,
                    numPage: 1,
                    itemMetadatas: metadatas
                )
                listener?.enumerationActionFinished(actionId: actionId)
            }

            return
        }

        let numPage = Int(String(data: page.rawValue, encoding: .utf8)!)!
        // TODO: Handle paging properly
        // Self.completeObserver(observer, ncKit: ncKit, numPage: numPage, itemMetadatas: nil)
        listener?.enumerationActionFinished(actionId: actionId)
        observer.finishEnumerating(upTo: nil)
    }

    public func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        let actionId = UUID()
        listener?.enumerationActionStarted(actionId: actionId)

        /*
         - query the server for updates since the passed-in sync anchor (TODO)

         If this is an enumerator for the working set:
         - note the changes in your local database

         - inform the observer about item deletions and updates (modifications + insertions)
         - inform the observer when you have finished enumerating up to a subsequent sync anchor
         */

        if enumeratedItemIdentifier == .workingSet {
            // Unlike when enumerating items we can't progressively enumerate items as we need to 
            // wait to see which items are truly deleted and which have just been moved elsewhere.
            Task {
                let (
                    _, newMetadatas, updatedMetadatas, deletedMetadatas, error
                ) = await fullRecursiveScan(
                    account: account,
                    remoteInterface: remoteInterface,
                    dbManager: dbManager,
                    scanChangesOnly: true
                )

                if self.isInvalidated {
                    listener?.enumerationActionFailed(
                        actionId: actionId, error: NSFileProviderError(.cannotSynchronize)
                    )
                    observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize))
                    return
                }

                guard error == nil else {
                    // TODO: Refactor for conciseness
                    let fpError =
                        error?.fileProviderError ?? NSFileProviderError(.cannotSynchronize)
                    listener?.enumerationActionFailed(actionId: actionId, error: fpError)
                    observer.finishEnumeratingWithError(fpError)
                    return
                }

                Self.completeChangesObserver(
                    observer,
                    anchor: anchor,
                    account: account,
                    remoteInterface: remoteInterface,
                    dbManager: dbManager,
                    newMetadatas: newMetadatas,
                    updatedMetadatas: updatedMetadatas,
                    deletedMetadatas: deletedMetadatas
                )
                listener?.enumerationActionFinished(actionId: actionId)
            }
            return
        } else if enumeratedItemIdentifier == .trashContainer {
            Task {
                let (_, trashedItems, _, trashReadError) = await remoteInterface.trashedItems(
                    account: account,
                    options: .init(),
                    taskHandler: { task in
                        if let domain = self.domain {
                            NSFileProviderManager(for: domain)?.register(
                                task,
                                forItemWithIdentifier: self.enumeratedItemIdentifier,
                                completionHandler: { _ in }
                            )
                        }
                    }
                )

                guard trashReadError == .success else {
                    let error =
                        trashReadError.fileProviderError ?? NSFileProviderError(.cannotSynchronize)
                    listener?.enumerationActionFailed(actionId: actionId, error: error)
                    observer.finishEnumeratingWithError(error)
                    return
                }

                Self.completeChangesObserver(
                    observer,
                    anchor: anchor,
                    account: account,
                    remoteInterface: remoteInterface,
                    dbManager: dbManager,
                    trashItems: trashedItems
                )
                listener?.enumerationActionFinished(actionId: actionId)
            }
            return
        }

        // No matter what happens here we finish enumeration in some way, either from the error
        // handling below or from the completeChangesObserver
        // TODO: Move to the sync engine extension
        Task {
            let (
                _, newMetadatas, updatedMetadatas, deletedMetadatas, readError
            ) = await Self.readServerUrl(
                serverUrl,
                account: account,
                remoteInterface: remoteInterface,
                dbManager: dbManager,
                stopAtMatchingEtags: true
            )

            // If we get a 404 we might add more deleted metadatas
            var currentDeletedMetadatas: [SendableItemMetadata] = []
            if let notNilDeletedMetadatas = deletedMetadatas {
                currentDeletedMetadatas = notNilDeletedMetadatas
            }

            guard readError == nil else {
                let error = readError!.fileProviderError ?? NSFileProviderError(.cannotSynchronize)

                if readError!.isNotFoundError {
                    guard let itemMetadata = self.enumeratedItemMetadata else {
                        listener?.enumerationActionFailed(actionId: actionId, error: error)
                        observer.finishEnumeratingWithError(error)
                        return
                    }

                    if itemMetadata.directory {
                        if let deletedDirectoryMetadatas =
                            dbManager.deleteDirectoryAndSubdirectoriesMetadata(
                                ocId: itemMetadata.ocId)
                        {
                            currentDeletedMetadatas += deletedDirectoryMetadatas
                        } else {
                        }
                    } else {
                        dbManager.deleteItemMetadata(ocId: itemMetadata.ocId)
                    }

                    Self.completeChangesObserver(
                        observer,
                        anchor: anchor,
                        account: account,
                        remoteInterface: remoteInterface,
                        dbManager: dbManager,
                        newMetadatas: nil,
                        updatedMetadatas: nil,
                        deletedMetadatas: [itemMetadata]
                    )
                    listener?.enumerationActionFinished(actionId: actionId)
                    return
                } else if readError!.isNoChangesError {  // All is well, just no changed etags
                    listener?.enumerationActionFinished(actionId: actionId)
                    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                    return
                }

                listener?.enumerationActionFailed(actionId: actionId, error: error)
                observer.finishEnumeratingWithError(error)
                return
            }

            Self.completeChangesObserver(
                observer,
                anchor: anchor,
                account: account,
                remoteInterface: remoteInterface,
                dbManager: dbManager,
                newMetadatas: newMetadatas,
                updatedMetadatas: updatedMetadatas,
                deletedMetadatas: deletedMetadatas
            )
            listener?.enumerationActionFinished(actionId: actionId)
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchor)
    }

    // MARK: - Helper methods
    static func fileProviderPageforNumPage(_ numPage: Int) -> NSFileProviderPage? {
        return nil
        // TODO: Handle paging properly
        // NSFileProviderPage("\(numPage)".data(using: .utf8)!)
    }

    private static func completeEnumerationObserver(
        _ observer: NSFileProviderEnumerationObserver,
        account: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        numPage: Int,
        itemMetadatas: [SendableItemMetadata]
    ) {
        Task {
            let items = await itemMetadatas.toFileProviderItems(
                account: account, remoteInterface: remoteInterface, dbManager: dbManager
            )

            Task { @MainActor in
                observer.didEnumerate(items)

                // TODO: Handle paging properly
                /*
                 if items.count == maxItemsPerFileProviderPage {
                 let nextPage = numPage + 1
                 let providerPage = NSFileProviderPage("\(nextPage)".data(using: .utf8)!)
                 observer.finishEnumerating(upTo: providerPage)
                 } else {
                 observer.finishEnumerating(upTo: nil)
                 }
                 */
                observer.finishEnumerating(upTo: fileProviderPageforNumPage(numPage))
            }
        }
    }

    private static func completeChangesObserver(
        _ observer: NSFileProviderChangeObserver,
        anchor: NSFileProviderSyncAnchor,
        account: Account,
        remoteInterface: RemoteInterface,
        dbManager: FilesDatabaseManager,
        newMetadatas: [SendableItemMetadata]?,
        updatedMetadatas: [SendableItemMetadata]?,
        deletedMetadatas: [SendableItemMetadata]?
    ) {
        guard newMetadatas != nil || updatedMetadatas != nil || deletedMetadatas != nil else {
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }

        // Observer does not care about new vs updated, so join
        var allUpdatedMetadatas: [SendableItemMetadata] = []
        var allDeletedMetadatas: [SendableItemMetadata] = []

        if let newMetadatas {
            allUpdatedMetadatas += newMetadatas
        }

        if let updatedMetadatas {
            allUpdatedMetadatas += updatedMetadatas
        }

        if let deletedMetadatas {
            allDeletedMetadatas = deletedMetadatas
        }

        let allFpItemDeletionsIdentifiers = Array(
            allDeletedMetadatas.map { NSFileProviderItemIdentifier($0.ocId) })
        if !allFpItemDeletionsIdentifiers.isEmpty {
            observer.didDeleteItems(withIdentifiers: allFpItemDeletionsIdentifiers)
        }

        Task { [allUpdatedMetadatas, allDeletedMetadatas] in
            let updatedItems = await allUpdatedMetadatas.toFileProviderItems(
                account: account, remoteInterface: remoteInterface, dbManager: dbManager
            )

            Task { @MainActor in
                if !updatedItems.isEmpty {
                    observer.didUpdate(updatedItems)
                }

                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            }
        }
    }
}
