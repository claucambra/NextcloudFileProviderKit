//
//  Logging.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 6/6/25.
//

import Foundation
import OSLog

class NCFPKLogger {
    enum LogLevel: Comparable {
        case none, error, warning, info, debug
    }

    let systemLogger: Logger
    var logLevel = LogLevel.info

    public init(logLevel: LogLevel = .info, category: String) {
        self.logLevel = logLevel
        self.systemLogger = Logger(subsystem: Logger.subsystem, category: category)
    }

    func error(_ string: String) {
        guard logLevel >= .error else { return }
        systemLogger.error("\(string, privacy: .public)")
    }

    func warning(_ string: String) {
        guard logLevel >= .warning else { return }
        systemLogger.warning("\(string, privacy: .public)")
    }

    func info(_ string: String) {
        guard logLevel >= .info else { return }
        systemLogger.info("\(string, privacy: .public)")
    }

    func debug(_ string: String) {
        guard logLevel >= .debug else { return }
        systemLogger.debug("\(string, privacy: .public)")
    }
}
