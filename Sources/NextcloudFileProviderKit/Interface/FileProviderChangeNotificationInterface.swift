//
//  FileProviderChangeNotificationInterface.swift
//
//
//  Created by Claudio Cambra on 16/5/24.
//

import FileProvider
import Foundation

public class FileProviderChangeNotificationInterface: ChangeNotificationInterface {
    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
    }

    public func notifyChange() {
        Task { @MainActor in
            if let manager = NSFileProviderManager(for: domain) {
                do {
                    try await manager.signalEnumerator(for: .workingSet)
                } catch {
                }
            }
        }
    }
}
