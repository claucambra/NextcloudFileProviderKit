//
//  Upload.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-29.
//

import Alamofire
import Foundation
import NextcloudKit
import OSLog
import RealmSwift

let defaultFileChunkSize = 10_000_000 // 10 MB
let uploadLogger = Logger(subsystem: Logger.subsystem, category: "upload")

func upload(
    fileLocatedAt localFilePath: String,
    toRemotePath remotePath: String,
    usingRemoteInterface remoteInterface: RemoteInterface,
    withAccount account: Account,
    inChunksSized chunkSize: Int = defaultFileChunkSize,
    usingChunkUploadId chunkUploadId: String = UUID().uuidString,
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

        return (
            ocId: ocId,
            chunks: nil,
            etag: etag,
            date: date as? Date,
            size: size,
            afError: afError,
            remoteError: remoteError
        )
    }

    uploadLogger.info(
        """
        Performing chunked upload to \(remotePath, privacy: .public)
            localFilePath: \(localFilePath, privacy: .public)
            remoteChunkStoreFolderName: \(chunkUploadId, privacy: .public)
            chunkSize: \(chunkSize, privacy: .public)
        """
    )

    let remainingChunks = dbManager
        .ncDatabase()
        .objects(RemoteFileChunk.self)
        .toUnmanagedResults()
        .filter { $0.remoteChunkStoreFolderName == chunkUploadId }

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
            uploadLogger.info(
                """
                \(localFilePath, privacy: .public) current chunk: \(currentChunk, privacy: .public)
                """
            )
        },
        chunkUploadStartHandler: { chunks in
            uploadLogger.info("\(localFilePath, privacy: .public) uploading chunk")
            let db = dbManager.ncDatabase()
            do {
                try db.write { db.add(chunks.map { RemoteFileChunk(value: $0) }) }
            } catch let error {
                uploadLogger.error(
                    """
                    Could not write chunks to db, won't be able to resume upload if transfer stops.
                        \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        },
        requestHandler: requestHandler,
        taskHandler: taskHandler,
        progressHandler: progressHandler,
        chunkUploadCompleteHandler: { chunk in
            uploadLogger.info("\(localFilePath, privacy: .public) uploaded chunk!")
            let db = dbManager.ncDatabase()
            do {
                try db.write {
                    let dbChunks = db.objects(RemoteFileChunk.self)
                    dbChunks
                        .filter {
                            $0.remoteChunkStoreFolderName == chunkUploadId &&
                            $0.fileName == chunk.fileName
                        }
                        .forEach { db.delete($0) } }
            } catch let error {
                uploadLogger.error(
                    """
                    Could not delete chunks in db, won't resume upload correctly if transfer stops.
                        \(error.localizedDescription, privacy: .public)
                    """
                )
            }
            chunkUploadCompleteHandler(chunk)
        }
    )

    uploadLogger.info("\(localFilePath, privacy: .public) successfully uploaded in chunks")

    return (
        ocId: file?.ocId,
        chunks: chunks,
        etag: file?.etag,
        date: file?.date,
        size: file?.size,
        afError: afError,
        remoteError: remoteError
    )
}
