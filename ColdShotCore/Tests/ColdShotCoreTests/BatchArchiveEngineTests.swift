import Foundation
import Testing
@testable import ColdShotCore

@Suite("Batch archive engine")
struct BatchArchiveEngineTests {
    @Test("A 5,000-asset campaign is split into automatic checkpoints without a global limit")
    func plansCompleteCampaignWithoutDroppingAssets() {
        let exact = ArchiveCampaignPlanner.ranges(assetCount: 5_000)
        let remainder = ArchiveCampaignPlanner.ranges(assetCount: 5_123)

        #expect(exact.count == 10)
        #expect(exact.allSatisfy { $0.count == 500 })
        #expect(exact.flatMap(Array.init) == Array(0..<5_000))
        #expect(remainder.count == 11)
        #expect(remainder.last == 5_000..<5_123)
        #expect(remainder.flatMap(Array.init) == Array(0..<5_123))
    }

    @Test("A batch archives assets sequentially and persists completion")
    func archivesAndPersistsBatch() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plans = [plan(id: "one"), plan(id: "two")]
        let filter = InventorySelectionFilter(
            cutoffDate: Date(timeIntervalSince1970: 1_700_000_000),
            includeVideos: false
        )

        let journal = try await BatchArchiveEngine().start(
            assets: plans,
            cutoffDate: Date(timeIntervalSince1970: 1_700_000_000),
            selectionFilter: filter,
            destination: destination,
            sourceFactory: { asset in
                BatchMemorySource(data: Data(asset.assetIdentifier.utf8))
            }
        )

        #expect(journal.isComplete)
        #expect(journal.completedCount == 2)
        #expect(journal.archivedByteCount == 6)
        #expect(journal.selectionFilter == filter)
        #expect(journal.assets.allSatisfy { $0.manifestRelativePath?.hasSuffix(".json") == true })
        #expect(try await BatchArchiveEngine().latestIncompleteJob(destination: destination) == nil)
        #expect(try await BatchArchiveEngine().latestCompletedJob(destination: destination)?.identifier == journal.identifier)
    }

    @Test("A completed batch can be verified without reading PhotoKit again")
    func verifiesCompletedBatchFromDestination() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plans = [plan(id: "one"), plan(id: "two")]
        let engine = BatchArchiveEngine()
        let journal = try await engine.start(
            assets: plans,
            cutoffDate: Date(timeIntervalSince1970: 1_700_000_000),
            destination: destination,
            sourceFactory: { asset in
                BatchMemorySource(data: Data(asset.assetIdentifier.utf8))
            }
        )
        let events = BatchVerificationEventRecorder()

        let verified = try await engine.verify(
            jobIdentifier: journal.identifier,
            destination: destination,
            onEvent: { event in events.append(event) }
        )

        #expect(verified.identifier == journal.identifier)
        #expect(verified.assets == journal.assets)
        #expect(verified.isComplete)
        #expect(events.snapshot().filter { event in
            if case .assetVerified = event { return true }
            return false
        }.count == 2)
    }

    @Test("An isolated recoverable asset error is retried once and does not stop later assets")
    func toleratesIsolatedRecoverableFailure() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plans = [plan(id: "one"), plan(id: "two"), plan(id: "three")]

        let journal = try await BatchArchiveEngine().start(
            assets: plans,
            cutoffDate: nil,
            destination: destination,
            sourceFactory: { asset in
                if asset.assetIdentifier == "two" { return BatchRecoverableFailingSource() }
                return BatchMemorySource(data: Data(asset.assetIdentifier.utf8))
            }
        )

        #expect(journal.isFinished)
        #expect(!journal.isComplete)
        #expect(journal.completedCount == 2)
        #expect(journal.failedCount == 1)
        #expect(journal.assets[1].attemptCount == 2)
        #expect(journal.assets[1].failureCategory == .assetUnavailable)
        #expect(journal.assets[2].state == .archived)
    }

    @Test("The tenth unresolved recoverable asset pauses before the next asset")
    func stopsAtFailureTolerance() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plans = (1...11).map { plan(id: "asset-\($0)") }
        let engine = BatchArchiveEngine()

        await #expect(throws: BatchArchiveError.failureToleranceReached(10)) {
            try await engine.start(
                assets: plans,
                cutoffDate: nil,
                destination: destination,
                sourceFactory: { _ in BatchRecoverableFailingSource() }
            )
        }

        let paused = try #require(try await engine.latestIncompleteJob(destination: destination))
        #expect(paused.failedCount == 10)
        #expect(paused.processedCount == 10)
        #expect(paused.assets[10].state == .pending)
    }

    @Test("A failed batch resumes without reading an already verified asset")
    func resumesAfterFailure() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plans = [plan(id: "one"), plan(id: "two")]

        do {
            _ = try await BatchArchiveEngine().start(
                assets: plans,
                cutoffDate: Date(timeIntervalSince1970: 1_700_000_000),
                destination: destination,
                sourceFactory: { asset in
                    if asset.assetIdentifier == "two" { return BatchFailingSource() }
                    return BatchMemorySource(data: Data("one".utf8))
                }
            )
            Issue.record("The first run should fail")
        } catch BatchTestError.expected {
            // Expected.
        }

        let incomplete = try #require(
            try await BatchArchiveEngine().latestIncompleteJob(destination: destination)
        )
        #expect(incomplete.completedCount == 1)
        #expect(incomplete.failedCount == 0)

        let resumed = try await BatchArchiveEngine().resume(
            jobIdentifier: incomplete.identifier,
            destination: destination,
            sourceFactory: { asset in
                if asset.assetIdentifier == "one" { return BatchFailingSource() }
                return BatchMemorySource(data: Data("two".utf8))
            }
        )

        #expect(resumed.isComplete)
        #expect(resumed.completedCount == 2)
    }

    @Test("Resume rejects corruption in an asset already marked archived")
    func resumeRevalidatesCompletedAssets() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plans = [plan(id: "one"), plan(id: "two")]

        do {
            _ = try await BatchArchiveEngine().start(
                assets: plans,
                cutoffDate: Date(timeIntervalSince1970: 1_700_000_000),
                destination: destination,
                sourceFactory: { asset in
                    if asset.assetIdentifier == "two" { return BatchFailingSource() }
                    return BatchMemorySource(data: Data("one".utf8))
                }
            )
            Issue.record("The first run should fail")
        } catch BatchTestError.expected {
            // Expected.
        }

        let incomplete = try #require(
            try await BatchArchiveEngine().latestIncompleteJob(destination: destination)
        )
        let manifestPath = try #require(incomplete.assets[0].manifestRelativePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let manifest = try decoder.decode(
            ArchiveManifest.self,
            from: Data(contentsOf: destination.appendingPathComponent(manifestPath))
        )
        let resourcePath = try #require(manifest.resources.first?.relativePath)
        try Data("corrupt".utf8).write(to: destination.appendingPathComponent(resourcePath))

        await #expect(throws: ArchiveError.self) {
            try await BatchArchiveEngine().resume(
                jobIdentifier: incomplete.identifier,
                destination: destination,
                sourceFactory: { _ in BatchMemorySource(data: Data("two".utf8)) }
            )
        }
    }

    @Test("Resume refreshes only unfinished PhotoKit plans")
    func resumeRefreshesOnlyPendingPlans() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plans = [plan(id: "one"), plan(id: "two")]

        do {
            _ = try await BatchArchiveEngine().start(
                assets: plans,
                cutoffDate: nil,
                destination: destination,
                sourceFactory: { asset in
                    if asset.assetIdentifier == "two" { return BatchFailingSource() }
                    return BatchMemorySource(data: Data("one".utf8))
                }
            )
            Issue.record("The first run should fail")
        } catch BatchTestError.expected {
            // Expected.
        }

        let incomplete = try #require(
            try await BatchArchiveEngine().latestIncompleteJob(destination: destination)
        )
        let recorder = BatchPlanRecorder()
        let refreshedDate = Date(timeIntervalSince1970: 1_800_000_000)

        let resumed = try await BatchArchiveEngine().resume(
            jobIdentifier: incomplete.identifier,
            destination: destination,
            planRefresher: { plan in
                recorder.recordRefreshed(plan.assetIdentifier)
                return ArchiveAssetPlan(
                    assetIdentifier: plan.assetIdentifier,
                    creationDate: plan.creationDate,
                    modificationDate: refreshedDate,
                    mediaKind: plan.mediaKind,
                    resources: plan.resources
                )
            },
            sourceFactory: { plan in
                recorder.recordSource(plan.assetIdentifier, modificationDate: plan.modificationDate)
                return BatchMemorySource(data: Data(plan.assetIdentifier.utf8))
            }
        )

        #expect(resumed.isComplete)
        #expect(recorder.refreshedIdentifiers == ["two"])
        #expect(recorder.sourcePlans == ["two": refreshedDate])
    }

    @Test("A V0.5 journal without a layout field decodes as legacy")
    func legacyJournalDecodingDefaultsToLegacyLayout() throws {
        let journal = BatchArchiveJournal(
            cutoffDate: Date(timeIntervalSince1970: 1_700_000_000),
            assets: [BatchAssetRecord(asset: plan(id: "legacy"))]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(journal)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "archiveLayoutVersion")
        if var assets = object["assets"] as? [[String: Any]], !assets.isEmpty {
            assets[0].removeValue(forKey: "diagnosticError")
            assets[0].removeValue(forKey: "failureCategory")
            assets[0].removeValue(forKey: "attemptCount")
            object["assets"] = assets
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded = try decoder.decode(BatchArchiveJournal.self, from: legacyData)

        #expect(decoded.archiveLayoutVersion == nil)
    }

    @Test("Resuming a V0.5 journal keeps writing the legacy per-asset layout")
    func resumesLegacyJournalWithLegacyWriter() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plans = [plan(id: "one"), plan(id: "two")]

        do {
            _ = try await BatchArchiveEngine().start(
                assets: plans,
                cutoffDate: Date(timeIntervalSince1970: 1_700_000_000),
                archiveLayoutVersion: .legacyPerAsset,
                destination: destination,
                sourceFactory: { asset in
                    if asset.assetIdentifier == "two" { return BatchFailingSource() }
                    return BatchMemorySource(data: Data("one".utf8))
                }
            )
            Issue.record("The legacy fixture batch should fail on its second asset")
        } catch BatchTestError.expected {
            // Expected.
        }

        let incomplete = try #require(
            try await BatchArchiveEngine().latestIncompleteJob(destination: destination)
        )
        let journalURL = destination
            .appendingPathComponent("ColdShotArchive/jobs")
            .appendingPathComponent("\(incomplete.identifier.uuidString).json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        object.removeValue(forKey: "archiveLayoutVersion")
        try JSONSerialization.data(withJSONObject: object).write(to: journalURL)

        let resumed = try await BatchArchiveEngine().resume(
            jobIdentifier: incomplete.identifier,
            destination: destination,
            sourceFactory: { asset in
                if asset.assetIdentifier == "one" { return BatchFailingSource() }
                return BatchMemorySource(data: Data("two".utf8))
            }
        )

        #expect(resumed.isComplete)
        #expect(resumed.archiveLayoutVersion == nil)
        #expect(resumed.assets.allSatisfy { $0.manifestRelativePath?.hasSuffix("/manifest.json") == true })
    }

    private func plan(id: String) -> ArchiveAssetPlan {
        ArchiveAssetPlan(
            assetIdentifier: id,
            creationDate: Date(timeIntervalSince1970: 1_600_000_000),
            modificationDate: nil,
            mediaKind: "image",
            resources: [
                ArchiveResourcePlan(
                    resourceIdentifier: "\(id)-resource",
                    originalFilename: "\(id).jpg",
                    resourceType: "photo",
                    uniformTypeIdentifier: "public.jpeg"
                )
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdShotBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct BatchMemorySource: ArchiveResourceSource {
    let data: Data

    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        try handler(data)
    }
}

private struct BatchFailingSource: ArchiveResourceSource {
    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        throw BatchTestError.expected
    }
}

private struct BatchRecoverableFailingSource: ArchiveResourceSource {
    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        throw BatchRecoverableTestError.expected
    }
}

private enum BatchRecoverableTestError: Error, ArchiveFailureClassifying {
    case expected

    var archiveFailureDisposition: ArchiveFailureDisposition { .recoverableAsset }
    var archiveFailureCategory: ArchiveFailureCategory { .assetUnavailable }
}

private enum BatchTestError: Error {
    case expected
}

private final class BatchVerificationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BatchVerificationEvent] = []

    func append(_ event: BatchVerificationEvent) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [BatchVerificationEvent] {
        lock.withLock { events }
    }
}

private final class BatchPlanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var refreshed: [String] = []
    private var sources: [String: Date?] = [:]

    var refreshedIdentifiers: [String] {
        lock.withLock { refreshed }
    }

    var sourcePlans: [String: Date?] {
        lock.withLock { sources }
    }

    func recordRefreshed(_ identifier: String) {
        lock.withLock { refreshed.append(identifier) }
    }

    func recordSource(_ identifier: String, modificationDate: Date?) {
        lock.withLock { sources[identifier] = modificationDate }
    }
}
