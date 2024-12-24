//
//  FilesDatabaseManager+Trash.swift
//  NextcloudFileProviderKit
//
//  Created by Claudio Cambra on 2024-12-02.
//

import RealmSwift

extension FilesDatabaseManager {
    func trashedItemMetadatas(account: Account) -> Results<ItemMetadata> {
        ncDatabase()
            .objects(ItemMetadata.self)
            .filter(
                "account == %@ AND serverUrl BEGINSWITH %@",
                account.ncKitAccount,
                account.trashUrl
            )
    }
}
