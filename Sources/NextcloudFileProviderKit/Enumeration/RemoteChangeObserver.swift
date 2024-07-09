//
//  RemoteChangeObserver.swift
//
//
//  Created by Claudio Cambra on 17/4/24.
//

import FileProvider
import Foundation
import NextcloudCapabilitiesKit
import NextcloudKit
import OSLog

public let NotifyPushAuthenticatedNotificationName = Notification.Name("NotifyPushAuthenticated")

public class RemoteChangeObserver: NSObject, NKCommonDelegate, URLSessionWebSocketDelegate {
    public let remoteInterface: RemoteInterface
    public let changeNotificationInterface: ChangeNotificationInterface
    public let domain: NSFileProviderDomain?
    public var accountId: String { remoteInterface.account.ncKitAccount }

    public var webSocketPingIntervalNanoseconds: UInt64 = 3 * 1_000_000_000
    public var webSocketReconfigureIntervalNanoseconds: UInt64 = 1 * 1_000_000_000
    public var webSocketPingFailLimit = 8
    public var webSocketAuthenticationFailLimit = 3
    public var webSocketTaskActive: Bool { webSocketTask != nil }

    private let logger = Logger(subsystem: Logger.subsystem, category: "changeobserver")

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
            if oldValue == .notReachable, networkReachability != .notReachable {
                reconnectWebSocket()
                changeNotificationInterface.notifyChange()
            }
        }
    }

    public init(
        remoteInterface: RemoteInterface,
        changeNotificationInterface: ChangeNotificationInterface,
        domain: NSFileProviderDomain?
    ) {
        self.remoteInterface = remoteInterface
        self.changeNotificationInterface = changeNotificationInterface
        self.domain = domain
        super.init()
        connect()
    }

    private func startPollingTimer() {
        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval, repeats: true
        ) { [weak self] _ in
            self?.changeNotificationInterface.notifyChange()
        }
        RunLoop.current.add(pollingTimer!, forMode: .common)
    }

    private func stopPollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = nil
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
            logger.error("Network unreachable, will retry when reconnected")
            return
        }
        guard webSocketAuthenticationFailCount < webSocketAuthenticationFailLimit else {
            logger.error(
                """
                Exceeded authentication failures for notify push websocket
                \(self.accountId, privacy: .public),
                will poll instead.
                """
            )
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
            self.logger.error(
                """
                Could not get \(self.accountId, privacy: .public) capabilities:
                \(error.errorCode, privacy: .public)
                \(error.errorDescription, privacy: .public)
                """
            )
            reconnectWebSocket()
            return
        }

        guard let capabilitiesData = capabilitiesData,
              let capabilities = Capabilities(data: capabilitiesData),
              let websocketEndpoint = capabilities.notifyPush?.endpoints?.websocket
        else {
            logger.error(
                """
                Could not get notifyPush websocket \(self.accountId, privacy: .public), polling.
                """
            )
            startPollingTimer()
            return
        }

        guard let websocketEndpointUrl = URL(string: websocketEndpoint) else {
            logger.error(
                """
                Received notifyPush endpoint is invalid: \(websocketEndpoint, privacy: .public)
                """
            )
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
        logger.info(
            """
            Successfully configured push notifications for \(self.accountId, privacy: .public)
            """
        )
    }

    public func authenticationChallenge(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let authMethod = challenge.protectionSpace.authenticationMethod
        logger.debug("Received auth challenge with method: \(authMethod, privacy: .public)")
        if authMethod == NSURLAuthenticationMethodHTTPBasic {
            let credential = URLCredential(
                user: remoteInterface.account.username,
                password: remoteInterface.account.password,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        } else if authMethod == NSURLAuthenticationMethodServerTrust {
            // TODO: Validate the server trust
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                logger.warning("Received server trust auth challenge but no trust avail")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            logger.warning("Unhandled auth method: \(authMethod, privacy: .public)")
            // Handle other authentication methods or cancel the challenge
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        logger.debug("Websocket connected \(self.accountId, privacy: .public) sending auth details")
        Task { await authenticateWebSocket() }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        logger.debug("Socket connection closed for \(self.accountId, privacy: .public).")
        if let reason = reason {
            logger.debug("Reason: \(String(data: reason, encoding: .utf8) ?? "", privacy: .public)")
        }
        logger.debug("Retrying websocket connection for \(self.accountId, privacy: .public).")
        reconnectWebSocket()
    }

    private func authenticateWebSocket() async {
        do {
            try await webSocketTask?.send(.string(remoteInterface.account.username))
            try await webSocketTask?.send(.string(remoteInterface.account.password))
        } catch let error {
            logger.error(
                """
                Error authenticating websocket for \(self.accountId, privacy: .public):
                \(error.localizedDescription, privacy: .public)
                """
            )
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
            } catch let error {
                self.logger.error(
                    """
                    Could not sleep websocket ping for \(self.accountId, privacy: .public):
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
            guard !Task.isCancelled else { return }
            self.pingWebSocket()
        }
    }

    private func pingWebSocket() {  // Keep the socket connection alive
        guard networkReachability != .notReachable else {
            logger.error("Not pinging \(self.accountId, privacy: .public), network is unreachable")
            return
        }

        webSocketTask?.sendPing { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                self.logger.warning(
                    """
                    Websocket ping failed: \(error?.localizedDescription ?? "", privacy: .public)
                    """
                )
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
                self.logger.debug("Failed to read websocket \(self.accountId, privacy: .public)")
                // Do not reconnect here, delegate methods will handle reconnecting
            case .success(let message):
                switch message {
                case .data(let data):
                    self.processWebsocket(data: data)
                case .string(let string):
                    self.processWebsocket(string: string)
                @unknown default:
                    self.logger.error("Unknown case encountered while reading websocket!")
                }
                self.readWebSocket()
            }
        }
    }

    private func processWebsocket(data: Data) {
        guard let string = String(data: data, encoding: .utf8) else {
            logger.error("Could parse websocket data for id: \(self.accountId, privacy: .public)")
            return
        }
        processWebsocket(string: string)
    }

    private func processWebsocket(string: String) {
        logger.debug("Received websocket string: \(string, privacy: .public)")
        if string == "notify_file" {
            logger.debug("Received file notification for \(self.accountId, privacy: .public)")
            changeNotificationInterface.notifyChange()
        } else if string == "notify_activity" {
            logger.debug("Ignoring activity notification: \(self.accountId, privacy: .public)")
        } else if string == "notify_notification" {
            logger.debug("Ignoring notification: \(self.accountId, privacy: .public)")
        } else if string == "authenticated" {
            logger.debug("Correctly authed websocket \(self.accountId, privacy: .public), pinging")
            NotificationCenter.default.post(
                name: NotifyPushAuthenticatedNotificationName, object: self
            )
            startNewWebSocketPingTask()
        } else if string == "err: Invalid credentials" {
            logger.debug(
                """
                Invalid creds for websocket for \(self.accountId, privacy: .public),
                reattempting auth.
                """
            )
            webSocketAuthenticationFailCount += 1
            reconnectWebSocket()
        } else {
            logger.warning(
                """
                Received unknown string from websocket \(self.accountId, privacy: .public):
                \(string, privacy: .public)
                """
            )
        }
    }

    public func networkReachabilityObserver(_ typeReachability: NKCommon.TypeReachability) {
        networkReachability = typeReachability
    }
}
