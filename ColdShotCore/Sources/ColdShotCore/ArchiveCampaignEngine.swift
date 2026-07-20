import Foundation

public enum ArchiveCampaignAssetState: String, Codable, Equatable, Sendable {
    case pending
    case archived
    case failed
}

public struct ArchiveCampaignAsset: Codable, Equatable, Sendable {
    public let assetIdentifier: String
    public let creationDate: Date?

    public init(assetIdentifier: String, creationDate: Date?) {
        self.assetIdentifier = assetIdentifier
        self.creationDate = creationDate
    }
}

public struct ArchiveCampaignAssetRecord: Codable, Equatable, Sendable {
    public let asset: ArchiveCampaignAsset
    public var state: ArchiveCampaignAssetState
    public var archivedByteCount: Int64
    public var lastError: String?
    public var diagnosticError: String?
    public var failureCategory: ArchiveFailureCategory?
    public var attemptCount: Int?

    public init(
        asset: ArchiveCampaignAsset,
        state: ArchiveCampaignAssetState = .pending,
        archivedByteCount: Int64 = 0,
        lastError: String? = nil,
        diagnosticError: String? = nil,
        failureCategory: ArchiveFailureCategory? = nil,
        attemptCount: Int? = 0
    ) {
        self.asset = asset
        self.state = state
        self.archivedByteCount = archivedByteCount
        self.lastError = lastError
        self.diagnosticError = diagnosticError
        self.failureCategory = failureCategory
        self.attemptCount = attemptCount
    }
}

public struct ArchiveCampaignBatchCheckpoint: Codable, Equatable, Sendable {
    public let jobIdentifier: UUID
    public let assetIndices: [Int]

    public init(jobIdentifier: UUID, assetIndices: [Int]) {
        self.jobIdentifier = jobIdentifier
        self.assetIndices = assetIndices
    }
}

public struct ArchiveCampaignJournal: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let identifier: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public let cutoffDate: Date?
    public let archiveLayoutVersion: ArchiveLayoutVersion
    public let selectionFilter: InventorySelectionFilter?
    public let maximumBatchSize: Int
    public let failureLimit: Int?
    public var assets: [ArchiveCampaignAssetRecord]
    public var currentBatch: ArchiveCampaignBatchCheckpoint?
    public var completedJobIdentifiers: [UUID]

    public init(
        schemaVersion: Int = 1,
        identifier: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        cutoffDate: Date?,
        archiveLayoutVersion: ArchiveLayoutVersion = .yearMonth,
        selectionFilter: InventorySelectionFilter? = nil,
        maximumBatchSize: Int = 500,
        failureLimit: Int = 10,
        assets: [ArchiveCampaignAssetRecord],
        currentBatch: ArchiveCampaignBatchCheckpoint? = nil,
        completedJobIdentifiers: [UUID] = []
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cutoffDate = cutoffDate
        self.archiveLayoutVersion = archiveLayoutVersion
        self.selectionFilter = selectionFilter
        self.maximumBatchSize = maximumBatchSize
        self.failureLimit = failureLimit
        self.assets = assets
        self.currentBatch = currentBatch
        self.completedJobIdentifiers = completedJobIdentifiers
    }

    public var completedCount: Int { assets.count { $0.state == .archived } }
    public var failedCount: Int { assets.count { $0.state == .failed } }
    public var processedCount: Int { completedCount + failedCount }
    public var archivedByteCount: Int64 { assets.reduce(0) { $0 + $1.archivedByteCount } }
    public var resolvedFailureLimit: Int { failureLimit ?? 10 }
    public var isFinished: Bool {
        !assets.isEmpty && currentBatch == nil && processedCount == assets.count
    }
    public var isComplete: Bool {
        !assets.isEmpty && currentBatch == nil && completedCount == assets.count
    }
}

public struct ArchiveCampaignSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let assetCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let archivedByteCount: Int64
    public let isComplete: Bool
    public let isFinished: Bool
    public let earliestAssetDate: Date?
    public let latestAssetDate: Date?

    public init(journal: ArchiveCampaignJournal) {
        id = journal.identifier
        createdAt = journal.createdAt
        updatedAt = journal.updatedAt
        assetCount = journal.assets.count
        completedCount = journal.completedCount
        failedCount = journal.failedCount
        archivedByteCount = journal.archivedByteCount
        isComplete = journal.isComplete
        isFinished = journal.isFinished
        let dates = journal.assets.compactMap(\.asset.creationDate)
        earliestAssetDate = dates.min()
        latestAssetDate = dates.max()
    }
}

public enum ArchiveCampaignEvent: Equatable, Sendable {
    case started(campaignIdentifier: UUID, assetCount: Int, completedCount: Int)
    case assetStarted(index: Int, total: Int, assetIdentifier: String, creationDate: Date?)
    case assetRetrying(index: Int, total: Int, assetIdentifier: String, attempt: Int, message: String)
    case archiveEvent(assetIdentifier: String, event: ArchiveEvent)
    case assetCompleted(index: Int, total: Int, assetIdentifier: String, byteCount: Int64)
    case assetFailed(index: Int, total: Int, assetIdentifier: String, message: String)
    case checkpoint(completedCount: Int, total: Int)
    case completed(campaignIdentifier: UUID, byteCount: Int64)
    case completedWithIssues(campaignIdentifier: UUID, byteCount: Int64, failedCount: Int)
}

public enum ArchiveCampaignError: Error, Equatable, LocalizedError, Sendable {
    case emptyCampaign
    case invalidMaximumBatchSize(Int)
    case duplicateAssetIdentifier(String)
    case journalNotFound(UUID)
    case unsupportedJournalVersion(Int)
    case invalidCheckpointIndex(Int)
    case planInventoryMismatch

    public var errorDescription: String? {
        switch self {
        case .emptyCampaign:
            "The archive campaign contains no assets."
        case .invalidMaximumBatchSize(let size):
            "The archive campaign batch size is invalid: \(size)."
        case .duplicateAssetIdentifier(let identifier):
            "The archive campaign contains the Photos asset more than once: \(identifier)."
        case .journalNotFound(let identifier):
            "The archive campaign journal was not found: \(identifier.uuidString)"
        case .unsupportedJournalVersion(let version):
            "The archive campaign journal version is unsupported: \(version)"
        case .invalidCheckpointIndex(let index):
            "The archive campaign checkpoint contains an invalid asset index: \(index)."
        case .planInventoryMismatch:
            "The refreshed Photos plans do not match the campaign checkpoint."
        }
    }
}

public actor ArchiveCampaignEngine {
    public typealias PlanProvider = @Sendable (
        _ assetIdentifiers: [String],
        _ selectionFilter: InventorySelectionFilter?
    ) async throws -> [ArchiveAssetPlan]
    public typealias EventHandler = @Sendable (ArchiveCampaignEvent) -> Void

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
        assets: [ArchiveCampaignAsset],
        cutoffDate: Date?,
        archiveLayoutVersion: ArchiveLayoutVersion = .yearMonth,
        selectionFilter: InventorySelectionFilter? = nil,
        maximumBatchSize: Int = 500,
        failureLimit: Int = 10,
        destination: URL,
        planProvider: @escaping PlanProvider,
        planRefresher: @escaping BatchArchiveEngine.PlanRefresher = { $0 },
        sourceFactory: @escaping BatchArchiveEngine.SourceFactory,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> ArchiveCampaignJournal {
        guard !assets.isEmpty else { throw ArchiveCampaignError.emptyCampaign }
        guard maximumBatchSize > 0 else {
            throw ArchiveCampaignError.invalidMaximumBatchSize(maximumBatchSize)
        }
        try Self.validateUniqueAssets(assets)

        var journal = ArchiveCampaignJournal(
            createdAt: now(),
            updatedAt: now(),
            cutoffDate: cutoffDate,
            archiveLayoutVersion: archiveLayoutVersion,
            selectionFilter: selectionFilter,
            maximumBatchSize: maximumBatchSize,
            failureLimit: failureLimit,
            assets: assets.map { ArchiveCampaignAssetRecord(asset: $0) }
        )
        try save(journal, destination: destination)
        return try await run(
            journal: &journal,
            destination: destination,
            planProvider: planProvider,
            planRefresher: planRefresher,
            sourceFactory: sourceFactory,
            retryFailedAssets: false,
            onEvent: onEvent
        )
    }

    public func resume(
        campaignIdentifier: UUID,
        destination: URL,
        planProvider: @escaping PlanProvider,
        planRefresher: @escaping BatchArchiveEngine.PlanRefresher = { $0 },
        sourceFactory: @escaping BatchArchiveEngine.SourceFactory,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> ArchiveCampaignJournal {
        var journal = try load(campaignIdentifier: campaignIdentifier, destination: destination)
        guard journal.schemaVersion == 1 else {
            throw ArchiveCampaignError.unsupportedJournalVersion(journal.schemaVersion)
        }
        guard journal.maximumBatchSize > 0 else {
            throw ArchiveCampaignError.invalidMaximumBatchSize(journal.maximumBatchSize)
        }
        try Self.validateUniqueAssets(journal.assets.map(\.asset))
        try await reconcileCurrentBatch(journal: &journal, destination: destination)
        try save(journal, destination: destination)
        return try await run(
            journal: &journal,
            destination: destination,
            planProvider: planProvider,
            planRefresher: planRefresher,
            sourceFactory: sourceFactory,
            retryFailedAssets: false,
            onEvent: onEvent
        )
    }

    public func retryFailures(
        campaignIdentifier: UUID,
        destination: URL,
        planProvider: @escaping PlanProvider,
        planRefresher: @escaping BatchArchiveEngine.PlanRefresher = { $0 },
        sourceFactory: @escaping BatchArchiveEngine.SourceFactory,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> ArchiveCampaignJournal {
        var journal = try load(campaignIdentifier: campaignIdentifier, destination: destination)
        guard journal.schemaVersion == 1 else {
            throw ArchiveCampaignError.unsupportedJournalVersion(journal.schemaVersion)
        }
        for index in journal.assets.indices where journal.assets[index].state == .failed {
            journal.assets[index].state = .pending
        }
        journal.updatedAt = now()
        try save(journal, destination: destination)
        return try await run(
            journal: &journal,
            destination: destination,
            planProvider: planProvider,
            planRefresher: planRefresher,
            sourceFactory: sourceFactory,
            retryFailedAssets: true,
            onEvent: onEvent
        )
    }

    public func latestIncompleteCampaign(destination: URL) throws -> ArchiveCampaignJournal? {
        try campaigns(destination: destination)
            .filter { !$0.isFinished }
            .max { $0.updatedAt < $1.updatedAt }
    }

    public func latestCompletedCampaign(destination: URL) throws -> ArchiveCampaignJournal? {
        try campaigns(destination: destination)
            .filter(\.isComplete)
            .max { $0.updatedAt < $1.updatedAt }
    }

    public func latestCampaignWithIssues(destination: URL) throws -> ArchiveCampaignJournal? {
        try campaigns(destination: destination)
            .filter { $0.isFinished && $0.failedCount > 0 }
            .max { $0.updatedAt < $1.updatedAt }
    }

    public func unresolvedFailureRecords(
        destination: URL
    ) throws -> [ArchiveCampaignAssetRecord] {
        let ordered = try campaigns(destination: destination).sorted { $0.updatedAt < $1.updatedAt }
        var latestByIdentifier: [String: ArchiveCampaignAssetRecord] = [:]
        for campaign in ordered {
            for record in campaign.assets {
                latestByIdentifier[record.asset.assetIdentifier] = record
            }
        }
        return latestByIdentifier.values
            .filter { $0.state == .failed }
            .sorted {
                ($0.asset.creationDate ?? .distantPast) < ($1.asset.creationDate ?? .distantPast)
            }
    }

    public func campaignHistory(
        destination: URL,
        limit: Int = 10
    ) throws -> [ArchiveCampaignSummary] {
        guard limit > 0 else { return [] }
        return try campaigns(destination: destination)
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map(ArchiveCampaignSummary.init)
    }

    private func run(
        journal: inout ArchiveCampaignJournal,
        destination: URL,
        planProvider: @escaping PlanProvider,
        planRefresher: @escaping BatchArchiveEngine.PlanRefresher,
        sourceFactory: @escaping BatchArchiveEngine.SourceFactory,
        retryFailedAssets: Bool,
        onEvent: @escaping EventHandler
    ) async throws -> ArchiveCampaignJournal {
        onEvent(.started(
            campaignIdentifier: journal.identifier,
            assetCount: journal.assets.count,
            completedCount: journal.processedCount
        ))

        while !journal.isFinished {
            try Task.checkCancellation()
            if journal.currentBatch == nil {
                let pendingIndices = journal.assets.indices
                    .filter { journal.assets[$0].state == .pending }
                guard !pendingIndices.isEmpty else { break }
                journal.currentBatch = ArchiveCampaignBatchCheckpoint(
                    jobIdentifier: UUID(),
                    assetIndices: Array(pendingIndices.prefix(journal.maximumBatchSize))
                )
                journal.updatedAt = now()
                try save(journal, destination: destination)
            }

            guard let checkpoint = journal.currentBatch else { continue }
            let eventContext = try Self.eventContext(for: checkpoint, in: journal)
            let batchEngine = BatchArchiveEngine(now: now)

            do {
                let batchJournal: BatchArchiveJournal
                if let existingBatch = try await batchEngine.job(
                    jobIdentifier: checkpoint.jobIdentifier,
                    destination: destination
                ) {
                    batchJournal = try await batchEngine.resume(
                        jobIdentifier: checkpoint.jobIdentifier,
                        destination: destination,
                        planRefresher: planRefresher,
                        sourceFactory: sourceFactory,
                        retryFailedAssets: retryFailedAssets,
                        failureLimit: journal.resolvedFailureLimit,
                        initialFailureCount: max(journal.failedCount - existingBatch.failedCount, 0),
                        onEvent: { event in
                            Self.forward(event, context: eventContext, to: onEvent)
                        }
                    )
                } else {
                    let identifiers = checkpoint.assetIndices.map {
                        journal.assets[$0].asset.assetIdentifier
                    }
                    let plans = try await planProvider(identifiers, journal.selectionFilter)
                    let orderedPlans = try Self.orderedPlans(plans, identifiers: identifiers)
                    try Task.checkCancellation()
                    batchJournal = try await batchEngine.start(
                        assets: orderedPlans,
                        jobIdentifier: checkpoint.jobIdentifier,
                        cutoffDate: journal.cutoffDate,
                        archiveLayoutVersion: journal.archiveLayoutVersion,
                        selectionFilter: journal.selectionFilter,
                        destination: destination,
                        planRefresher: planRefresher,
                        sourceFactory: sourceFactory,
                        failureLimit: journal.resolvedFailureLimit,
                        initialFailureCount: journal.failedCount,
                        onEvent: { event in
                            Self.forward(event, context: eventContext, to: onEvent)
                        }
                    )
                }

                try Self.reconcile(batchJournal, checkpoint: checkpoint, journal: &journal)
                guard batchJournal.isFinished else { continue }
                if !journal.completedJobIdentifiers.contains(checkpoint.jobIdentifier) {
                    journal.completedJobIdentifiers.append(checkpoint.jobIdentifier)
                }
                journal.currentBatch = nil
                journal.updatedAt = now()
                try save(journal, destination: destination)
                onEvent(.checkpoint(
                    completedCount: journal.processedCount,
                    total: journal.assets.count
                ))
            } catch {
                if let batchJournal = try? await batchEngine.job(
                    jobIdentifier: checkpoint.jobIdentifier,
                    destination: destination
                ) {
                    try? Self.reconcile(batchJournal, checkpoint: checkpoint, journal: &journal)
                }
                journal.updatedAt = now()
                try? save(journal, destination: destination)
                throw error
            }
        }

        guard journal.processedCount == journal.assets.count else {
            throw ArchiveCampaignError.planInventoryMismatch
        }
        journal.currentBatch = nil
        journal.updatedAt = now()
        try save(journal, destination: destination)
        if journal.failedCount > 0 {
            onEvent(.completedWithIssues(
                campaignIdentifier: journal.identifier,
                byteCount: journal.archivedByteCount,
                failedCount: journal.failedCount
            ))
        } else {
            onEvent(.completed(
                campaignIdentifier: journal.identifier,
                byteCount: journal.archivedByteCount
            ))
        }
        return journal
    }

    private func reconcileCurrentBatch(
        journal: inout ArchiveCampaignJournal,
        destination: URL
    ) async throws {
        guard let checkpoint = journal.currentBatch else { return }
        let batchEngine = BatchArchiveEngine(now: now)
        guard let batchJournal = try await batchEngine.job(
            jobIdentifier: checkpoint.jobIdentifier,
            destination: destination
        ) else { return }
        try Self.reconcile(batchJournal, checkpoint: checkpoint, journal: &journal)
        if batchJournal.isFinished {
            if !journal.completedJobIdentifiers.contains(checkpoint.jobIdentifier) {
                journal.completedJobIdentifiers.append(checkpoint.jobIdentifier)
            }
            journal.currentBatch = nil
        }
        journal.updatedAt = now()
    }

    private static func reconcile(
        _ batchJournal: BatchArchiveJournal,
        checkpoint: ArchiveCampaignBatchCheckpoint,
        journal: inout ArchiveCampaignJournal
    ) throws {
        let expectedIdentifiers = try checkpoint.assetIndices.map { index in
            guard journal.assets.indices.contains(index) else {
                throw ArchiveCampaignError.invalidCheckpointIndex(index)
            }
            return journal.assets[index].asset.assetIdentifier
        }
        guard batchJournal.assets.map(\.asset.assetIdentifier) == expectedIdentifiers else {
            throw ArchiveCampaignError.planInventoryMismatch
        }

        for (batchRecord, campaignIndex) in zip(batchJournal.assets, checkpoint.assetIndices) {
            switch batchRecord.state {
            case .archived:
                journal.assets[campaignIndex].state = .archived
                journal.assets[campaignIndex].archivedByteCount = batchRecord.archivedByteCount
                journal.assets[campaignIndex].lastError = nil
                journal.assets[campaignIndex].diagnosticError = nil
                journal.assets[campaignIndex].failureCategory = nil
                journal.assets[campaignIndex].attemptCount = batchRecord.attemptCount
            case .failed:
                journal.assets[campaignIndex].state = .failed
                journal.assets[campaignIndex].lastError = batchRecord.lastError
                journal.assets[campaignIndex].diagnosticError = batchRecord.diagnosticError
                journal.assets[campaignIndex].failureCategory = batchRecord.failureCategory
                journal.assets[campaignIndex].attemptCount = batchRecord.attemptCount
            case .pending, .archiving:
                journal.assets[campaignIndex].state = .pending
                journal.assets[campaignIndex].lastError = nil
            }
        }
    }

    private struct EventContext: Sendable {
        let total: Int
        let positions: [String: (index: Int, creationDate: Date?)]
    }

    private static func eventContext(
        for checkpoint: ArchiveCampaignBatchCheckpoint,
        in journal: ArchiveCampaignJournal
    ) throws -> EventContext {
        var positions: [String: (index: Int, creationDate: Date?)] = [:]
        for index in checkpoint.assetIndices {
            guard journal.assets.indices.contains(index) else {
                throw ArchiveCampaignError.invalidCheckpointIndex(index)
            }
            let asset = journal.assets[index].asset
            positions[asset.assetIdentifier] = (index + 1, asset.creationDate)
        }
        return EventContext(total: journal.assets.count, positions: positions)
    }

    private static func forward(
        _ event: BatchArchiveEvent,
        context: EventContext,
        to handler: EventHandler
    ) {
        switch event {
        case .started, .completed, .completedWithIssues:
            break
        case .assetStarted(_, _, let identifier):
            guard let position = context.positions[identifier] else { return }
            handler(.assetStarted(
                index: position.index,
                total: context.total,
                assetIdentifier: identifier,
                creationDate: position.creationDate
            ))
        case .assetRetrying(_, _, let identifier, let attempt, let message):
            guard let position = context.positions[identifier] else { return }
            handler(.assetRetrying(
                index: position.index,
                total: context.total,
                assetIdentifier: identifier,
                attempt: attempt,
                message: message
            ))
        case .archiveEvent(let identifier, let archiveEvent):
            handler(.archiveEvent(assetIdentifier: identifier, event: archiveEvent))
        case .assetCompleted(_, _, let identifier, let byteCount):
            guard let position = context.positions[identifier] else { return }
            handler(.assetCompleted(
                index: position.index,
                total: context.total,
                assetIdentifier: identifier,
                byteCount: byteCount
            ))
        case .assetFailed(_, _, let identifier, let message):
            guard let position = context.positions[identifier] else { return }
            handler(.assetFailed(
                index: position.index,
                total: context.total,
                assetIdentifier: identifier,
                message: message
            ))
        }
    }

    private static func orderedPlans(
        _ plans: [ArchiveAssetPlan],
        identifiers: [String]
    ) throws -> [ArchiveAssetPlan] {
        let grouped = Dictionary(grouping: plans, by: \.assetIdentifier)
        guard plans.count == identifiers.count,
              grouped.count == identifiers.count,
              Set(grouped.keys) == Set(identifiers) else {
            throw ArchiveCampaignError.planInventoryMismatch
        }
        return try identifiers.map { identifier in
            guard let plan = grouped[identifier]?.first else {
                throw ArchiveCampaignError.planInventoryMismatch
            }
            return plan
        }
    }

    private static func validateUniqueAssets(_ assets: [ArchiveCampaignAsset]) throws {
        var identifiers: Set<String> = []
        for asset in assets where !identifiers.insert(asset.assetIdentifier).inserted {
            throw ArchiveCampaignError.duplicateAssetIdentifier(asset.assetIdentifier)
        }
    }

    private func campaigns(destination: URL) throws -> [ArchiveCampaignJournal] {
        let directory = try campaignsDirectory(destination: destination, create: false)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { try decodeJournal(at: $0) }
    }

    private func save(_ journal: ArchiveCampaignJournal, destination: URL) throws {
        let directory = try campaignsDirectory(destination: destination, create: true)
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

    private func load(campaignIdentifier: UUID, destination: URL) throws -> ArchiveCampaignJournal {
        let directory = try campaignsDirectory(destination: destination, create: false)
        let url = directory.appendingPathComponent("\(campaignIdentifier.uuidString).json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ArchiveCampaignError.journalNotFound(campaignIdentifier)
        }
        return try decodeJournal(at: url)
    }

    private func decodeJournal(at url: URL) throws -> ArchiveCampaignJournal {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ArchiveCampaignJournal.self, from: Data(contentsOf: url))
    }

    private func campaignsDirectory(destination: URL, create: Bool) throws -> URL {
        let directory = destination
            .appendingPathComponent("ColdShotArchive", isDirectory: true)
            .appendingPathComponent("campaigns", isDirectory: true)
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
