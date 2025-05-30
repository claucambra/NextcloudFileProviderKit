//
//  Item+Delete.swift
//
//
//  Created by Claudio Cambra on 15/4/24.
//

import FileProvider
import Foundation
import NextcloudKit
public extension Item {
    // NOTE: the trashing metadata modification procedure here is rough. You SHOULD run a rescan of
    // the trash in order to ensure you are getting a correct picture of the item's current remote
    // state! This is important particularly for receiving the correct trash bin filename in case of
    // there being a previous item in the trash with the same name, prompting the server to rename
    // the newly-trashed target item
    func delete(
        trashing: Bool = false,
        domain: NSFileProviderDomain? = nil,
        dbManager: FilesDatabaseManager = .shared
    ) async -> Error? {
        let serverFileNameUrl = metadata.serverUrl + "/" + metadata.fileName
        guard serverFileNameUrl != "" else {
            return NSFileProviderError(.noSuchItem)
        }
        let ocId = itemIdentifier.rawValue

        let (_, _, error) = await remoteInterface.delete(
            remotePath: serverFileNameUrl,
            account: account,
            options: .init(),
            taskHandler: { task in
                if let domain {
                    NSFileProviderManager(for: domain)?.register(
                        task,
                        forItemWithIdentifier: self.itemIdentifier,
                        completionHandler: { _ in }
                    )
                }
        })

        guard error == .success else {
            return error.fileProviderError
        }

        guard !trashing else {
            if self.metadata.directory {
                _ = dbManager.renameDirectoryAndPropagateToChildren(
                    ocId: ocId,
                    newServerUrl: account.trashUrl,
                    newFileName: filename
                )
            } else {
                dbManager.renameItemMetadata(
                    ocId: ocId, newServerUrl: account.trashUrl, newFileName: filename
                )
            }

            guard var metadata = dbManager.itemMetadata(ocId: ocId) else {
                return NSFileProviderError(.cannotSynchronize)
            }
            metadata.trashbinFileName = filename
            metadata.trashbinDeletionTime = Date()
            metadata.trashbinOriginalLocation =
                String(self.metadata.serverUrl + "/" + filename).replacingOccurrences(
                    of: account.davFilesUrl + "/", with: ""
                )

            dbManager.addItemMetadata(metadata)

            return nil
        }
        if self.metadata.directory {
            _ = dbManager.deleteDirectoryAndSubdirectoriesMetadata(ocId: ocId)
        } else {
            dbManager.deleteItemMetadata(ocId: ocId)
        }
        return nil
    }
}
