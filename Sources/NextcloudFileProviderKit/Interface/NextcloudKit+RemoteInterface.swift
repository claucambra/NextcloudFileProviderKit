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

    public var account: Account {
        Account(
            user: nkCommonInstance.user,
            serverUrl: nkCommonInstance.urlBase,
            password: nkCommonInstance.password
        )
    }

    public func createFolder(
        remotePath: String,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (URLSessionTask) -> Void = { _ in }
    ) async -> (account: String, ocId: String?, date: NSDate?, error: NKError) {
        return await withCheckedContinuation { continuation in
            createFolder(
                serverUrlFileName: remotePath,
                options: options,
                taskHandler: taskHandler
            ) { account, ocId, date, error in
                continuation.resume(returning: (account, ocId, date, error))
            }
        }
    }

    public func upload(
        remotePath: String,
        localPath: String, 
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
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
        allHeaderFields: [AnyHashable : Any]?,
        afError: AFError?,
        remoteError: NKError
    ) {
        return await withCheckedContinuation { continuation in
            upload(
                serverUrlFileName: remotePath,
                fileNameLocalPath: localPath,
                dateCreationFile: creationDate,
                dateModificationFile: modificationDate,
                options: options,
                requestHandler: requestHandler,
                taskHandler: taskHandler,
                progressHandler: progressHandler
            ) { account, ocId, etag, date, size, allHeaderFields, afError, nkError in
                continuation.resume(returning: (
                    account,
                    ocId,
                    etag,
                    date,
                    size,
                    allHeaderFields,
                    afError,
                    nkError
                ))
            }
        }
    }

    public func download(
        remotePath: String,
        localPath: String,
        options: NKRequestOptions = .init(),
        requestHandler: @escaping (DownloadRequest) -> Void = { _ in },
        taskHandler: @escaping (URLSessionTask) -> Void = { _ in },
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async -> (
        account: String,
        etag: String?,
        date: NSDate?,
        length: Int64,
        allHeaderFields: [AnyHashable : Any]?,
        afError: AFError?,
        remoteError: NKError
    ) {
        return await withCheckedContinuation { continuation in
            download(
                serverUrlFileName: remotePath,
                fileNameLocalPath: localPath,
                options: options,
                requestHandler: requestHandler,
                taskHandler: taskHandler,
                progressHandler: progressHandler
            ) { account, etag, date, length, allHeaderFields, afError, remoteError in
                continuation.resume(returning: (
                    account, 
                    etag,
                    date,
                    length,
                    allHeaderFields,
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
                options: options,
                taskHandler: taskHandler
            ) { account, files, data, error in
                continuation.resume(returning: (account, files, data, error))
            }
        }
    }

    public func delete(
        remotePath: String,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (URLSessionTask) -> Void = { _ in }
    ) async -> (account: String, error: NKError) {
        return await withCheckedContinuation { continuation in
            deleteFileOrFolder(serverUrlFileName: remotePath) { account, error in
                continuation.resume(returning: (account, error))
            }
        }
    }

    public func downloadThumbnail(
        url: URL, options: NKRequestOptions, taskHandler: @escaping (URLSessionTask) -> Void
    ) async -> (account: String, data: Data?, error: NKError) {
        await withCheckedContinuation { continuation in
            getPreview(
                url: url, options: options, taskHandler: taskHandler
            ) { account, data, error in
                continuation.resume(returning: (account, data, error))
            }
        }
    }

    public func getInternalType(
        fileName: String, mimeType: String, directory: Bool
    ) -> (
        mimeType: String,
        classFile: String,
        iconName: String,
        typeIdentifier: String,
        fileNameWithoutExt: String,
        ext: String
    ) {
        return nkCommonInstance.getInternalType(
            fileName: fileName, mimeType: mimeType, directory: directory
        )
    }
}
