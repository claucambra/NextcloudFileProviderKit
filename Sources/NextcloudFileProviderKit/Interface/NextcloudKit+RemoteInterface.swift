//
//  NextcloudKit+RemoteInterface.swift
//  
//
//  Created by Claudio Cambra on 16/4/24.
//

import Alamofire
import FileProvider
import Foundation
import NextcloudKit

extension NextcloudKit: RemoteInterface {

    public func setDelegate(_ delegate: any NextcloudKitDelegate) {
        setup(delegate: delegate)
    }

    public func createFolder(
        remotePath: String,
        account: Account,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (URLSessionTask) -> Void = { _ in }
    ) async -> (account: String, ocId: String?, date: NSDate?, error: NKError) {
        return await withCheckedContinuation { continuation in
            createFolder(
                serverUrlFileName: remotePath,
                account: account.ncKitAccount,
                options: options,
                taskHandler: taskHandler
            ) { account, ocId, date, _, error in
                continuation.resume(returning: (account, ocId, date as NSDate?, error))
            }
        }
    }

    public func upload(
        remotePath: String,
        localPath: String, 
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        account: Account,
        options: NKRequestOptions = .init(),
        requestHandler: @escaping (UploadRequest) -> Void = { _ in },
        taskHandler: @escaping (URLSessionTask) -> Void = { _ in },
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async -> (
        account: String,
        ocId: String?,
        etag: String?,
        date: NSDate?,
        size: Int64,
        response: HTTPURLResponse?,
        afError: AFError?,
        remoteError: NKError
    ) {
        return await withCheckedContinuation { continuation in
            upload(
                serverUrlFileName: remotePath,
                fileNameLocalPath: localPath,
                dateCreationFile: creationDate,
                dateModificationFile: modificationDate,
                account: account.ncKitAccount,
                options: options,
                requestHandler: requestHandler,
                taskHandler: taskHandler,
                progressHandler: progressHandler
            ) { account, ocId, etag, date, size, response, afError, nkError in
                continuation.resume(returning: (
                    account,
                    ocId,
                    etag,
                    date as NSDate?,
                    size,
                    response?.response,
                    afError,
                    nkError
                ))
            }
        }
    }

    public func move(
        remotePathSource: String,
        remotePathDestination: String,
        overwrite: Bool,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (URLSessionTask) -> Void
    ) async -> (account: String, data: Data?, error: NKError) {
        return await withCheckedContinuation { continuation in
            moveFileOrFolder(
                serverUrlFileNameSource: remotePathSource,
                serverUrlFileNameDestination: remotePathDestination,
                overwrite: overwrite,
                account: account.ncKitAccount,
                options: options,
                taskHandler: taskHandler
            ) { account, data, error in
                continuation.resume(returning: (account, data?.data, error))
            }
        }
    }

    public func download(
        remotePath: String,
        localPath: String,
        account: Account,
        options: NKRequestOptions = .init(),
        requestHandler: @escaping (DownloadRequest) -> Void = { _ in },
        taskHandler: @escaping (URLSessionTask) -> Void = { _ in },
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async -> (
        account: String,
        etag: String?,
        date: NSDate?,
        length: Int64,
        response: HTTPURLResponse?,
        afError: AFError?,
        remoteError: NKError
    ) {
        return await withCheckedContinuation { continuation in
            download(
                serverUrlFileName: remotePath,
                fileNameLocalPath: localPath,
                account: account.ncKitAccount,
                options: options,
                requestHandler: requestHandler,
                taskHandler: taskHandler,
                progressHandler: progressHandler
            ) { account, etag, date, length, data, afError, remoteError in
                continuation.resume(returning: (
                    account, 
                    etag,
                    date as NSDate?,
                    length,
                    data?.response,
                    afError,
                    remoteError
                ))
            }
        }
    }

    public func enumerate(
        remotePath: String,
        depth: EnumerateDepth,
        showHiddenFiles: Bool = false,
        includeHiddenFiles: [String] = [],
        requestBody: Data? = nil,
        account: Account,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (URLSessionTask) -> Void = { _ in }
    ) async -> (
        account: String, files: [NKFile], data: Data?, error: NKError
    ) {
        return await withCheckedContinuation { continuation in
            readFileOrFolder(
                serverUrlFileName: remotePath,
                depth: depth.rawValue,
                showHiddenFiles: showHiddenFiles,
                includeHiddenFiles: includeHiddenFiles,
                requestBody: requestBody,
                account: account.ncKitAccount,
                options: options,
                taskHandler: taskHandler
            ) { account, files, data, error in
                continuation.resume(returning: (account, files ?? [], data?.data, error))
            }
        }
    }

    public func delete(
        remotePath: String,
        account: Account,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (URLSessionTask) -> Void = { _ in }
    ) async -> (account: String, response: HTTPURLResponse?, error: NKError) {
        return await withCheckedContinuation { continuation in
            deleteFileOrFolder(
                serverUrlFileName: remotePath, account: account.ncKitAccount
            ) { account, response, error in
                continuation.resume(returning: (account, response?.response, error))
            }
        }
    }

    public func trashedItems(
        account: Account,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (URLSessionTask) -> Void
    ) async -> (account: String, trashedItems: [NKTrash], data: Data?, error: NKError) {
        return await withCheckedContinuation { continuation in
            listingTrash(
                showHiddenFiles: true, account: account.ncKitAccount
            ) { account, items, data, error in
                continuation.resume(returning: (account, items ?? [], data?.data, error))
            }
        }
    }

    public func restoreFromTrash(
        filename: String,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, data: Data?, error: NKError) {
        let trashFileUrl = account.trashUrl + "/" + filename
        let recoverFileUrl = account.trashRestoreUrl + "/" + filename

        return await move(
            remotePathSource: trashFileUrl,
            remotePathDestination: recoverFileUrl,
            overwrite: false,
            account: account,
            options: options,
            taskHandler: taskHandler
        )
    }

    public func downloadThumbnail(
        url: URL,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (URLSessionTask) -> Void
    ) async -> (account: String, data: Data?, error: NKError) {
        await withCheckedContinuation { continuation in
            downloadPreview(
                url: url, account: account.ncKitAccount, options: options, taskHandler: taskHandler
            ) { account, data, error in
                continuation.resume(returning: (account, data?.data, error))
            }
        }
    }

    public func fetchCapabilities(
        account: Account,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (_ task: URLSessionTask) -> Void = { _ in }
    ) async -> (account: String, data: Data?, error: NKError) {
        return await withCheckedContinuation { continuation in
            getCapabilities(account: account.ncKitAccount, options: options, taskHandler: taskHandler) { account, data, error in
                continuation.resume(returning: (account, data?.data, error))
            }
        }
    }

    public func fetchUserProfile(
        account: Account,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (_ task: URLSessionTask) -> Void = { _ in }
    ) async -> (account: String, userProfile: NKUserProfile?, data: Data?, error: NKError) {
        return await withCheckedContinuation { continuation in
            getUserProfile(
                account: account.ncKitAccount, options: options, taskHandler: taskHandler
            ) { account, userProfile, data, error in
                continuation.resume(returning: (account, userProfile, data?.data, error))
            }
        }
    }

    public func tryAuthenticationAttempt(
        account: Account,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (_ task: URLSessionTask) -> Void = { _ in }
    ) async -> AuthenticationAttemptResultState {
        // Test by trying to fetch user profile
        let (_, _, _, error) =
            await enumerate(remotePath: account.davFilesUrl + "/", depth: .target, account: account)

        if error == .success {
            return .success
        } else if error.isCouldntConnectError {
            return .connectionError
        } else {
            return .authenticationError
        }
    }
}
