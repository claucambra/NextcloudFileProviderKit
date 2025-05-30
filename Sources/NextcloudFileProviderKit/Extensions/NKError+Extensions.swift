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
import Foundation
import NextcloudKit

extension NKError {
    static var noChangesErrorCode: Int {
        -200
    }

    var isCouldntConnectError: Bool {
        errorCode == -9999 || errorCode == -1001 || errorCode == -1004 || errorCode == -1005
            || errorCode == -1009 || errorCode == -1012 || errorCode == -1200 || errorCode == -1202
            || errorCode == 500 || errorCode == 503 || errorCode == 200
    }

    var isUnauthenticatedError: Bool {
        errorCode == -1013
    }

    var isGoingOverQuotaError: Bool {
        errorCode == 507
    }

    var isNotFoundError: Bool {
        errorCode == 404
    }

    var isNoChangesError: Bool {
        errorCode == NKError.noChangesErrorCode
    }

    var isUnauthorizedError: Bool {
        errorCode == 401
    }

    var matchesCollisionError: Bool {
        errorCode == 405
    }

    var fileProviderError: NSFileProviderError? {
        if self == .success {
            nil
        } else if isNotFoundError {
            NSFileProviderError(.noSuchItem)
        } else if isCouldntConnectError {
            // Provide something the file provider can do something with
            NSFileProviderError(.serverUnreachable)
        } else if isUnauthenticatedError || isUnauthorizedError {
            NSFileProviderError(.notAuthenticated)
        } else if isGoingOverQuotaError {
            NSFileProviderError(.insufficientQuota)
        } else if matchesCollisionError {
            NSFileProviderError(.filenameCollision)
        } else {
            NSFileProviderError(.cannotSynchronize)
        }
    }

    func fileProviderError(
        handlingNoSuchItemErrorUsingItemIdentifier identifier: NSFileProviderItemIdentifier
    ) -> Error? {
        guard fileProviderError?.code == .noSuchItem else {
            return fileProviderError as Error?
        }
        return NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)
    }

    func fileProviderError(
        handlingCollisionAgainstItemInRemotePath problemRemotePath: String,
        dbManager: FilesDatabaseManager,
        remoteInterface: RemoteInterface
    ) async -> Error? {
        guard fileProviderError?.code == .filenameCollision else {
            return fileProviderError as Error?
        }
        guard let collidingItemMetadata = dbManager.itemMetadata(
            account: dbManager.account.ncKitAccount, locatedAtRemoteUrl: problemRemotePath
        ), let collidingItem = await Item.storedItem(
            identifier: .init(collidingItemMetadata.ocId),
            account: dbManager.account,
            remoteInterface: remoteInterface,
            dbManager: dbManager
        ) else {
            return NSFileProviderError(.filenameCollision)
        }
        return NSError.fileProviderErrorForCollision(with: collidingItem)
    }
}
