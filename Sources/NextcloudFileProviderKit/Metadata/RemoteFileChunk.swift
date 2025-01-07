//
//  RemoteFileChunk.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2025-01-08.
//

import Foundation
import NextcloudKit
import RealmSwift

public class RemoteFileChunk: Object {
    @Persisted public var fileName: String
    @Persisted public var size: Int64
    @Persisted public var uploadUuid: String

    static func fromNcKitChunks(_ chunks: [(fileName: String, size: Int64)]) -> [RemoteFileChunk] {
        chunks.map { RemoteFileChunk(ncKitChunk: $0) }
    }

    convenience init(ncKitChunk: (fileName: String, size: Int64)) {
        self.init()
        fileName = ncKitChunk.fileName
        size = ncKitChunk.size
    }

    func toNcKitChunk() -> (fileName: String, size: Int64) {
        (fileName, size)
    }
}

extension Array<RemoteFileChunk> {
    func toNcKitChunks() -> [(fileName: String, size: Int64)] {
        map { ($0.fileName, $0.size) }
    }
}
