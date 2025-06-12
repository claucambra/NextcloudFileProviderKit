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
import OSLog

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
            if networkReachability == .notReachable {
                logger.info("Network unreachable, stopping websocket and stopping polling")
                stopPollingTimer()
            } else if oldValue == .notReachable {
                logger.info("Network reachable, trying to reconnect to websocket")
                startPollingTimer()
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
                self?.logger.info("Polling timer timeout, notifying change")
                self?.changeNotificationInterface.notifyChange()
            }
            logger.info("Starting polling timer")
        }
    }

    private func stopPollingTimer() {
        Task { @MainActor in
            logger.info("Stopping polling timer")
            pollingTimer?.invalidate()
            pollingTimer = nil
        }
    }

    public func connect() {
        startPollingTimer()
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
