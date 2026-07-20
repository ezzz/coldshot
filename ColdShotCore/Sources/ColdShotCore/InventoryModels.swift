import Foundation

public struct InventoryAssetSnapshot: Equatable, Sendable {
    public let creationDate: Date?
    public let mediaKind: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval
    public let isLivePhoto: Bool
    public let isFavorite: Bool
    public let isHidden: Bool

    public init(
        creationDate: Date?,
        mediaKind: String,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval,
        isLivePhoto: Bool,
        isFavorite: Bool = false,
        isHidden: Bool = false
    ) {
        self.creationDate = creationDate
        self.mediaKind = mediaKind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isLivePhoto = isLivePhoto
        self.isFavorite = isFavorite
        self.isHidden = isHidden
    }
}

public struct InventoryVolumeEstimate: Equatable, Sendable {
    public let lowerBoundBytes: Int64
    public let upperBoundBytes: Int64

    public init(lowerBoundBytes: Int64, upperBoundBytes: Int64) {
        self.lowerBoundBytes = lowerBoundBytes
        self.upperBoundBytes = upperBoundBytes
    }

    public static let zero = InventoryVolumeEstimate(lowerBoundBytes: 0, upperBoundBytes: 0)

    public static func + (lhs: Self, rhs: Self) -> Self {
        InventoryVolumeEstimate(
            lowerBoundBytes: lhs.lowerBoundBytes + rhs.lowerBoundBytes,
            upperBoundBytes: lhs.upperBoundBytes + rhs.upperBoundBytes
        )
    }
}

public struct InventoryMonthKey: Hashable, Codable, Identifiable, Comparable, Sendable {
    public var id: String { String(format: "%04d-%02d", year, month) }
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.year == rhs.year ? lhs.month < rhs.month : lhs.year < rhs.year
    }

    public func startDate(calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    public func exclusiveEndDate(calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        guard let start = startDate(calendar: calendar) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: start)
    }
}

public struct InventoryMonthSummary: Identifiable, Equatable, Sendable {
    public var id: InventoryMonthKey { key }
    public let key: InventoryMonthKey
    public let photoCount: Int
    public let videoCount: Int
    public let livePhotoCount: Int
    public let videoDuration: TimeInterval
    public let estimatedVolume: InventoryVolumeEstimate

    public var assetCount: Int { photoCount + videoCount }
}

public struct InventoryYearSummary: Identifiable, Equatable, Sendable {
    public var id: Int { year }

    public let year: Int
    public let photoCount: Int
    public let videoCount: Int
    public let livePhotoCount: Int
    public let videoDuration: TimeInterval
    public let estimatedVolume: InventoryVolumeEstimate
    public let months: [InventoryMonthSummary]

    public var assetCount: Int { photoCount + videoCount }

    public init(
        year: Int,
        photoCount: Int,
        videoCount: Int,
        livePhotoCount: Int,
        videoDuration: TimeInterval,
        estimatedVolume: InventoryVolumeEstimate,
        months: [InventoryMonthSummary] = []
    ) {
        self.year = year
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.livePhotoCount = livePhotoCount
        self.videoDuration = videoDuration
        self.estimatedVolume = estimatedVolume
        self.months = months
    }
}

public struct InventorySelectionSummary: Equatable, Sendable {
    public let cutoffDate: Date?
    public let assetCount: Int
    public let photoCount: Int
    public let videoCount: Int
    public let livePhotoCount: Int
    public let videoDuration: TimeInterval
    public let estimatedVolume: InventoryVolumeEstimate

    public init(
        cutoffDate: Date?,
        assetCount: Int,
        photoCount: Int,
        videoCount: Int,
        livePhotoCount: Int,
        videoDuration: TimeInterval,
        estimatedVolume: InventoryVolumeEstimate
    ) {
        self.cutoffDate = cutoffDate
        self.assetCount = assetCount
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.livePhotoCount = livePhotoCount
        self.videoDuration = videoDuration
        self.estimatedVolume = estimatedVolume
    }
}

public struct InventorySelectionFilter: Codable, Equatable, Sendable {
    public var cutoffDate: Date?
    public var rangeStartDate: Date?
    public var rangeEndDate: Date?
    public var includeStandardPhotos: Bool
    public var includeLivePhotos: Bool
    public var includeVideos: Bool
    public var includeFavorites: Bool
    public var includeHidden: Bool

    public init(
        cutoffDate: Date? = nil,
        rangeStartDate: Date? = nil,
        rangeEndDate: Date? = nil,
        includeStandardPhotos: Bool = true,
        includeLivePhotos: Bool = true,
        includeVideos: Bool = true,
        includeFavorites: Bool = false,
        includeHidden: Bool = false
    ) {
        self.cutoffDate = cutoffDate
        self.rangeStartDate = rangeStartDate
        self.rangeEndDate = rangeEndDate
        self.includeStandardPhotos = includeStandardPhotos
        self.includeLivePhotos = includeLivePhotos
        self.includeVideos = includeVideos
        self.includeFavorites = includeFavorites
        self.includeHidden = includeHidden
    }

    public func includes(
        _ asset: InventoryAssetSnapshot,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Bool {
        if let rangeStartDate {
            guard let creationDate = asset.creationDate,
                  creationDate >= rangeStartDate else { return false }
        }
        if let rangeEndDate {
            guard let creationDate = asset.creationDate,
                  creationDate < rangeEndDate else { return false }
        }
        if let cutoffDate {
            guard let creationDate = asset.creationDate else { return false }
            guard creationDate < cutoffDate else { return false }
        }

        if asset.isFavorite && !includeFavorites { return false }
        if asset.isHidden && !includeHidden { return false }

        if asset.mediaKind == "video" { return includeVideos }
        guard asset.mediaKind == "image" else { return false }
        return asset.isLivePhoto ? includeLivePhotos : includeStandardPhotos
    }
}

public struct InventoryReport: Equatable, Sendable {
    public let years: [InventoryYearSummary]
    public let undatedAssetCount: Int

    public init(years: [InventoryYearSummary], undatedAssetCount: Int) {
        self.years = years
        self.undatedAssetCount = undatedAssetCount
    }

    public var totalAssetCount: Int {
        years.reduce(undatedAssetCount) { $0 + $1.assetCount }
    }

    public func selection(before cutoffDate: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> InventorySelectionSummary {
        let included = years.flatMap(\.months).filter { summary in
            guard let start = summary.key.startDate(calendar: calendar) else { return false }
            return start < cutoffDate
        }

        return InventorySelectionSummary(
            cutoffDate: cutoffDate,
            assetCount: included.reduce(0) { $0 + $1.assetCount },
            photoCount: included.reduce(0) { $0 + $1.photoCount },
            videoCount: included.reduce(0) { $0 + $1.videoCount },
            livePhotoCount: included.reduce(0) { $0 + $1.livePhotoCount },
            videoDuration: included.reduce(0) { $0 + $1.videoDuration },
            estimatedVolume: included.reduce(.zero) { $0 + $1.estimatedVolume }
        )
    }
}

public struct InventoryEstimator: Sendable {
    public init() {}

    public func buildReport(
        from assets: some Sequence<InventoryAssetSnapshot>,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> InventoryReport {
        var buckets: [Int: MutableYearSummary] = [:]
        var monthBuckets: [InventoryMonthKey: MutableYearSummary] = [:]
        var undatedAssetCount = 0

        for asset in assets {
            guard let creationDate = asset.creationDate else {
                undatedAssetCount += 1
                continue
            }
            let year = calendar.component(.year, from: creationDate)
            let month = calendar.component(.month, from: creationDate)
            var bucket = buckets[year, default: MutableYearSummary()]
            var monthBucket = monthBuckets[InventoryMonthKey(year: year, month: month), default: MutableYearSummary()]
            if asset.mediaKind == "video" {
                bucket.videoCount += 1
                bucket.videoDuration += max(asset.duration, 0)
                monthBucket.videoCount += 1
                monthBucket.videoDuration += max(asset.duration, 0)
            } else {
                bucket.photoCount += 1
                monthBucket.photoCount += 1
                if asset.isLivePhoto {
                    bucket.livePhotoCount += 1
                    monthBucket.livePhotoCount += 1
                }
            }
            let estimate = estimate(for: asset)
            bucket.estimatedVolume = bucket.estimatedVolume + estimate
            monthBucket.estimatedVolume = monthBucket.estimatedVolume + estimate
            buckets[year] = bucket
            monthBuckets[InventoryMonthKey(year: year, month: month)] = monthBucket
        }

        let summaries = buckets.keys.sorted().map { year in
            let bucket = buckets[year] ?? MutableYearSummary()
            return InventoryYearSummary(
                year: year,
                photoCount: bucket.photoCount,
                videoCount: bucket.videoCount,
                livePhotoCount: bucket.livePhotoCount,
                videoDuration: bucket.videoDuration,
                estimatedVolume: bucket.estimatedVolume,
                months: monthBuckets.keys
                    .filter { $0.year == year }
                    .sorted()
                    .map { key in
                        let month = monthBuckets[key] ?? MutableYearSummary()
                        return InventoryMonthSummary(
                            key: key,
                            photoCount: month.photoCount,
                            videoCount: month.videoCount,
                            livePhotoCount: month.livePhotoCount,
                            videoDuration: month.videoDuration,
                            estimatedVolume: month.estimatedVolume
                        )
                    }
            )
        }
        return InventoryReport(years: summaries, undatedAssetCount: undatedAssetCount)
    }

    public func estimate(for asset: InventoryAssetSnapshot) -> InventoryVolumeEstimate {
        let pixels = Int64(max(asset.pixelWidth, 1)) * Int64(max(asset.pixelHeight, 1))
        if asset.mediaKind == "video" {
            let seconds = max(asset.duration, 1)
            let megapixels = max(Double(pixels) / 1_000_000, 0.5)
            let lowBitsPerSecond = max(1_000_000, megapixels * 1_000_000)
            let highBitsPerSecond = max(12_000_000, megapixels * 8_000_000)
            return InventoryVolumeEstimate(
                lowerBoundBytes: Int64(seconds * lowBitsPerSecond / 8),
                upperBoundBytes: Int64(seconds * highBitsPerSecond / 8)
            )
        }

        let liveMultiplier: Double = asset.isLivePhoto ? 2.0 : 1.0
        return InventoryVolumeEstimate(
            lowerBoundBytes: Int64(Double(pixels) * 0.18 * liveMultiplier),
            upperBoundBytes: Int64(Double(pixels) * 1.25 * liveMultiplier)
        )
    }

    public func selection(
        from assets: some Sequence<InventoryAssetSnapshot>,
        matching filter: InventorySelectionFilter,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> InventorySelectionSummary {
        var assetCount = 0
        var photoCount = 0
        var videoCount = 0
        var livePhotoCount = 0
        var videoDuration: TimeInterval = 0
        var estimatedVolume = InventoryVolumeEstimate.zero

        for asset in assets where filter.includes(asset, calendar: calendar) {
            assetCount += 1
            if asset.mediaKind == "video" {
                videoCount += 1
                videoDuration += max(asset.duration, 0)
            } else {
                photoCount += 1
                if asset.isLivePhoto { livePhotoCount += 1 }
            }
            estimatedVolume = estimatedVolume + estimate(for: asset)
        }

        return InventorySelectionSummary(
            cutoffDate: filter.cutoffDate,
            assetCount: assetCount,
            photoCount: photoCount,
            videoCount: videoCount,
            livePhotoCount: livePhotoCount,
            videoDuration: videoDuration,
            estimatedVolume: estimatedVolume
        )
    }
}

private struct MutableYearSummary {
    var photoCount = 0
    var videoCount = 0
    var livePhotoCount = 0
    var videoDuration: TimeInterval = 0
    var estimatedVolume: InventoryVolumeEstimate = .zero
}
