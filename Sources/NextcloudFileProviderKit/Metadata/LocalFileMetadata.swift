/*
 * Copyright (C) 2023 by Claudio Cambra <claudio.cambra@nextcloud.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

import Foundation
import RealmSwift

public class LocalFileMetadata: Object {
    @Persisted(primaryKey: true) public var ocId: String
    @Persisted public var account = ""
    @Persisted public var etag = ""
    @Persisted public var exifDate: Date?
    @Persisted public var exifLatitude = ""
    @Persisted public var exifLongitude = ""
    @Persisted public var exifLensModel: String?
    @Persisted public var favorite: Bool = false
    @Persisted public var fileName = ""
    @Persisted public var offline: Bool = false
}
