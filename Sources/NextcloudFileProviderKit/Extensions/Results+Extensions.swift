//
//  Results+Extensions.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-18.
//

import Realm
import RealmSwift

extension Results where Element: ItemMetadata {
    func toUnmanagedResults() -> [ItemMetadata] {
        return map { ItemMetadata(value: $0) }
    }
}
