import Foundation

public enum BatchAssetState: String, Codable, Equatable, Sendable {
    case pending
    case archiving
    case archived
    case failed
}

public struct BatchAssetRecord: Codable, Equatable, Sendable {
    public var asset: ArchiveAssetPlan
    public var state: BatchAssetState
    public var manifestRelativePath: String?
    public var archivedByteCount: Int64
    public var lastError: String?
    public var diagnosticError: String?
    public var failureCategory: ArchiveFailureCategory?
    public var attemptCount: Int?

    public init(
        asset: ArchiveAssetPlan,
        state: BatchAssetState = .pending,
        manifestRelativePath: String? = nil,
        archivedByteCount: Int64 = 0,
        lastError: String? = nil,
        diagnosticError: String? = nil,
        failureCategory: ArchiveFailureCategory? = nil,
        attemptCount: Int? = 0
    ) {
        self.asset = asset
        self.state = state
        self.manifestRelativePath = manifestRelativePath
        self.archivedByteCount = archivedByteCount
        self.lastError = lastError
        self.diagnosticError = diagnosticError
        self.failureCategory = failureCategory
        self.attemptCount = attemptCount
    }
}

public struct BatchArchiveJournal: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let identifier: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public let cutoffDate: Date?
    public let archiveLayoutVersion: ArchiveLayoutVersion?
    public let selectionFilter: InventorySelectionFilter?
    public var assets: [BatchAssetRecord]

    public init(
        schemaVersion: Int = 1,
        identifier: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        cutoffDate: Date?,
        archiveLayoutVersion: ArchiveLayoutVersion? = .yearMonth,
        selectionFilter: InventorySelectionFilter? = nil,
        assets: [BatchAssetRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cutoffDate = cutoffDate
        self.archiveLayoutVersion = archiveLayoutVersion
        self.selectionFilter = selectionFilter
        self.assets = assets
    }

    public var completedCount: Int { assets.count { $0.state == .archived } }
    public var failedCount: Int { assets.count { $0.state == .failed } }
    public var processedCount: Int { completedCount + failedCount }
    public var archivedByteCount: Int64 { assets.reduce(0) { $0 + $1.archivedByteCount } }
    public var isComplete: Bool { !assets.isEmpty && completedCount == assets.count }
    public var isFinished: Bool { !assets.isEmpty && processedCount == assets.count }
}

public enum BatchArchiveEvent: Equatable, Sendable {
    case started(jobIdentifier: UUID, assetCount: Int, completedCount: Int)
    case assetStarted(index: Int, total: Int, assetIdentifier: String)
    case assetRetrying(index: Int, total: Int, assetIdentifier: String, attempt: Int, message: String)
    case archiveEvent(assetIdentifier: String, event: ArchiveEvent)
    case assetCompleted(index: Int, total: Int, assetIdentifier: String, byteCount: Int64)
    case assetFailed(index: Int, total: Int, assetIdentifier: String, message: String)
    case completed(jobIdentifier: UUID, byteCount: Int64)
    case completedWithIssues(jobIdentifier: UUID, byteCount: Int64, failedCount: Int)
}

public enum BatchVerificationEvent: Equatable, Sendable {
    case started(jobIdentifier: UUID, assetCount: Int)
    case assetVerified(index: Int, total: Int, assetIdentifier: String)
    case completed(jobIdentifier: UUID, byteCount: Int64)
}

public enum BatchArchiveError: Error, Equatable, LocalizedError, Sendable {
    case emptyBatch
    case journalNotFound(UUID)
    case unsupportedJournalVersion(Int)
    case incompleteBatchCannotBeVerified(UUID)
    case missingManifest(String)
    case manifestAssetMismatch(String)
    case refreshedAssetMismatch(expected: String, actual: String)
    case failureToleranceReached(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyBatch:
            "The archive batch contains no assets."
        case .journalNotFound(let identifier):
            "The archive batch journal was not found: \(identifier.uuidString)"
        case .unsupportedJournalVersion(let version):
            "The archive batch journal version is unsupported: \(version)"
        case .incompleteBatchCannotBeVerified(let identifier):
            "The archive batch is incomplete and cannot be verified: \(identifier.uuidString)"
        case .missingManifest(let identifier):
            "The archived asset has no manifest reference: \(identifier)"
        case .manifestAssetMismatch(let identifier):
            "The manifest does not belong to the expected Photos asset: \(identifier)"
        case .refreshedAssetMismatch(let expected, let actual):
            "The refreshed Photos plan belongs to \(actual) instead of \(expected)."
        case .failureToleranceReached(let limit):
            "The archive paused after reaching the safety limit of \(limit) unresolved asset errors."
        }
    }
}

public enum ArchiveCampaignPlanner {
    public static func ranges(
        assetCount: Int,
        maximumBatchSize: Int = 500
    ) -> [Range<Int>] {
        guard assetCount > 0, maximumBatchSize > 0 else { return [] }
        return stride(from: 0, to: assetCount, by: maximumBatchSize).map { lowerBound in
            lowerBound..<min(lowerBound + maximumBatchSize, assetCount)
        }
    }
}

public actor BatchArchiveEngine {
    public typealias SourceFactory = @Sendable (ArchiveAssetPlan) async throws -> any ArchiveResourceSource
    public typealias PlanRefresher = @Sendable (ArchiveAssetPlan) async throws -> ArchiveAssetPlan
    public typealias EventHandler = @Sendable (BatchArchiveEvent) -> Void
    public typealias VerificationEventHandler = @Sendable (BatchVerificationEvent) -> Void

    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
    }

    public func start(
        assets: [ArchiveAssetPlan],
        jobIdentifier: UUID = UUID(),
        cutoffDate: Date?,
        archiveLayoutVersion: ArchiveLayoutVersion = .yearMonth,
        selectionFilter: InventorySelectionFilter? = nil,
        destination: URL,
        planRefresher: @escaping PlanRefresher = { $0 },
        sourceFactory: @escaping SourceFactory,
        failureLimit: Int = 10,
        initialFailureCount: Int = 0,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> BatchArchiveJournal {
        guard !assets.isEmpty else { throw BatchArchiveError.emptyBatch }
        var journal = BatchArchiveJournal(
            identifier: jobIdentifier,
            createdAt: now(),
            updatedAt: now(),
            cutoffDate: cutoffDate,
            archiveLayoutVersion: archiveLayoutVersion,
            selectionFilter: selectionFilter,
            assets: assets.map { BatchAssetRecord(asset: $0) }
        )
        try save(journal, destination: destination)
        return try await run(
            journal: &journal,
            destination: destination,
            planRefresher: planRefresher,
            sourceFactory: sourceFactory,
            failureLimit: failureLimit,
            initialFailureCount: initialFailureCount,
            onEvent: onEvent
        )
    }

    public func resume(
        jobIdentifier: UUID,
        destination: URL,
        planRefresher: @escaping PlanRefresher = { $0 },
        sourceFactory: @escaping SourceFactory,
        retryFailedAssets: Bool = false,
        failureLimit: Int = 10,
        initialFailureCount: Int = 0,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> BatchArchiveJournal {
        var journal = try load(jobIdentifier: jobIdentifier, destination: destination)
        guard journal.schemaVersion == 1 else {
            throw BatchArchiveError.unsupportedJournalVersion(journal.schemaVersion)
        }

        // A completed record is only resumable if its destination manifest and
        // every referenced resource still pass their SHA-256 verification.
        let archiveEngine = ArchiveEngine(now: now)
        for record in journal.assets where record.state == .archived {
            try Task.checkCancellation()
            guard let relativePath = record.manifestRelativePath else {
                throw BatchArchiveError.missingManifest(record.asset.assetIdentifier)
            }
            let manifest = try await archiveEngine.verifyManifest(
                relativePath: relativePath,
                destination: destination
            )
            guard manifest.sourceAsset.assetIdentifier == record.asset.assetIdentifier else {
                throw BatchArchiveError.manifestAssetMismatch(record.asset.assetIdentifier)
            }
        }

        for index in journal.assets.indices where journal.assets[index].state != .archived {
            if journal.assets[index].state == .failed, !retryFailedAssets { continue }
            journal.assets[index].state = .pending
            if retryFailedAssets {
                journal.assets[index].lastError = nil
                journal.assets[index].diagnosticError = nil
                journal.assets[index].failureCategory = nil
            }
        }
        journal.updatedAt = now()
        try save(journal, destination: destination)
        return try await run(
            journal: &journal,
            destination: destination,
            planRefresher: planRefresher,
            sourceFactory: sourceFactory,
            failureLimit: failureLimit,
            initialFailureCount: initialFailureCount,
            onEvent: onEvent
        )
    }

    public func latestIncompleteJob(destination: URL) throws -> BatchArchiveJournal? {
        try jobs(destination: destination).filter { !$0.isFinished }.max { $0.updatedAt < $1.updatedAt }
    }

    public func latestCompletedJob(destination: URL) throws -> BatchArchiveJournal? {
        try jobs(destination: destination).filter(\.isComplete).max { $0.updatedAt < $1.updatedAt }
    }

    public func job(jobIdentifier: UUID, destination: URL) throws -> BatchArchiveJournal? {
        do {
            return try load(jobIdentifier: jobIdentifier, destination: destination)
        } catch BatchArchiveError.journalNotFound {
            return nil
        }
    }

    public func verify(
        jobIdentifier: UUID,
        destination: URL,
        onEvent: @escaping VerificationEventHandler = { _ in }
    ) async throws -> BatchArchiveJournal {
        let journal = try load(jobIdentifier: jobIdentifier, destination: destination)
        guard journal.schemaVersion == 1 else {
            throw BatchArchiveError.unsupportedJournalVersion(journal.schemaVersion)
        }
        guard journal.isComplete else {
            throw BatchArchiveError.incompleteBatchCannotBeVerified(jobIdentifier)
        }

        onEvent(.started(jobIdentifier: journal.identifier, assetCount: journal.assets.count))
        let archiveEngine = ArchiveEngine(now: now)
        for (index, record) in journal.assets.enumerated() {
            try Task.checkCancellation()
            guard let relativePath = record.manifestRelativePath else {
                throw BatchArchiveError.missingManifest(record.asset.assetIdentifier)
            }
            let manifest = try await archiveEngine.verifyManifest(
                relativePath: relativePath,
                destination: destination
            )
            guard manifest.sourceAsset.assetIdentifier == record.asset.assetIdentifier else {
                throw BatchArchiveError.manifestAssetMismatch(record.asset.assetIdentifier)
            }
            onEvent(.assetVerified(
                index: index + 1,
                total: journal.assets.count,
                assetIdentifier: record.asset.assetIdentifier
            ))
        }
        onEvent(.completed(jobIdentifier: journal.identifier, byteCount: journal.archivedByteCount))
        return journal
    }

    private func jobs(destination: URL) throws -> [BatchArchiveJournal] {
        let jobsDirectory = try jobsDirectory(destination: destination, create: false)
        guard fileManager.fileExists(atPath: jobsDirectory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: jobsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .map { try decodeJournal(at: $0) }
    }

    private func run(
        journal: inout BatchArchiveJournal,
        destination: URL,
        planRefresher: @escaping PlanRefresher,
        sourceFactory: @escaping SourceFactory,
        failureLimit: Int,
        initialFailureCount: Int,
        onEvent: @escaping EventHandler
    ) async throws -> BatchArchiveJournal {
        onEvent(.started(
            jobIdentifier: journal.identifier,
            assetCount: journal.assets.count,
            completedCount: journal.completedCount
        ))

        guard initialFailureCount + journal.failedCount < failureLimit else {
            throw BatchArchiveError.failureToleranceReached(failureLimit)
        }

        for index in journal.assets.indices where journal.assets[index].state == .pending
            || journal.assets[index].state == .archiving {
            try Task.checkCancellation()
            let frozenAsset = journal.assets[index].asset
            var didFinishAsset = false
            for attempt in 1...2 {
                do {
                    let asset = try await planRefresher(frozenAsset)
                    guard asset.assetIdentifier == frozenAsset.assetIdentifier else {
                        throw BatchArchiveError.refreshedAssetMismatch(
                            expected: frozenAsset.assetIdentifier,
                            actual: asset.assetIdentifier
                        )
                    }
                    journal.assets[index].asset = asset
                    journal.assets[index].state = .archiving
                    journal.assets[index].lastError = nil
                    journal.assets[index].diagnosticError = nil
                    journal.assets[index].failureCategory = nil
                    journal.assets[index].attemptCount = (journal.assets[index].attemptCount ?? 0) + 1
                    journal.updatedAt = now()
                    try save(journal, destination: destination)
                    onEvent(.assetStarted(
                        index: index + 1,
                        total: journal.assets.count,
                        assetIdentifier: asset.assetIdentifier
                    ))

                let source = try await sourceFactory(asset)
                let archiveEngine = ArchiveEngine(now: now)
                let manifest = try await archiveEngine.archive(
                    asset: asset,
                    source: source,
                    destination: destination,
                    layout: journal.archiveLayoutVersion ?? .legacyPerAsset
                ) { event in
                    onEvent(.archiveEvent(assetIdentifier: asset.assetIdentifier, event: event))
                }
                let byteCount = manifest.resources.reduce(0) { $0 + $1.byteCount }
                journal.assets[index].state = .archived
                journal.assets[index].manifestRelativePath = try await archiveEngine.committedManifestRelativePath(
                    for: asset,
                    destination: destination
                )
                journal.assets[index].archivedByteCount = byteCount
                journal.updatedAt = now()
                try save(journal, destination: destination)
                onEvent(.assetCompleted(
                    index: index + 1,
                    total: journal.assets.count,
                    assetIdentifier: asset.assetIdentifier,
                    byteCount: byteCount
                ))
                    didFinishAsset = true
                    break
                } catch is CancellationError {
                    journal.assets[index].state = .pending
                    journal.updatedAt = now()
                    try? save(journal, destination: destination)
                    throw CancellationError()
                } catch {
                    let classified = error as? any ArchiveFailureClassifying
                    let isRecoverable = classified?.archiveFailureDisposition == .recoverableAsset
                    if isRecoverable, attempt == 1 {
                        onEvent(.assetRetrying(
                            index: index + 1,
                            total: journal.assets.count,
                            assetIdentifier: frozenAsset.assetIdentifier,
                            attempt: 2,
                            message: error.localizedDescription
                        ))
                        continue
                    }

                    journal.assets[index].lastError = error.localizedDescription
                    journal.assets[index].diagnosticError = String(reflecting: error)
                    journal.assets[index].failureCategory = classified?.archiveFailureCategory ?? .unknown
                    journal.updatedAt = now()

                    if isRecoverable {
                        journal.assets[index].state = .failed
                        try save(journal, destination: destination)
                        onEvent(.assetFailed(
                            index: index + 1,
                            total: journal.assets.count,
                            assetIdentifier: frozenAsset.assetIdentifier,
                            message: error.localizedDescription
                        ))
                        didFinishAsset = true
                        if initialFailureCount + journal.failedCount >= failureLimit {
                            throw BatchArchiveError.failureToleranceReached(failureLimit)
                        }
                        break
                    }

                    journal.assets[index].state = .pending
                    try? save(journal, destination: destination)
                    onEvent(.assetFailed(
                        index: index + 1,
                        total: journal.assets.count,
                        assetIdentifier: frozenAsset.assetIdentifier,
                        message: error.localizedDescription
                    ))
                    throw error
                }
            }
            if !didFinishAsset { break }
        }

        if journal.failedCount > 0 {
            onEvent(.completedWithIssues(
                jobIdentifier: journal.identifier,
                byteCount: journal.archivedByteCount,
                failedCount: journal.failedCount
            ))
        } else {
            onEvent(.completed(jobIdentifier: journal.identifier, byteCount: journal.archivedByteCount))
        }
        return journal
    }

    private func save(_ journal: BatchArchiveJournal, destination: URL) throws {
        let directory = try jobsDirectory(destination: destination, create: true)
        let finalURL = directory.appendingPathComponent("\(journal.identifier.uuidString).json")
        let partialURL = finalURL.appendingPathExtension("partial")
        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(journal).write(to: partialURL)
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: finalURL)
        }
    }

    private func load(jobIdentifier: UUID, destination: URL) throws -> BatchArchiveJournal {
        let directory = try jobsDirectory(destination: destination, create: false)
        let url = directory.appendingPathComponent("\(jobIdentifier.uuidString).json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw BatchArchiveError.journalNotFound(jobIdentifier)
        }
        return try decodeJournal(at: url)
    }

    private func decodeJournal(at url: URL) throws -> BatchArchiveJournal {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(BatchArchiveJournal.self, from: Data(contentsOf: url))
    }

    private func jobsDirectory(destination: URL, create: Bool) throws -> URL {
        let directory = destination
            .appendingPathComponent("ColdShotArchive", isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: true)
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

}
