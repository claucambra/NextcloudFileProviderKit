//
//  Item+KeepDownloaded.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 13/5/25.
//

import FileProvider

public extension Item {
    func toggle(keepDownloadedIn domain: NSFileProviderDomain) async throws {
        try await set(keepDownloaded: !keepDownloaded, domain: domain)
    }

    func set(keepDownloaded: Bool, domain: NSFileProviderDomain) async throws {
        try dbManager.set(keepDownloaded: keepDownloaded, for: metadata)

        guard let manager = NSFileProviderManager(for: domain) else {
            if #available(macOS 14.1, *) {
                throw NSFileProviderError(.providerDomainNotFound)
            } else {
                let providerDomainNotFoundErrorCode = -2013
                throw NSError(
                    domain: NSFileProviderErrorDomain,
                    code: providerDomainNotFoundErrorCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to get manager for domain."]
                )
            }
        }

        if #available(macOS 13.0, iOS 16.0, visionOS 1.0, *) {
            if keepDownloaded && !isDownloaded {
                try await manager.requestDownloadForItem(withIdentifier: itemIdentifier)
            } else {
                try await manager.requestModification(
                    of: [.lastUsedDate], forItemWithIdentifier: itemIdentifier
                )
            }
        } else {
            try await manager.signalEnumerator(for: .workingSet)
        }
    }
}
