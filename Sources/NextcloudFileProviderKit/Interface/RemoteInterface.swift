//
//  RemoteInterface.swift
//
//
//  Created by Claudio Cambra on 16/4/24.
//

import Alamofire
import FileProvider
import Foundation
import NextcloudCapabilitiesKit
import NextcloudKit
import OSLog

fileprivate let CapabilitiesFetchInterval: TimeInterval = 30 * 60 // 30mins

public enum EnumerateDepth: String {
    case target = "0"
    case targetAndDirectChildren = "1"
    case targetAndAllChildren = "infinity"
}

public enum AuthenticationAttemptResultState: Int {
    case authenticationError, connectionError, success
}

actor RetrievedCapabilitiesActor {
    static let shared: RetrievedCapabilitiesActor = {
        let instance = RetrievedCapabilitiesActor()
        return instance
    }()
    var ongoingFetches: Set<String> = []
    var data: [String: (capabilities: Capabilities, retrievedAt: Date)] = [:]

    private var ongoingFetchContinuations: [String: [CheckedContinuation<Void, Never>]] = [:]

    func setCapabilities(
        forAccount account: String,
        capabilities: Capabilities,
        retrievedAt: Date = Date()
    ) {
        self.data[account] = (capabilities: capabilities, retrievedAt: retrievedAt)
    }

    func setOngoingFetch(forAccount account: String, ongoing: Bool) {
        if ongoing {
            ongoingFetches.insert(account)
        } else {
            ongoingFetches.remove(account)
            // If there are any continuations waiting for this account, resume them.
            if let continuations = ongoingFetchContinuations.removeValue(forKey: account) {
                continuations.forEach { $0.resume() }
            }
        }
    }

    func awaitFetchCompletion(forAccount account: String) async {
        guard ongoingFetches.contains(account) else { return }

        // If a fetch is ongoing, create a continuation and store it.
        await withCheckedContinuation { continuation in
            var existingContinuations = ongoingFetchContinuations[account, default: []]
            existingContinuations.append(continuation)
            ongoingFetchContinuations[account] = existingContinuations
        }
    }
}

public protocol RemoteInterface {

    func setDelegate(_ delegate: NextcloudKitDelegate)

    func createFolder(
        remotePath: String,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, ocId: String?, date: NSDate?, error: NKError)

    func upload(
        remotePath: String,
        localPath: String,
        creationDate: Date?,
        modificationDate: Date?,
        account: Account,
        options: NKRequestOptions,
        requestHandler: @escaping (_ request: UploadRequest) -> Void,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void,
        progressHandler: @escaping (_ progress: Progress) -> Void
    ) async -> (
        account: String,
        ocId: String?,
        etag: String?,
        date: NSDate?,
        size: Int64,
        response: HTTPURLResponse?,
        afError: AFError?,
        remoteError: NKError
    )

    func chunkedUpload(
        localPath: String,
        remotePath: String,
        remoteChunkStoreFolderName: String,
        chunkSize: Int,
        remainingChunks: [RemoteFileChunk],
        creationDate: Date?,
        modificationDate: Date?,
        account: Account,
        options: NKRequestOptions,
        currentNumChunksUpdateHandler: @escaping (_ num: Int) -> Void,
        chunkCounter: @escaping (_ counter: Int) -> Void,
        chunkUploadStartHandler: @escaping (_ filesChunk: [RemoteFileChunk]) -> Void,
        requestHandler: @escaping (_ request: UploadRequest) -> Void,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void,
        progressHandler: @escaping (Progress) -> Void,
        chunkUploadCompleteHandler: @escaping (_ fileChunk: RemoteFileChunk) -> Void
    ) async -> (
        account: String,
        fileChunks: [RemoteFileChunk]?,
        file: NKFile?,
        afError: AFError?,
        remoteError: NKError
    )

    func move(
        remotePathSource: String,
        remotePathDestination: String,
        overwrite: Bool,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, data: Data?, error: NKError)

    func download(
        remotePath: String,
        localPath: String,
        account: Account,
        options: NKRequestOptions,
        requestHandler: @escaping (_ request: DownloadRequest) -> Void,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void,
        progressHandler: @escaping (_ progress: Progress) -> Void
    ) async -> (
        account: String,
        etag: String?,
        date: NSDate?,
        length: Int64,
        response: HTTPURLResponse?,
        afError: AFError?,
        remoteError: NKError
    )

    func enumerate(
        remotePath: String,
        depth: EnumerateDepth,
        showHiddenFiles: Bool,
        includeHiddenFiles: [String],
        requestBody: Data?,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, files: [NKFile], data: Data?, error: NKError)

    func delete(
        remotePath: String,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, response: HTTPURLResponse?, error: NKError)

    func setLockStateForFile(
        remotePath: String,
        lock: Bool,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, response: HTTPURLResponse?, error: NKError)

    func trashedItems(
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, trashedItems: [NKTrash], data: Data?, error: NKError)

    func restoreFromTrash(
        filename: String,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, data: Data?, error: NKError)

    func downloadThumbnail(
        url: URL,
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, data: Data?, error: NKError)

    func fetchCapabilities(
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, capabilities: Capabilities?, data: Data?, error: NKError)

    func fetchUserProfile(
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> (account: String, userProfile: NKUserProfile?, data: Data?, error: NKError)

    func tryAuthenticationAttempt(
        account: Account,
        options: NKRequestOptions,
        taskHandler: @escaping (_ task: URLSessionTask) -> Void
    ) async -> AuthenticationAttemptResultState
}

public extension RemoteInterface {

    private var logger: Logger {
        Logger(subsystem: Logger.subsystem, category: "RemoteInterface")
    }

    func currentCapabilities(
        account: Account,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (_ task: URLSessionTask) -> Void = { _ in }
    ) async -> (account: String, capabilities: Capabilities?, data: Data?, error: NKError) {
        let ncKitAccount = account.ncKitAccount
        await RetrievedCapabilitiesActor.shared.awaitFetchCompletion(forAccount: ncKitAccount)
        guard let lastRetrieval = await RetrievedCapabilitiesActor.shared.data[ncKitAccount],
              lastRetrieval.retrievedAt.timeIntervalSince(Date()) > -CapabilitiesFetchInterval
        else {
            return await fetchCapabilities(
                account: account, options: options, taskHandler: taskHandler
            )
        }
        return (account.ncKitAccount, lastRetrieval.capabilities, nil, .success)
    }

    func supportsTrash(
        account: Account,
        options: NKRequestOptions = .init(),
        taskHandler: @escaping (_ task: URLSessionTask) -> Void = { _ in }
    ) async -> Bool {
        var remoteSupportsTrash = false
        let (_, capabilities, _, _) = await currentCapabilities(
            account: account, options: .init(), taskHandler: { _ in }
        )
        if let filesCapabilities = capabilities?.files {
            remoteSupportsTrash = filesCapabilities.undelete
        } else {
            logger.warning("Could not get capabilities, will assume trash is unavailable.")
        }
        return remoteSupportsTrash
    }
}
