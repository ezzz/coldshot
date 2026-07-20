import Testing
@testable import ColdShotCore

@Suite("Archive time estimator")
struct ArchiveTimeEstimatorTests {
    @Test("ETA remains hidden until enough complete assets are sampled")
    func waitsForStableSample() {
        var estimator = ArchiveTimeEstimator()
        for _ in 0..<19 { estimator.recordAssetDuration(10) }
        #expect(estimator.estimatedRemainingTime(forRemainingAssetCount: 10) == nil)
        estimator.recordAssetDuration(10)
        #expect(estimator.estimatedRemainingTime(forRemainingAssetCount: 10) == 100)
    }

    @Test("Recent transfer durations progressively influence ETA")
    func smoothsRecentDurations() {
        var estimator = ArchiveTimeEstimator()
        for _ in 0..<20 { estimator.recordAssetDuration(10) }
        let before = estimator.estimatedRemainingTime(forRemainingAssetCount: 10)
        for _ in 0..<20 { estimator.recordAssetDuration(30) }
        let after = estimator.estimatedRemainingTime(forRemainingAssetCount: 10)
        #expect(before == 100)
        #expect(after != nil)
        #expect(after! > before!)
        #expect(after! < 300)
    }
}
