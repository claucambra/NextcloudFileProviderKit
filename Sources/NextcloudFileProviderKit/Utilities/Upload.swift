//
//  Upload.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-29.
//

import Alamofire
import Foundation
import NextcloudCapabilitiesKit
import NextcloudKit
import RealmSwift

let defaultFileChunkSize = 104_857_600 // 100 MiB

func upload(
    fileLocatedAt localFilePath: String,
    toRemotePath remotePath: String,
    usingRemoteInterface remoteInterface: RemoteInterface,
    withAccount account: Account,
    inChunksSized chunkSize: Int? = nil,
    usingChunkUploadId chunkUploadId: String? = UUID().uuidString,
    dbManager: FilesDatabaseManager = .shared,
    creationDate: Date? = nil,
    modificationDate: Date? = nil,
    options: NKRequestOptions = .init(queue: .global(qos: .utility)),
    requestHandler: @escaping (UploadRequest) -> Void = { _ in },
    taskHandler: @escaping (URLSessionTask) -> Void = { _ in },
    progressHandler: @escaping (Progress) -> Void = { _ in },
    chunkUploadCompleteHandler: @escaping (_ fileChunk: RemoteFileChunk) -> Void  = { _ in }
) async -> (
    ocId: String?,
    chunks: [RemoteFileChunk]?,
    etag: String?,
    date: Date?,
    size: Int64?,
    afError: AFError?,
    remoteError: NKError
) {
    let fileSize =
        (try? FileManager.default.attributesOfItem(atPath: localFilePath)[.size] as? Int64) ?? 0

    let chunkSize = await {
        if let chunkSize {
            return chunkSize
        }
        let (_, capabilitiesData, error) = await remoteInterface.fetchCapabilities(
            account: account, options: options, taskHandler: taskHandler
        )
        guard let capabilitiesData,
              let capabilities = Capabilities(data: capabilitiesData),
              let serverChunkSize = capabilities.files?.chunkedUpload?.maxChunkSize,
              serverChunkSize > 0
        else {
            return defaultFileChunkSize
        }
        return Int(serverChunkSize)
    }()

    guard fileSize > chunkSize else {
        let (_, ocId, etag, date, size, _, afError, remoteError) = await remoteInterface.upload(
            remotePath: remotePath,
            localPath: localFilePath,
            creationDate: creationDate,
            modificationDate: modificationDate,
            account: account,
            options: options,
            requestHandler: requestHandler,
            taskHandler: taskHandler,
            progressHandler: progressHandler
        )

        return (ocId, nil, etag, date as? Date, size, afError, remoteError)
    }

    let chunkUploadId = chunkUploadId ?? UUID().uuidString

    let remainingChunks = dbManager
        .ncDatabase()
        .objects(RemoteFileChunk.self)
        .where({ $0.remoteChunkStoreFolderName == chunkUploadId })
        .toUnmanagedResults()

    let (_, chunks, file, afError, remoteError) = await remoteInterface.chunkedUpload(
        localPath: localFilePath,
        remotePath: remotePath,
        remoteChunkStoreFolderName: chunkUploadId,
        chunkSize: chunkSize,
        remainingChunks: remainingChunks,
        creationDate: creationDate,
        modificationDate: modificationDate,
        account: account,
        options: options,
        currentNumChunksUpdateHandler: { _ in },
        chunkCounter: { currentChunk in
        },
        chunkUploadStartHandler: { chunks in
            // Do not add chunks to database if we have done this already
            guard remainingChunks.isEmpty else { return }

            let db = dbManager.ncDatabase()
            do {
                try db.write { db.add(chunks.map { RemoteFileChunk(value: $0) }) }
            } catch {
            }
        },
        requestHandler: requestHandler,
        taskHandler: taskHandler,
        progressHandler: progressHandler,
        chunkUploadCompleteHandler: { chunk in
            let db = dbManager.ncDatabase()
            do {
                try db.write {
                    db
                        .objects(RemoteFileChunk.self)
                        .where {
                            $0.remoteChunkStoreFolderName == chunkUploadId &&
                            $0.fileName == chunk.fileName
                        }
                        .forEach { db.delete($0) } }
            } catch {
            }
            chunkUploadCompleteHandler(chunk)
        }
    )

    return (file?.ocId, chunks, file?.etag, file?.date, file?.size, afError, remoteError)
}
