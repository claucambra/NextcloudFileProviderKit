//
//  ThumbnailFetcher.swift
//
//
//  Created by Claudio Cambra on 15/4/24.
//

import FileProvider
import Foundation
import NextcloudKit
import OSLog

fileprivate let logger = Logger(subsystem: Logger.subsystem, category: "thumbnails")

public func fetchThumbnails(
    for itemIdentifiers: [NSFileProviderItemIdentifier],
    requestedSize size: CGSize,
    account: Account,
    usingRemoteInterface remoteInterface: RemoteInterface,
    perThumbnailCompletionHandler: @escaping (
        NSFileProviderItemIdentifier,
        Data?,
        Error?
    ) -> Void,
    completionHandler: @escaping (Error?) -> Void
) -> Progress {
    let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))

    @Sendable func finishCurrent() {
        progress.completedUnitCount += 1

        if progress.completedUnitCount == progress.totalUnitCount {
            completionHandler(nil)
        }
    }

    for itemIdentifier in itemIdentifiers {
        guard let item = Item.storedItem(
            identifier: itemIdentifier,
            account: account,
            remoteInterface: remoteInterface
        ) else {
            logger.error(
                """
                Could not find item with identifier: \(itemIdentifier.rawValue, privacy: .public),
                unable to download thumbnail!
                """
            )
            perThumbnailCompletionHandler(itemIdentifier, nil, NSFileProviderError(.noSuchItem))
            finishCurrent()
            continue
        }

        Task {
            let (data, error) = await item.fetchThumbnail(size: size)
            perThumbnailCompletionHandler(itemIdentifier, data, error)
            finishCurrent()
        }
    }

    return progress
}
