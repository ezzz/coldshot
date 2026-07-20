import Foundation
import Testing
@testable import ColdShotCore

@Suite("Archive campaign engine")
struct ArchiveCampaignEngineTests {
    @Test("An interrupted multi-batch campaign resumes through every remaining batch")
    func resumesWholeCampaignAcrossTechnicalBatches() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let assets = ["one", "two", "three", "four", "five"].map {
            ArchiveCampaignAsset(
                assetIdentifier: $0,
                creationDate: Date(timeIntervalSince1970: 1_600_000_000)
            )
        }
        let firstProvider = CampaignPlanProviderRecorder()

        do {
            _ = try await ArchiveCampaignEngine().start(
                assets: assets,
                cutoffDate: nil,
                maximumBatchSize: 2,
                destination: destination,
                planProvider: { identifiers, _ in
                    firstProvider.record(identifiers)
                    return identifiers.map { plan(id: $0) }
                },
                sourceFactory: { asset in
                    if asset.assetIdentifier == "four" { return CampaignFailingSource() }
                    return CampaignMemorySource(data: Data(asset.assetIdentifier.utf8))
                }
            )
            Issue.record("The campaign should stop on the fourth asset")
        } catch CampaignTestError.expected {
            // Expected.
        }

        let engine = ArchiveCampaignEngine()
        let incomplete = try #require(
            try await engine.latestIncompleteCampaign(destination: destination)
        )
        #expect(incomplete.completedCount == 3)
        #expect(incomplete.assets.count == 5)
        #expect(incomplete.currentBatch != nil)
        #expect(firstProvider.calls == [["one", "two"], ["three", "four"]])

        let resumeProvider = CampaignPlanProviderRecorder()
        let sourceRecorder = CampaignSourceRecorder()
        let completed = try await engine.resume(
            campaignIdentifier: incomplete.identifier,
            destination: destination,
            planProvider: { identifiers, _ in
                resumeProvider.record(identifiers)
                return identifiers.map { plan(id: $0) }
            },
            planRefresher: { frozenPlan in
                plan(id: frozenPlan.assetIdentifier, modificationDate: Date(timeIntervalSince1970: 42))
            },
            sourceFactory: { asset in
                sourceRecorder.record(asset.assetIdentifier)
                if ["one", "two", "three"].contains(asset.assetIdentifier) {
                    return CampaignFailingSource()
                }
                return CampaignMemorySource(data: Data(asset.assetIdentifier.utf8))
            }
        )

        #expect(completed.isComplete)
        #expect(completed.completedCount == 5)
        #expect(completed.completedJobIdentifiers.count == 3)
        #expect(resumeProvider.calls == [["five"]])
        #expect(sourceRecorder.identifiers == ["four", "five"])
        #expect(try await engine.latestIncompleteCampaign(destination: destination) == nil)
        #expect(try await engine.latestCompletedCampaign(destination: destination)?.identifier == completed.identifier)
        let history = try await engine.campaignHistory(destination: destination)
        #expect(history.count == 1)
        #expect(history[0].id == completed.identifier)
        #expect(history[0].completedCount == 5)
        #expect(history[0].isComplete)
        #expect(history[0].earliestAssetDate == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(history[0].latestAssetDate == Date(timeIntervalSince1970: 1_600_000_000))
    }

    @Test("A campaign rejects a plan provider that drops an asset")
    func rejectsIncompletePlanInventory() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: ArchiveCampaignError.planInventoryMismatch) {
            try await ArchiveCampaignEngine().start(
                assets: [
                    ArchiveCampaignAsset(assetIdentifier: "one", creationDate: nil),
                    ArchiveCampaignAsset(assetIdentifier: "two", creationDate: nil)
                ],
                cutoffDate: nil,
                destination: destination,
                planProvider: { _, _ in [plan(id: "one")] },
                sourceFactory: { asset in
                    CampaignMemorySource(data: Data(asset.assetIdentifier.utf8))
                }
            )
        }
    }

    @Test("A campaign finishes with persistent issues and can retry only those assets")
    func retriesPersistentCampaignIssues() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let assets = ["one", "two", "three"].map {
            ArchiveCampaignAsset(assetIdentifier: $0, creationDate: nil)
        }
        let engine = ArchiveCampaignEngine()

        let withIssues = try await engine.start(
            assets: assets,
            cutoffDate: nil,
            destination: destination,
            planProvider: { identifiers, _ in identifiers.map { plan(id: $0) } },
            sourceFactory: { asset in
                if asset.assetIdentifier == "two" { return CampaignRecoverableFailingSource() }
                return CampaignMemorySource(data: Data(asset.assetIdentifier.utf8))
            }
        )

        #expect(withIssues.isFinished)
        #expect(!withIssues.isComplete)
        #expect(withIssues.completedCount == 2)
        #expect(withIssues.failedCount == 1)
        #expect(try await engine.latestIncompleteCampaign(destination: destination) == nil)
        #expect(try await engine.latestCampaignWithIssues(destination: destination)?.identifier == withIssues.identifier)
        #expect(try await engine.unresolvedFailureRecords(destination: destination).count == 1)

        let completed = try await engine.retryFailures(
            campaignIdentifier: withIssues.identifier,
            destination: destination,
            planProvider: { identifiers, _ in identifiers.map { plan(id: $0) } },
            sourceFactory: { asset in
                CampaignMemorySource(data: Data(asset.assetIdentifier.utf8))
            }
        )

        #expect(completed.isComplete)
        #expect(completed.completedCount == 3)
        #expect(completed.failedCount == 0)
        #expect(try await engine.unresolvedFailureRecords(destination: destination).isEmpty)
    }

    @Test("A cooperative pause preserves the campaign checkpoint")
    func cooperativePausePreservesCheckpoint() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let assets = ["one", "two", "three"].map {
            ArchiveCampaignAsset(assetIdentifier: $0, creationDate: nil)
        }

        await #expect(throws: CancellationError.self) {
            try await ArchiveCampaignEngine().start(
                assets: assets,
                cutoffDate: nil,
                maximumBatchSize: 2,
                destination: destination,
                planProvider: { identifiers, _ in identifiers.map { plan(id: $0) } },
                sourceFactory: { asset in
                    if asset.assetIdentifier == "two" { return CampaignCancellingSource() }
                    return CampaignMemorySource(data: Data(asset.assetIdentifier.utf8))
                }
            )
        }

        let engine = ArchiveCampaignEngine()
        let paused = try #require(
            try await engine.latestIncompleteCampaign(destination: destination)
        )
        #expect(paused.completedCount == 1)
        #expect(paused.currentBatch != nil)

        let completed = try await engine.resume(
            campaignIdentifier: paused.identifier,
            destination: destination,
            planProvider: { identifiers, _ in identifiers.map { plan(id: $0) } },
            sourceFactory: { asset in
                CampaignMemorySource(data: Data(asset.assetIdentifier.utf8))
            }
        )
        #expect(completed.isComplete)
        #expect(completed.completedCount == 3)
    }

    @Test("Corrupt campaign history is surfaced instead of silently ignored")
    func corruptHistoryFailsLoudly() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let directory = destination
            .appendingPathComponent("ColdShotArchive", isDirectory: true)
            .appendingPathComponent("campaigns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("corrupt.json")
        )

        await #expect(throws: DecodingError.self) {
            try await ArchiveCampaignEngine().campaignHistory(destination: destination)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdShotCampaignTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func plan(id: String, modificationDate: Date? = nil) -> ArchiveAssetPlan {
    ArchiveAssetPlan(
        assetIdentifier: id,
        creationDate: Date(timeIntervalSince1970: 1_600_000_000),
        modificationDate: modificationDate,
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

private struct CampaignMemorySource: ArchiveResourceSource {
    let data: Data

    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        try handler(data)
    }
}

private struct CampaignFailingSource: ArchiveResourceSource {
    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        throw CampaignTestError.expected
    }
}

private struct CampaignRecoverableFailingSource: ArchiveResourceSource {
    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        throw CampaignRecoverableTestError.expected
    }
}

private enum CampaignRecoverableTestError: Error, ArchiveFailureClassifying {
    case expected

    var archiveFailureDisposition: ArchiveFailureDisposition { .recoverableAsset }
    var archiveFailureCategory: ArchiveFailureCategory { .sourceChanged }
}

private struct CampaignCancellingSource: ArchiveResourceSource {
    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        throw CancellationError()
    }
}

private enum CampaignTestError: Error {
    case expected
}

private final class CampaignPlanProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [[String]] = []

    var calls: [[String]] {
        lock.withLock { storedCalls }
    }

    func record(_ identifiers: [String]) {
        lock.withLock { storedCalls.append(identifiers) }
    }
}

private final class CampaignSourceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentifiers: [String] = []

    var identifiers: [String] {
        lock.withLock { storedIdentifiers }
    }

    func record(_ identifier: String) {
        lock.withLock { storedIdentifiers.append(identifier) }
    }
}
