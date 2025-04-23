//
//  NextcloudKit+RemoteInterface.swift
//  
//
//  Created by Claudio Cambra on 16/4/24.
//

import Alamofire
import FileProvider
import NextcloudCapabilitiesKit
import NextcloudKit

public class NextcloudRemoteInterface: NextcloudKit, RemoteInterface {

    public var delegate: NextcloudKitDelegate? {
        get { nkCommonInstance.delegate }
        set { setup(delegate: newValue) }
    }

    public var capabilities: Capabilities?

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

    public func chunkedUpload(
        localPath: String,
        remotePath: String,
        remoteChunkStoreFolderName: String = UUID().uuidString,
        chunkSize: Int,
        remainingChunks: [RemoteFileChunk],
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        account: Account,
        options: NKRequestOptions = .init(),
        currentNumChunksUpdateHandler: @escaping (_ num: Int) -> Void = { _ in },
        chunkCounter: @escaping (_ counter: Int) -> Void = { _ in },
        chunkUploadStartHandler: @escaping (_ filesChunk: [RemoteFileChunk]) -> Void = { _ in },
        requestHandler: @escaping (_ request: UploadRequest) -> Void = { _ in },
        taskHandler: @escaping (_ task: URLSessionTask) -> Void = { _ in },
        progressHandler: @escaping (Progress) -> Void = { _ in },
        chunkUploadCompleteHandler: @escaping (_ fileChunk: RemoteFileChunk) -> Void = { _ in }
    ) async -> (
        account: String,
        fileChunks: [RemoteFileChunk]?,
        file: NKFile?,
        afError: AFError?,
        remoteError: NKError
    ) {
        guard let remoteUrl = URL(string: remotePath) else {
            uploadLogger.error("NCKit ext: Could not get url from \(remotePath, privacy: .public)")
            return ("", nil, nil, nil, .urlError)
        }
        let localUrl = URL(fileURLWithPath: localPath)

        let fm = FileManager.default
        let chunksOutputDirectoryUrl =
            fm.temporaryDirectory.appendingPathComponent(remoteChunkStoreFolderName)
        do {
            try fm.createDirectory(at: chunksOutputDirectoryUrl, withIntermediateDirectories: true)
        } catch let error {
            uploadLogger.error(
                """
                Could not create temporary directory for chunked files: \(error, privacy: .public)
                """
            )
            return ("", nil, nil, nil, .urlError)
        }

        var directory = localUrl.deletingLastPathComponent().path
        if directory.last == "/" {
            directory.removeLast()
        }
        let fileChunksOutputDirectory = chunksOutputDirectoryUrl.path
        let fileName = localUrl.lastPathComponent
        let destinationFileName = remoteUrl.lastPathComponent
        guard let serverUrl = remoteUrl
            .deletingLastPathComponent()
            .absoluteString
            .removingPercentEncoding
        else {
            uploadLogger.error(
                "NCKit ext: Could not get server url from \(remotePath, privacy: .public)"
            )
            return ("", nil, nil, nil, .urlError)
        }
        let fileChunks = remainingChunks.toNcKitChunks()

        uploadLogger.info(
            """
            Beginning chunked upload of: \(localPath, privacy: .public)
                directory: \(directory, privacy: .public)
                fileChunksOutputDirectory: \(fileChunksOutputDirectory, privacy: .public)
                fileName: \(fileName, privacy: .public)
                destinationFileName: \(destinationFileName, privacy: .public)
                date: \(modificationDate?.debugDescription ?? "", privacy: .public)
                creationDate: \(creationDate?.debugDescription ?? "", privacy: .public)
                serverUrl: \(serverUrl, privacy: .public)
                chunkFolder: \(remoteChunkStoreFolderName, privacy: .public)
                filesChunk: \(fileChunks, privacy: .public)
                chunkSize: \(chunkSize, privacy: .public)
            """
        )

        return await withCheckedContinuation { continuation in
            uploadChunk(
                directory: directory,
                fileChunksOutputDirectory: fileChunksOutputDirectory,
                fileName: fileName,
                destinationFileName: destinationFileName,
                date: modificationDate,
                creationDate: creationDate,
                serverUrl: serverUrl,
                chunkFolder: remoteChunkStoreFolderName,
                filesChunk: fileChunks,
                chunkSize: chunkSize,
                account: account.ncKitAccount,
                options: options,
                numChunks: currentNumChunksUpdateHandler,
                counterChunk: chunkCounter,
                start: { processedChunks in
                    let chunks = RemoteFileChunk.fromNcKitChunks(
                        processedChunks, remoteChunkStoreFolderName: remoteChunkStoreFolderName
                    )
                    chunkUploadStartHandler(chunks)
                },
                requestHandler: requestHandler,
                taskHandler: taskHandler,
                progressHandler: { totalBytesExpected, totalBytes, fractionCompleted in
                    let currentProgress = Progress(totalUnitCount: totalBytesExpected)
                    currentProgress.completedUnitCount = totalBytes
                    progressHandler(currentProgress)
                },
                uploaded: { uploadedChunk in
                    let chunk = RemoteFileChunk(
                        ncKitChunk: uploadedChunk,
                        remoteChunkStoreFolderName: remoteChunkStoreFolderName
                    )
                    chunkUploadCompleteHandler(chunk)
                }
            ) { account, receivedChunks, file, afError, error in
                let chunks = RemoteFileChunk.fromNcKitChunks(
                    receivedChunks ?? [], remoteChunkStoreFolderName: remoteChunkStoreFolderName
                )
                continuation.resume(returning: (account, chunks, file, afError, error))
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

    public func setLockStateForFile(
        remotePath: String,
        lock: Bool,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, response: HTTPURLResponse?, error: NKError) {
        return await withCheckedContinuation { continuation in
            lockUnlockFile(
                serverUrlFileName: remotePath, shouldLock: lock, account: account.ncKitAccount
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
            overwrite: true,
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
    ) async -> (account: String, capabilities: Capabilities?, data: Data?, error: NKError) {
        return await withCheckedContinuation { continuation in
            getCapabilities(account: account.ncKitAccount, options: options, taskHandler: taskHandler) { account, data, error in
                let capabilities: Capabilities? = {
                    guard let realData = data?.data else { return nil }
                    return Capabilities(data: realData)
                }()
                self.capabilities = capabilities
                continuation.resume(returning: (account, capabilities, data?.data, error))
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
