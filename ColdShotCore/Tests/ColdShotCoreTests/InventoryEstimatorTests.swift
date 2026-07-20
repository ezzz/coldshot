import Foundation
import Testing
@testable import ColdShotCore

@Suite("Inventory estimator")
struct InventoryEstimatorTests {
    @Test("Assets are grouped by year and media kind")
    func groupsAssetsByYear() throws {
        let assets = [
            snapshot(year: 2022, mediaKind: "image", live: true),
            snapshot(year: 2022, mediaKind: "image"),
            snapshot(year: 2022, mediaKind: "video", duration: 60),
            snapshot(year: 2023, mediaKind: "video", duration: 120),
            InventoryAssetSnapshot(
                creationDate: nil,
                mediaKind: "image",
                pixelWidth: 1,
                pixelHeight: 1,
                duration: 0,
                isLivePhoto: false
            )
        ]

        let report = InventoryEstimator().buildReport(from: assets)

        #expect(report.totalAssetCount == 5)
        #expect(report.undatedAssetCount == 1)
        let year2022 = try #require(report.years.first { $0.year == 2022 })
        #expect(year2022.photoCount == 2)
        #expect(year2022.videoCount == 1)
        #expect(year2022.livePhotoCount == 1)
        #expect(year2022.videoDuration == 60)
        #expect(year2022.estimatedVolume.lowerBoundBytes > 0)
        #expect(year2022.estimatedVolume.upperBoundBytes > year2022.estimatedVolume.lowerBoundBytes)
        #expect(year2022.months.count == 1)
        #expect(year2022.months[0].key == InventoryMonthKey(year: 2022, month: 1))
    }

    @Test("Assets are grouped by month and a monthly cutoff is exact")
    func groupsAssetsByMonthAndUsesExactCutoff() throws {
        let assets = [
            snapshot(year: 2023, month: 1, mediaKind: "image"),
            snapshot(year: 2023, month: 2, mediaKind: "image"),
            snapshot(year: 2023, month: 3, mediaKind: "video", duration: 30)
        ]
        let report = InventoryEstimator().buildReport(from: assets)
        let year = try #require(report.years.first)
        #expect(year.months.map(\.key.month) == [1, 2, 3])

        let cutoff = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2023, month: 3, day: 1)
        )!
        let selection = InventoryEstimator().selection(
            from: assets,
            matching: InventorySelectionFilter(
                cutoffDate: cutoff,
                includeFavorites: true,
                includeHidden: true
            )
        )
        #expect(selection.assetCount == 2)
        #expect(selection.videoCount == 0)
    }

    @Test("Cutoff selection is cumulative and excludes the cutoff year")
    func cutoffSelectionIsCumulative() {
        let report = InventoryEstimator().buildReport(from: [
            snapshot(year: 2021, mediaKind: "image"),
            snapshot(year: 2022, mediaKind: "image"),
            snapshot(year: 2023, mediaKind: "video", duration: 30)
        ])

        let cutoff = makeDate(year: 2023)
        let selection = report.selection(before: cutoff)

        #expect(selection.assetCount == 2)
        #expect(selection.photoCount == 2)
        #expect(selection.videoCount == 0)
    }

    @Test("Video estimates scale with duration")
    func videoEstimateScalesWithDuration() {
        let estimator = InventoryEstimator()
        let short = estimator.estimate(for: snapshot(year: 2024, mediaKind: "video", duration: 10))
        let long = estimator.estimate(for: snapshot(year: 2024, mediaKind: "video", duration: 100))

        #expect(long.lowerBoundBytes == short.lowerBoundBytes * 10)
        #expect(long.upperBoundBytes == short.upperBoundBytes * 10)
    }

    @Test("MVP 1 filters media, favorites, hidden assets, and cutoff entirely in memory")
    func filteredSelectionUsesLightweightSnapshots() {
        let assets = [
            snapshot(year: 2021, mediaKind: "image"),
            snapshot(year: 2021, mediaKind: "image", live: true),
            snapshot(year: 2021, mediaKind: "video", duration: 30),
            snapshot(year: 2021, mediaKind: "image", favorite: true),
            snapshot(year: 2021, mediaKind: "video", duration: 30, hidden: true),
            snapshot(year: 2024, mediaKind: "image")
        ]
        let filter = InventorySelectionFilter(
            cutoffDate: makeDate(year: 2023),
            includeStandardPhotos: false,
            includeLivePhotos: true,
            includeVideos: true,
            includeFavorites: false,
            includeHidden: false
        )

        let selection = InventoryEstimator().selection(from: assets, matching: filter)

        #expect(selection.assetCount == 2)
        #expect(selection.photoCount == 1)
        #expect(selection.livePhotoCount == 1)
        #expect(selection.videoCount == 1)
        #expect(selection.estimatedVolume.upperBoundBytes > 0)
    }

    @Test("Disabling the cutoff includes assets without dates")
    func noCutoffIncludesUndatedAssets() {
        let undated = InventoryAssetSnapshot(
            creationDate: nil,
            mediaKind: "image",
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            duration: 0,
            isLivePhoto: false
        )
        let selection = InventoryEstimator().selection(
            from: [undated],
            matching: InventorySelectionFilter(includeFavorites: true, includeHidden: true)
        )

        #expect(selection.assetCount == 1)
    }

    @Test("A manual date range includes its first day and excludes its upper bound")
    func manualRangeUsesHalfOpenBounds() {
        let filter = InventorySelectionFilter(
            rangeStartDate: makeDate(year: 2022),
            rangeEndDate: makeDate(year: 2024),
            includeFavorites: true,
            includeHidden: true
        )
        let selection = InventoryEstimator().selection(
            from: [
                snapshot(year: 2021, mediaKind: "image"),
                snapshot(year: 2022, mediaKind: "image"),
                snapshot(year: 2023, mediaKind: "video"),
                snapshot(year: 2024, mediaKind: "image")
            ],
            matching: filter
        )

        #expect(selection.assetCount == 2)
        #expect(selection.photoCount == 1)
        #expect(selection.videoCount == 1)
    }

    private func snapshot(
        year: Int,
        month: Int = 1,
        mediaKind: String,
        duration: TimeInterval = 0,
        live: Bool = false,
        favorite: Bool = false,
        hidden: Bool = false
    ) -> InventoryAssetSnapshot {
        InventoryAssetSnapshot(
            creationDate: makeDate(year: year, month: month),
            mediaKind: mediaKind,
            pixelWidth: mediaKind == "video" ? 1_920 : 4_032,
            pixelHeight: mediaKind == "video" ? 1_080 : 3_024,
            duration: duration,
            isLivePhoto: live,
            isFavorite: favorite,
            isHidden: hidden
        )
    }

    private func makeDate(year: Int, month: Int = 1) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1))!
    }
}
