import Foundation

public struct ArchiveTimeEstimator: Equatable, Sendable {
    private var smoothedSecondsPerAsset: TimeInterval?
    private var recentDurations: [TimeInterval] = []
    public private(set) var sampleCount = 0

    public init() {}

    public mutating func reset() {
        smoothedSecondsPerAsset = nil
        recentDurations = []
        sampleCount = 0
    }

    public mutating func recordAssetDuration(_ duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        let bounded = min(max(duration, 0.05), 6 * 60 * 60)
        recentDurations.append(bounded)
        if recentDurations.count > 60 { recentDurations.removeFirst() }
        let ordered = recentDurations.sorted()
        let trim = ordered.count >= 10 ? max(ordered.count / 10, 1) : 0
        let central = ordered.dropFirst(trim).dropLast(trim)
        let robustMean = central.reduce(0, +) / Double(max(central.count, 1))
        if let previous = smoothedSecondsPerAsset {
            let weight = sampleCount < 20 ? 1 / Double(sampleCount + 1) : 0.05
            smoothedSecondsPerAsset = previous + weight * (robustMean - previous)
        } else {
            smoothedSecondsPerAsset = robustMean
        }
        sampleCount += 1
    }

    public func estimatedRemainingTime(forRemainingAssetCount count: Int) -> TimeInterval? {
        guard count > 0, sampleCount >= 20, let smoothedSecondsPerAsset else { return nil }
        return smoothedSecondsPerAsset * Double(count)
    }
}
