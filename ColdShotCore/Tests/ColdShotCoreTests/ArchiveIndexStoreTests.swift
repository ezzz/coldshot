import Foundation
import Testing
@testable import ColdShotCore

@Suite("Archive index store")
struct ArchiveIndexStoreTests {
    @Test("A full scan and its PhotoKit checkpoint are committed together")
    func fullScanPersistsProfileAndAssets() async throws {
        let fixture = try Fixture()
        let store = ArchiveIndexStore(databaseURL: fixture.databaseURL)
        let synchronizedAt = Date(timeIntervalSince1970: 2_000)

        try await store.saveTargetCutoffDate(Date(timeIntervalSince1970: 1_000), profileIdentifier: "system")
        try await store.apply(
            ArchiveIndexSyncBatch(
                assets: [asset("a"), asset("b")],
                isFullScan: true,
                photoKitChangeToken: Data([1, 2, 3]),
                synchronizedAt: synchronizedAt
            ),
            profileIdentifier: "system"
        )

        let profile = try #require(await store.profile(identifier: "system"))
        #expect(profile.targetCutoffDate == Date(timeIntervalSince1970: 1_000))
        #expect(profile.photoKitChangeToken == Data([1, 2, 3]))
        #expect(profile.lastFullScanAt == synchronizedAt)
        #expect(profile.lastDeltaScanAt == synchronizedAt)
        #expect(try await store.assets().map(\.assetIdentifier) == ["a", "b"])
    }

    @Test("A changed archived asset is flagged until it is archived again")
    func deltaFlagsArchivedChanges() async throws {
        let fixture = try Fixture()
        let store = ArchiveIndexStore(databaseURL: fixture.databaseURL)
        try await store.apply(
            ArchiveIndexSyncBatch(
                assets: [asset("a", modification: 10), asset("b")],
                isFullScan: true,
                photoKitChangeToken: Data([1])
            ),
            profileIdentifier: "system"
        )
        try await store.markArchived(["a"])

        try await store.apply(
            ArchiveIndexSyncBatch(
                assets: [asset("a", modification: 20)],
                isFullScan: false,
                photoKitChangeToken: Data([2])
            ),
            profileIdentifier: "system"
        )

        let changed = try #require(await store.assets().first { $0.assetIdentifier == "a" })
        #expect(changed.isArchived)
        #expect(changed.needsReview)

        try await store.markArchived(["a"])
        let reviewed = try #require(await store.assets().first { $0.assetIdentifier == "a" })
        #expect(!reviewed.needsReview)
    }

    @Test("Full and delta deletions disappear from the active index")
    func deletionsAreExcluded() async throws {
        let fixture = try Fixture()
        let store = ArchiveIndexStore(databaseURL: fixture.databaseURL)
        try await store.apply(
            ArchiveIndexSyncBatch(
                assets: [asset("a"), asset("b")],
                isFullScan: true,
                photoKitChangeToken: Data([1])
            ),
            profileIdentifier: "system"
        )
        try await store.apply(
            ArchiveIndexSyncBatch(
                assets: [],
                deletedAssetIdentifiers: ["a"],
                isFullScan: false,
                photoKitChangeToken: Data([2])
            ),
            profileIdentifier: "system"
        )
        #expect(try await store.assets().map(\.assetIdentifier) == ["b"])

        try await store.apply(
            ArchiveIndexSyncBatch(
                assets: [asset("c")],
                isFullScan: true,
                photoKitChangeToken: Data([3])
            ),
            profileIdentifier: "system"
        )
        #expect(try await store.assets().map(\.assetIdentifier) == ["c"])
    }

    private func asset(_ identifier: String, modification: TimeInterval = 10) -> ArchiveIndexAsset {
        ArchiveIndexAsset(
            assetIdentifier: identifier,
            creationDate: Date(timeIntervalSince1970: modification),
            modificationDate: Date(timeIntervalSince1970: modification),
            mediaKind: "image",
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: 0,
            isLivePhoto: false,
            isFavorite: false,
            isHidden: false
        )
    }

    private struct Fixture {
        let root: URL
        var databaseURL: URL { root.appendingPathComponent("index.sqlite") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ColdShotIndexTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }
}
