import Foundation
import SQLite3

public struct ArchiveIndexAsset: Equatable, Sendable {
    public let assetIdentifier: String
    public let creationDate: Date?
    public let modificationDate: Date?
    public let mediaKind: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval
    public let isLivePhoto: Bool
    public let isFavorite: Bool
    public let isHidden: Bool
    public let isArchived: Bool
    public let needsReview: Bool

    public init(
        assetIdentifier: String,
        creationDate: Date?,
        modificationDate: Date?,
        mediaKind: String,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval,
        isLivePhoto: Bool,
        isFavorite: Bool,
        isHidden: Bool,
        isArchived: Bool = false,
        needsReview: Bool = false
    ) {
        self.assetIdentifier = assetIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.mediaKind = mediaKind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isLivePhoto = isLivePhoto
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.isArchived = isArchived
        self.needsReview = needsReview
    }

    public var inventorySnapshot: InventoryAssetSnapshot {
        InventoryAssetSnapshot(
            creationDate: creationDate,
            mediaKind: mediaKind,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration,
            isLivePhoto: isLivePhoto,
            isFavorite: isFavorite,
            isHidden: isHidden
        )
    }
}

public struct ArchiveProfileRecord: Equatable, Sendable {
    public let identifier: String
    public let targetCutoffDate: Date?
    public let photoKitChangeToken: Data?
    public let lastFullScanAt: Date?
    public let lastDeltaScanAt: Date?

    public init(
        identifier: String,
        targetCutoffDate: Date?,
        photoKitChangeToken: Data?,
        lastFullScanAt: Date?,
        lastDeltaScanAt: Date?
    ) {
        self.identifier = identifier
        self.targetCutoffDate = targetCutoffDate
        self.photoKitChangeToken = photoKitChangeToken
        self.lastFullScanAt = lastFullScanAt
        self.lastDeltaScanAt = lastDeltaScanAt
    }
}

public struct ArchiveIndexSyncBatch: Sendable {
    public let assets: [ArchiveIndexAsset]
    public let deletedAssetIdentifiers: Set<String>
    public let isFullScan: Bool
    public let photoKitChangeToken: Data
    public let synchronizedAt: Date

    public init(
        assets: [ArchiveIndexAsset],
        deletedAssetIdentifiers: Set<String> = [],
        isFullScan: Bool,
        photoKitChangeToken: Data,
        synchronizedAt: Date = Date()
    ) {
        self.assets = assets
        self.deletedAssetIdentifiers = deletedAssetIdentifiers
        self.isFullScan = isFullScan
        self.photoKitChangeToken = photoKitChangeToken
        self.synchronizedAt = synchronizedAt
    }
}

public enum ArchiveIndexError: Error, LocalizedError, Sendable {
    case cannotCreateDirectory(String)
    case cannotOpenDatabase(String)
    case sqlite(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let path):
            "ColdShot could not create its local index directory: \(path)"
        case .cannotOpenDatabase(let path):
            "ColdShot could not open its local index: \(path)"
        case .sqlite(let code, let message):
            "SQLite error \(code): \(message)"
        }
    }
}

public actor ArchiveIndexStore {
    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func profile(identifier: String) throws -> ArchiveProfileRecord? {
        try withDatabase { db in
            let sql = """
                SELECT target_cutoff, change_token, last_full_scan, last_delta_scan
                FROM archive_profiles WHERE identifier = ? LIMIT 1
                """
            let statement = try prepare(sql, db: db)
            defer { sqlite3_finalize(statement) }
            try bind(identifier, at: 1, statement: statement, db: db)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return ArchiveProfileRecord(
                identifier: identifier,
                targetCutoffDate: optionalDate(statement, column: 0),
                photoKitChangeToken: optionalData(statement, column: 1),
                lastFullScanAt: optionalDate(statement, column: 2),
                lastDeltaScanAt: optionalDate(statement, column: 3)
            )
        }
    }

    public func saveTargetCutoffDate(_ date: Date?, profileIdentifier: String) throws {
        try withDatabase { db in
            let statement = try prepare(
                """
                INSERT INTO archive_profiles(identifier, target_cutoff)
                VALUES(?, ?)
                ON CONFLICT(identifier) DO UPDATE SET target_cutoff = excluded.target_cutoff
                """,
                db: db
            )
            defer { sqlite3_finalize(statement) }
            try bind(profileIdentifier, at: 1, statement: statement, db: db)
            try bind(date, at: 2, statement: statement, db: db)
            try stepDone(statement, db: db)
        }
    }

    public func apply(_ batch: ArchiveIndexSyncBatch, profileIdentifier: String) throws {
        try withDatabase { db in
            try execute("BEGIN IMMEDIATE TRANSACTION", db: db)
            do {
                if batch.isFullScan {
                    try execute("UPDATE photo_assets SET is_deleted = 1", db: db)
                }
                for asset in batch.assets {
                    try upsert(asset, db: db)
                }
                for identifier in batch.deletedAssetIdentifiers {
                    let statement = try prepare(
                        "UPDATE photo_assets SET is_deleted = 1, needs_review = 1 WHERE asset_identifier = ?",
                        db: db
                    )
                    do {
                        try bind(identifier, at: 1, statement: statement, db: db)
                        try stepDone(statement, db: db)
                        sqlite3_finalize(statement)
                    } catch {
                        sqlite3_finalize(statement)
                        throw error
                    }
                }
                let profile = try prepare(
                    """
                    INSERT INTO archive_profiles(
                        identifier, change_token, last_full_scan, last_delta_scan
                    ) VALUES(?, ?, ?, ?)
                    ON CONFLICT(identifier) DO UPDATE SET
                        change_token = excluded.change_token,
                        last_full_scan = coalesce(excluded.last_full_scan, archive_profiles.last_full_scan),
                        last_delta_scan = excluded.last_delta_scan
                    """,
                    db: db
                )
                defer { sqlite3_finalize(profile) }
                try bind(profileIdentifier, at: 1, statement: profile, db: db)
                try bind(batch.photoKitChangeToken, at: 2, statement: profile, db: db)
                try bind(batch.isFullScan ? batch.synchronizedAt : nil, at: 3, statement: profile, db: db)
                try bind(batch.synchronizedAt, at: 4, statement: profile, db: db)
                try stepDone(profile, db: db)
                try execute("COMMIT", db: db)
            } catch {
                try? execute("ROLLBACK", db: db)
                throw error
            }
        }
    }

    public func assets() throws -> [ArchiveIndexAsset] {
        try withDatabase { db in
            let statement = try prepare(
                """
                SELECT asset_identifier, creation_date, modification_date, media_kind,
                       pixel_width, pixel_height, duration, is_live_photo,
                       is_favorite, is_hidden, is_archived, needs_review
                FROM photo_assets
                WHERE is_deleted = 0
                ORDER BY creation_date IS NULL, creation_date, asset_identifier
                """,
                db: db
            )
            defer { sqlite3_finalize(statement) }
            var result: [ArchiveIndexAsset] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(
                    ArchiveIndexAsset(
                        assetIdentifier: string(statement, column: 0),
                        creationDate: optionalDate(statement, column: 1),
                        modificationDate: optionalDate(statement, column: 2),
                        mediaKind: string(statement, column: 3),
                        pixelWidth: Int(sqlite3_column_int64(statement, 4)),
                        pixelHeight: Int(sqlite3_column_int64(statement, 5)),
                        duration: sqlite3_column_double(statement, 6),
                        isLivePhoto: sqlite3_column_int(statement, 7) != 0,
                        isFavorite: sqlite3_column_int(statement, 8) != 0,
                        isHidden: sqlite3_column_int(statement, 9) != 0,
                        isArchived: sqlite3_column_int(statement, 10) != 0,
                        needsReview: sqlite3_column_int(statement, 11) != 0
                    )
                )
            }
            return result
        }
    }

    public func replaceArchivedIdentifiers(_ identifiers: Set<String>) throws {
        try withDatabase { db in
            try execute("BEGIN IMMEDIATE TRANSACTION", db: db)
            do {
                try execute("UPDATE photo_assets SET is_archived = 0", db: db)
                for identifier in identifiers {
                    let statement = try prepare(
                        "UPDATE photo_assets SET is_archived = 1 WHERE asset_identifier = ?",
                        db: db
                    )
                    do {
                        try bind(identifier, at: 1, statement: statement, db: db)
                        try stepDone(statement, db: db)
                        sqlite3_finalize(statement)
                    } catch {
                        sqlite3_finalize(statement)
                        throw error
                    }
                }
                try execute("COMMIT", db: db)
            } catch {
                try? execute("ROLLBACK", db: db)
                throw error
            }
        }
    }

    public func markArchived(_ identifiers: Set<String>) throws {
        guard !identifiers.isEmpty else { return }
        try withDatabase { db in
            try execute("BEGIN IMMEDIATE TRANSACTION", db: db)
            do {
                for identifier in identifiers {
                    let statement = try prepare(
                        "UPDATE photo_assets SET is_archived = 1, needs_review = 0 WHERE asset_identifier = ?",
                        db: db
                    )
                    do {
                        try bind(identifier, at: 1, statement: statement, db: db)
                        try stepDone(statement, db: db)
                        sqlite3_finalize(statement)
                    } catch {
                        sqlite3_finalize(statement)
                        throw error
                    }
                }
                try execute("COMMIT", db: db)
            } catch {
                try? execute("ROLLBACK", db: db)
                throw error
            }
        }
    }

    private func upsert(_ asset: ArchiveIndexAsset, db: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT INTO photo_assets(
                asset_identifier, creation_date, modification_date, media_kind,
                pixel_width, pixel_height, duration, is_live_photo,
                is_favorite, is_hidden, is_deleted, is_archived, needs_review
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
            ON CONFLICT(asset_identifier) DO UPDATE SET
                needs_review = CASE
                    WHEN photo_assets.is_archived = 1
                     AND photo_assets.modification_date IS NOT excluded.modification_date
                    THEN 1 ELSE photo_assets.needs_review END,
                creation_date = excluded.creation_date,
                modification_date = excluded.modification_date,
                media_kind = excluded.media_kind,
                pixel_width = excluded.pixel_width,
                pixel_height = excluded.pixel_height,
                duration = excluded.duration,
                is_live_photo = excluded.is_live_photo,
                is_favorite = excluded.is_favorite,
                is_hidden = excluded.is_hidden,
                is_deleted = 0
            """,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        try bind(asset.assetIdentifier, at: 1, statement: statement, db: db)
        try bind(asset.creationDate, at: 2, statement: statement, db: db)
        try bind(asset.modificationDate, at: 3, statement: statement, db: db)
        try bind(asset.mediaKind, at: 4, statement: statement, db: db)
        sqlite3_bind_int64(statement, 5, Int64(asset.pixelWidth))
        sqlite3_bind_int64(statement, 6, Int64(asset.pixelHeight))
        sqlite3_bind_double(statement, 7, asset.duration)
        sqlite3_bind_int(statement, 8, asset.isLivePhoto ? 1 : 0)
        sqlite3_bind_int(statement, 9, asset.isFavorite ? 1 : 0)
        sqlite3_bind_int(statement, 10, asset.isHidden ? 1 : 0)
        sqlite3_bind_int(statement, 11, asset.isArchived ? 1 : 0)
        sqlite3_bind_int(statement, 12, asset.needsReview ? 1 : 0)
        try stepDone(statement, db: db)
    }

    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ArchiveIndexError.cannotCreateDirectory(directory.path)
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ArchiveIndexError.cannotOpenDatabase(databaseURL.path)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        try migrate(database)
        return try operation(database)
    }

    private func migrate(_ db: OpaquePointer) throws {
        try execute("PRAGMA journal_mode = WAL", db: db)
        try execute("PRAGMA foreign_keys = ON", db: db)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS archive_profiles(
                identifier TEXT PRIMARY KEY NOT NULL,
                target_cutoff REAL,
                change_token BLOB,
                last_full_scan REAL,
                last_delta_scan REAL
            ) STRICT
            """,
            db: db
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS photo_assets(
                asset_identifier TEXT PRIMARY KEY NOT NULL,
                creation_date REAL,
                modification_date REAL,
                media_kind TEXT NOT NULL,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                duration REAL NOT NULL,
                is_live_photo INTEGER NOT NULL,
                is_favorite INTEGER NOT NULL,
                is_hidden INTEGER NOT NULL,
                is_deleted INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0,
                needs_review INTEGER NOT NULL DEFAULT 0
            ) STRICT
            """,
            db: db
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS photo_assets_creation ON photo_assets(creation_date, asset_identifier)",
            db: db
        )
    }

    private func execute(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            throw ArchiveIndexError.sqlite(code: result, message: message)
        }
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw ArchiveIndexError.sqlite(code: result, message: String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer, db: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw ArchiveIndexError.sqlite(code: result, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: String, at index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = sqlite3_bind_text(statement, index, value, -1, destructor)
        guard result == SQLITE_OK else {
            throw ArchiveIndexError.sqlite(code: result, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: Data, at index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), destructor)
        }
        guard result == SQLITE_OK else {
            throw ArchiveIndexError.sqlite(code: result, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: Date?, at index: Int32, statement: OpaquePointer, db: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw ArchiveIndexError.sqlite(code: result, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func optionalData(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}
