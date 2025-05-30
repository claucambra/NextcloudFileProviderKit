//
//  RemoteChangeObserver.swift
//
//
//  Created by Claudio Cambra on 17/4/24.
//

import Alamofire
import FileProvider
import Foundation
import NextcloudCapabilitiesKit
import NextcloudKit

public let NotifyPushAuthenticatedNotificationName = Notification.Name("NotifyPushAuthenticated")

public class RemoteChangeObserver: NSObject, NextcloudKitDelegate, URLSessionWebSocketDelegate {
    public let remoteInterface: RemoteInterface
    public let changeNotificationInterface: ChangeNotificationInterface
    public let domain: NSFileProviderDomain?
    public var account: Account
    public var accountId: String { account.ncKitAccount }

    public var webSocketPingIntervalNanoseconds: UInt64 = 3 * 1_000_000_000
    public var webSocketReconfigureIntervalNanoseconds: UInt64 = 1 * 1_000_000_000
    public var webSocketPingFailLimit = 8
    public var webSocketAuthenticationFailLimit = 3
    public var webSocketTaskActive: Bool { webSocketTask != nil }

    private var webSocketUrlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketOperationQueue = OperationQueue()
    private var webSocketPingTask: Task<(), Never>?
    private(set) var webSocketPingFailCount = 0
    private(set) var webSocketAuthenticationFailCount = 0

    private(set) var pollingTimer: Timer?
    public var pollInterval: TimeInterval = 60 {
        didSet {
            if pollingActive {
                stopPollingTimer()
                startPollingTimer()
            }
        }
    }
    public var pollingActive: Bool { pollingTimer != nil }

    private(set) var networkReachability: NKCommon.TypeReachability = .unknown {
        didSet {
            if networkReachability == .notReachable {
                stopPollingTimer()
                resetWebSocket()
            } else if oldValue == .notReachable {
                reconnectWebSocket()
                changeNotificationInterface.notifyChange()
            }
        }
    }

    public init(
        account: Account,
        remoteInterface: RemoteInterface,
        changeNotificationInterface: ChangeNotificationInterface,
        domain: NSFileProviderDomain?
    ) {
        self.account = account
        self.remoteInterface = remoteInterface
        self.changeNotificationInterface = changeNotificationInterface
        self.domain = domain
        super.init()
        connect()
    }

    private func startPollingTimer() {
        Task { @MainActor in
            pollingTimer = Timer.scheduledTimer(
                withTimeInterval: pollInterval, repeats: true
            ) { [weak self] timer in
                self?.changeNotificationInterface.notifyChange()
            }
        }
    }

    private func stopPollingTimer() {
        Task { @MainActor in
            pollingTimer?.invalidate()
            pollingTimer = nil
        }
    }

    public func connect() {
        // Authentication fixes require some type of user or external change.
        // We don't want to reset the auth tries within reconnect web socket as this is called
        // internally
        webSocketAuthenticationFailCount = 0
        reconnectWebSocket()
    }

    private func reconnectWebSocket() {
        stopPollingTimer()
        resetWebSocket()
        guard networkReachability != .notReachable else {
            return
        }
        guard webSocketAuthenticationFailCount < webSocketAuthenticationFailLimit else {
            startPollingTimer()
            return
        }
        Task {
            try await Task.sleep(nanoseconds: webSocketReconfigureIntervalNanoseconds)
            await self.configureNotifyPush()
        }
    }

    public func resetWebSocket() {
        webSocketTask?.cancel()
        webSocketUrlSession = nil
        webSocketTask = nil
        webSocketOperationQueue.cancelAllOperations()
        webSocketOperationQueue.isSuspended = true
        webSocketPingTask?.cancel()
        webSocketPingTask = nil
        webSocketPingFailCount = 0
    }

    private func configureNotifyPush() async {
        let (_, capabilitiesData, error) = await remoteInterface.fetchCapabilities(
            account: account,
            options: .init(),
            taskHandler: { task in
                if let domain = self.domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: .rootContainer,
                        completionHandler: { _ in }
                    )
                }
            }
        )

        guard error == .success else {
            reconnectWebSocket()
            return
        }

        guard let capabilitiesData = capabilitiesData,
              let capabilities = Capabilities(data: capabilitiesData),
              let websocketEndpoint = capabilities.notifyPush?.endpoints?.websocket
        else {
            startPollingTimer()
            return
        }

        guard let websocketEndpointUrl = URL(string: websocketEndpoint) else {
            return
        }
        webSocketOperationQueue.isSuspended = false
        webSocketUrlSession = URLSession(
            configuration: URLSessionConfiguration.default,
            delegate: self,
            delegateQueue: webSocketOperationQueue
        )
        webSocketTask = webSocketUrlSession?.webSocketTask(with: websocketEndpointUrl)
        webSocketTask?.resume()
    }

    public func authenticationChallenge(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let authMethod = challenge.protectionSpace.authenticationMethod
        if authMethod == NSURLAuthenticationMethodHTTPBasic {
            let credential = URLCredential(
                user: account.username,
                password: account.password,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        } else if authMethod == NSURLAuthenticationMethodServerTrust {
            // TODO: Validate the server trust
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            // Handle other authentication methods or cancel the challenge
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { await authenticateWebSocket() }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        reconnectWebSocket()
    }

    private func authenticateWebSocket() async {
        do {
            try await webSocketTask?.send(.string(account.username))
            try await webSocketTask?.send(.string(account.password))
        } catch {
        }
        readWebSocket()
    }

    private func startNewWebSocketPingTask() {
        guard !Task.isCancelled else { return }

        if let webSocketPingTask, !webSocketPingTask.isCancelled {
            webSocketPingTask.cancel()
        }

        webSocketPingTask = Task.detached(priority: .background) {
            do {
                try await Task.sleep(nanoseconds: self.webSocketPingIntervalNanoseconds)
            } catch {
            }
            guard !Task.isCancelled else { return }
            self.pingWebSocket()
        }
    }

    private func pingWebSocket() {  // Keep the socket connection alive
        guard networkReachability != .notReachable else {
            return
        }

        webSocketTask?.sendPing { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                self.webSocketPingFailCount += 1
                if self.webSocketPingFailCount > self.webSocketPingFailLimit {
                    Task.detached(priority: .medium) { self.reconnectWebSocket() }
                } else {
                    self.startNewWebSocketPingTask()
                }
                return
            }

            self.startNewWebSocketPingTask()
        }
    }

    private func readWebSocket() {
        webSocketTask?.receive { result in
            switch result {
            case .failure:
                // Do not reconnect here, delegate methods will handle reconnecting
                break
            case .success(let message):
                switch message {
                case .data(let data):
                    self.processWebsocket(data: data)
                case .string(let string):
                    self.processWebsocket(string: string)
                @unknown default:
                    break
                }
                self.readWebSocket()
            }
        }
    }

    private func processWebsocket(data: Data) {
        guard let string = String(data: data, encoding: .utf8) else {
            return
        }
        processWebsocket(string: string)
    }

    private func processWebsocket(string: String) {
        if string == "notify_file" {
            changeNotificationInterface.notifyChange()
        } else if string == "notify_activity" {
        } else if string == "notify_notification" {
        } else if string == "authenticated" {
            NotificationCenter.default.post(
                name: NotifyPushAuthenticatedNotificationName, object: self
            )
            startNewWebSocketPingTask()
        } else if string == "err: Invalid credentials" {
            webSocketAuthenticationFailCount += 1
            reconnectWebSocket()
        } else {
        }
    }

    // MARK: - NextcloudKitDelegate methods

    public func networkReachabilityObserver(_ typeReachability: NKCommon.TypeReachability) {
        networkReachability = typeReachability
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { }

    public func downloadProgress(
        _ progress: Float,
        totalBytes: Int64,
        totalBytesExpected: Int64,
        fileName: String,
        serverUrl: String,
        session: URLSession,
        task: URLSessionTask
    ) { }

    public func uploadProgress(
        _ progress: Float,
        totalBytes: Int64,
        totalBytesExpected: Int64,
        fileName: String,
        serverUrl: String,
        session: URLSession,
        task: URLSessionTask
    ) { }

    public func downloadingFinish(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) { }

    public func downloadComplete(
        fileName: String,
        serverUrl: String,
        etag: String?,
        date: Date?,
        dateLastModified: Date?,
        length: Int64,
        task: URLSessionTask,
        error: NKError
    ) { }

    public func uploadComplete(
        fileName: String,
        serverUrl: String,
        ocId: String?,
        etag: String?,
        date: Date?,
        size: Int64,
        task: URLSessionTask,
        error: NKError
    ) { }

    public func request<Value>(
        _ request: Alamofire.DataRequest, didParseResponse response: Alamofire.AFDataResponse<Value>
    ) { }
}
