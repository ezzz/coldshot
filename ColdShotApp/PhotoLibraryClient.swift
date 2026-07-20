import ColdShotCore
import Foundation
import OSLog
@preconcurrency import Photos

enum ColdShotLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.coldshot.prototype"
    static var diagnosticSubsystem: String { subsystem }
    static let workflow = Logger(subsystem: subsystem, category: "Workflow")
    static let photoKit = Logger(subsystem: subsystem, category: "PhotoKit")
    static let archive = Logger(subsystem: subsystem, category: "Archive")

    static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(String(reflecting: type(of: error))) | \(nsError.domain) (\(nsError.code)) | \(nsError.localizedDescription)"
    }

    static func diagnostic(category: String, level: String, message: String) {
        DiagnosticRecorder.shared.record(category: category, level: level, message: message)
    }
}

struct PhotoAssetCandidate: Identifiable, Sendable {
    let id: String
    let displayName: String
    let snapshot: InventoryAssetSnapshot
    let modificationDate: Date?

    var mediaKind: String { snapshot.mediaKind }
    var creationDate: Date? { snapshot.creationDate }
    var isLivePhoto: Bool { snapshot.isLivePhoto }

    var creationDateText: String {
        guard let creationDate else { return "Date inconnue" }
        return creationDate.formatted(date: .abbreviated, time: .shortened)
    }
}

struct PhotoScanResult: Sendable {
    let totalCount: Int
    let candidates: [PhotoAssetCandidate]
    let inventoryReport: InventoryReport
}

struct PhotoLibrarySyncResult: Sendable {
    let batch: ArchiveIndexSyncBatch
    let usedPersistentChanges: Bool
}

private final class PersistentChangeAccumulator: @unchecked Sendable {
    var changedIdentifiers: Set<String> = []
    var deletedIdentifiers: Set<String> = []
    var latestToken: PHPersistentChangeToken
    var error: (any Error)?

    init(token: PHPersistentChangeToken) {
        latestToken = token
    }
}

enum PhotoLibraryError: Error, LocalizedError {
    case authorizationRequired
    case libraryUnavailable(String)
    case assetUnavailable(String)
    case sourceHasNoResources(String)
    case assetNoLongerMatchesSelection(String)
    case resourceInventoryChanged(String)
    case resourceConsumerFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            "L’accès à Photos est requis avant l’inventaire."
        case .libraryUnavailable(let details):
            "La Photothèque système est indisponible. \(details)"
        case .assetUnavailable(let identifier):
            "L’asset Photos n’est plus disponible : \(identifier)"
        case .sourceHasNoResources(let identifier):
            "L’asset Photos ne contient aucune ressource exportable : \(identifier)"
        case .assetNoLongerMatchesSelection(let identifier):
            "L’asset Photos ne correspond plus aux filtres choisis : \(identifier). Relancez l’analyse avant de reprendre."
        case .resourceInventoryChanged(let identifier):
            "L’inventaire des ressources Photos a changé avant l’export : \(identifier)"
        case .resourceConsumerFailed(let message):
            "Le moteur d’archive a refusé des données PhotoKit : \(message)"
        }
    }
}

extension PhotoLibraryError: ArchiveFailureClassifying {
    var archiveFailureDisposition: ArchiveFailureDisposition {
        switch self {
        case .assetUnavailable, .sourceHasNoResources, .assetNoLongerMatchesSelection,
             .resourceInventoryChanged:
            .recoverableAsset
        case .authorizationRequired, .libraryUnavailable, .resourceConsumerFailed:
            .fatal
        }
    }

    var archiveFailureCategory: ArchiveFailureCategory {
        switch self {
        case .assetUnavailable:
            .assetUnavailable
        case .sourceHasNoResources:
            .sourceHasNoResources
        case .assetNoLongerMatchesSelection:
            .selectionChanged
        case .resourceInventoryChanged:
            .sourceChanged
        case .authorizationRequired:
            .authorization
        case .libraryUnavailable:
            .photoLibrary
        case .resourceConsumerFailed:
            .destination
        }
    }
}

actor PhotoLibraryClient {
    func synchronize(previousTokenData: Data?, forceFullScan: Bool = false) throws -> PhotoLibrarySyncResult {
        if !forceFullScan, let previousTokenData {
            do {
                return try persistentChanges(since: previousTokenData)
            } catch {
                ColdShotLog.photoKit.notice("Persistent PhotoKit changes unavailable; falling back to full inventory; error=\(ColdShotLog.describe(error), privacy: .public)")
            }
        }
        return try fullSynchronization()
    }

    func availabilityMessage() -> String? {
        guard let reason = PHPhotoLibrary.shared().unavailabilityReason else { return nil }
        ColdShotLog.photoKit.error("System Photo Library unavailable: \(Self.describe(reason), privacy: .public)")
        return Self.describe(reason)
    }

    func scan() throws -> PhotoScanResult {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        ColdShotLog.photoKit.info("Starting PhotoKit inventory; authorization=\(authorization.rawValue, privacy: .public)")
        guard authorization == .authorized || authorization == .limited else {
            ColdShotLog.photoKit.error("PhotoKit inventory refused; authorization=\(authorization.rawValue, privacy: .public)")
            throw PhotoLibraryError.authorizationRequired
        }
        try Self.assertLibraryAvailable()

        let options = Self.personalLibraryFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)

        if assets.count == NSNotFound {
            throw PhotoLibraryError.libraryUnavailable(
                availabilityDetails(fallback: "Photos could not create a valid query for the System Photo Library.")
            )
        }
        try Self.assertLibraryAvailable()

        var candidates: [PhotoAssetCandidate] = []
        candidates.reserveCapacity(assets.count)
        var snapshots: [InventoryAssetSnapshot] = []
        snapshots.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let snapshot = Self.snapshot(for: asset)
            snapshots.append(snapshot)
            candidates.append(
                PhotoAssetCandidate(
                    id: asset.localIdentifier,
                    displayName: Self.displayName(for: snapshot),
                    snapshot: snapshot,
                    modificationDate: asset.modificationDate
                )
            )
        }
        ColdShotLog.photoKit.info("PhotoKit inventory completed; assets=\(assets.count, privacy: .public)")
        return PhotoScanResult(
            totalCount: assets.count,
            candidates: candidates,
            inventoryReport: InventoryEstimator().buildReport(from: snapshots)
        )
    }

    private func fullSynchronization() throws -> PhotoLibrarySyncResult {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoLibraryError.authorizationRequired
        }
        try Self.assertLibraryAvailable()
        let library = PHPhotoLibrary.shared()
        let token = library.currentChangeToken
        let result = try scan()
        let tokenData = try Self.encode(token: token)
        return PhotoLibrarySyncResult(
            batch: ArchiveIndexSyncBatch(
                assets: result.candidates.map(Self.indexAsset),
                isFullScan: true,
                photoKitChangeToken: tokenData
            ),
            usedPersistentChanges: false
        )
    }

    private func persistentChanges(since tokenData: Data) throws -> PhotoLibrarySyncResult {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoLibraryError.authorizationRequired
        }
        try Self.assertLibraryAvailable()
        guard let token = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: PHPersistentChangeToken.self,
            from: tokenData
        ) else {
            throw PhotoLibraryError.libraryUnavailable("Le point de reprise PhotoKit local est illisible.")
        }

        let library = PHPhotoLibrary.shared()
        let changes = try library.fetchPersistentChanges(since: token)
        let accumulator = PersistentChangeAccumulator(token: token)
        changes.__enumerateChanges { change, stop in
            guard accumulator.error == nil else {
                stop.pointee = true
                return
            }
            do {
                let details = try change.changeDetails(for: .asset)
                let changed = details.insertedLocalIdentifiers
                    .union(details.updatedLocalIdentifiers)
                accumulator.changedIdentifiers.formUnion(changed)
                accumulator.changedIdentifiers.subtract(details.deletedLocalIdentifiers)
                accumulator.deletedIdentifiers.formUnion(details.deletedLocalIdentifiers)
                accumulator.deletedIdentifiers.subtract(changed)
                accumulator.latestToken = change.changeToken
            } catch {
                accumulator.error = error
                stop.pointee = true
            }
        }
        if let enumerationError = accumulator.error { throw enumerationError }

        let fetchedAssets = try Self.fetchAssets(identifiers: Array(accumulator.changedIdentifiers))
        let fetchedIdentifiers = Set(fetchedAssets.map(\.localIdentifier))
        accumulator.deletedIdentifiers.formUnion(
            accumulator.changedIdentifiers.subtracting(fetchedIdentifiers)
        )
        let encodedToken = try Self.encode(token: accumulator.latestToken)
        ColdShotLog.photoKit.info("Persistent PhotoKit changes ready; changed=\(fetchedAssets.count, privacy: .public) deleted=\(accumulator.deletedIdentifiers.count, privacy: .public)")
        return PhotoLibrarySyncResult(
            batch: ArchiveIndexSyncBatch(
                assets: fetchedAssets.map(Self.indexAsset),
                deletedAssetIdentifiers: accumulator.deletedIdentifiers,
                isFullScan: false,
                photoKitChangeToken: encodedToken
            ),
            usedPersistentChanges: true
        )
    }

    private static func encode(token: PHPersistentChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func fetchAssets(identifiers: [String]) throws -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        try assertLibraryAvailable()
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: personalLibraryFetchOptions()
        )
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        try assertLibraryAvailable()
        return assets
    }

    private static func indexAsset(_ candidate: PhotoAssetCandidate) -> ArchiveIndexAsset {
        ArchiveIndexAsset(
            assetIdentifier: candidate.id,
            creationDate: candidate.creationDate,
            modificationDate: candidate.modificationDate,
            mediaKind: candidate.snapshot.mediaKind,
            pixelWidth: candidate.snapshot.pixelWidth,
            pixelHeight: candidate.snapshot.pixelHeight,
            duration: candidate.snapshot.duration,
            isLivePhoto: candidate.snapshot.isLivePhoto,
            isFavorite: candidate.snapshot.isFavorite,
            isHidden: candidate.snapshot.isHidden
        )
    }

    private static func indexAsset(_ asset: PHAsset) -> ArchiveIndexAsset {
        let snapshot = snapshot(for: asset)
        return ArchiveIndexAsset(
            assetIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            mediaKind: snapshot.mediaKind,
            pixelWidth: snapshot.pixelWidth,
            pixelHeight: snapshot.pixelHeight,
            duration: snapshot.duration,
            isLivePhoto: snapshot.isLivePhoto,
            isFavorite: snapshot.isFavorite,
            isHidden: snapshot.isHidden
        )
    }

    func prepareArchivePlans(
        for candidates: [PhotoAssetCandidate],
        matching filter: InventorySelectionFilter? = nil
    ) throws -> [ArchiveAssetPlan] {
        try prepareArchivePlans(
            forIdentifiers: candidates.map(\.id),
            matching: filter
        )
    }

    func prepareArchivePlan(
        forIdentifier identifier: String,
        matching filter: InventorySelectionFilter? = nil
    ) throws -> ArchiveAssetPlan {
        guard let plan = try prepareArchivePlans(
            forIdentifiers: [identifier],
            matching: filter
        ).first else {
            throw PhotoLibraryError.assetUnavailable(identifier)
        }
        return plan
    }

    func prepareArchivePlans(
        forIdentifiers identifiers: [String],
        matching filter: InventorySelectionFilter? = nil
    ) throws -> [ArchiveAssetPlan] {
        ColdShotLog.photoKit.info("Preparing PhotoKit plans; requested=\(identifiers.count, privacy: .public)")
        try Self.assertLibraryAvailable()
        let fetched = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: Self.personalLibraryFetchOptions()
        )
        var assetsByIdentifier: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }
        ColdShotLog.photoKit.info("PhotoKit plan fetch completed; requested=\(identifiers.count, privacy: .public) fetched=\(assetsByIdentifier.count, privacy: .public)")
        try Self.assertLibraryAvailable()

        let missingIdentifiers = identifiers.filter { assetsByIdentifier[$0] == nil }
        if let firstMissingIdentifier = missingIdentifiers.first {
            ColdShotLog.photoKit.error("PhotoKit plan fetch is incomplete; missing=\(missingIdentifiers.count, privacy: .public) firstAsset=\(firstMissingIdentifier, privacy: .public)")
        }

        let plans = try identifiers.map { identifier in
            guard let asset = assetsByIdentifier[identifier] else {
                ColdShotLog.photoKit.error("Asset missing while preparing plans; asset=\(identifier, privacy: .public)")
                throw PhotoLibraryError.assetUnavailable(identifier)
            }
            if let filter, !filter.includes(Self.snapshot(for: asset)) {
                ColdShotLog.photoKit.error("Asset no longer matches selection; asset=\(identifier, privacy: .public)")
                throw PhotoLibraryError.assetNoLongerMatchesSelection(identifier)
            }
            let resources = PHAssetResource.assetResources(for: asset)
            guard !resources.isEmpty else {
                ColdShotLog.photoKit.error("Asset has no exportable resources; asset=\(identifier, privacy: .public)")
                throw PhotoLibraryError.sourceHasNoResources(identifier)
            }
            let resourcePlans = Self.resourcePlans(assetIdentifier: identifier, resources: resources)
            return ArchiveAssetPlan(
                assetIdentifier: identifier,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                mediaKind: Self.mediaKind(asset.mediaType),
                resources: resourcePlans
            )
        }
        ColdShotLog.photoKit.info("PhotoKit plans ready; assets=\(plans.count, privacy: .public)")
        return plans
    }

    fileprivate static func assertLibraryAvailable() throws {
        if let reason = PHPhotoLibrary.shared().unavailabilityReason {
            throw PhotoLibraryError.libraryUnavailable(Self.describe(reason))
        }
    }

    /// Every fetch used by the archive pipeline must address the same PhotoKit
    /// population. In particular, both hidden assets and non-representative
    /// members of burst sequences are excluded by PhotoKit's default options.
    fileprivate static func personalLibraryFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return options
    }

    private func availabilityDetails(fallback: String) -> String {
        guard let reason = PHPhotoLibrary.shared().unavailabilityReason else { return fallback }
        return Self.describe(reason)
    }

    fileprivate static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        let path = (nsError.userInfo[NSURLErrorKey] as? URL)?.path(percentEncoded: false)
        let location = path.map { " Photothèque : \($0)." } ?? ""
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription).\(location)"
    }

    fileprivate static func resourceIdentifier(assetIdentifier: String, index: Int, type: Int) -> String {
        "\(assetIdentifier)::\(index)::\(type)"
    }

    fileprivate static func resourcePlans(
        assetIdentifier: String,
        resources: [PHAssetResource]
    ) -> [ArchiveResourcePlan] {
        resources.enumerated().map { index, resource in
            ArchiveResourcePlan(
                resourceIdentifier: resourceIdentifier(
                    assetIdentifier: assetIdentifier,
                    index: index,
                    type: resource.type.rawValue
                ),
                originalFilename: resource.originalFilename,
                resourceType: resourceTypeName(resource.type),
                uniformTypeIdentifier: resource.uniformTypeIdentifier
            )
        }
    }

    fileprivate static func resourceTypeName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternatePhoto"
        case .fullSizePhoto: "fullSizePhoto"
        case .fullSizeVideo: "fullSizeVideo"
        case .adjustmentData: "adjustmentData"
        case .adjustmentBasePhoto: "adjustmentBasePhoto"
        case .pairedVideo: "pairedVideo"
        case .fullSizePairedVideo: "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: "adjustmentBaseVideo"
        case .photoProxy: "photoProxy"
        @unknown default: "unknown-\(type.rawValue)"
        }
    }

    fileprivate static func mediaKind(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    private static func displayName(for snapshot: InventoryAssetSnapshot) -> String {
        if snapshot.mediaKind == "video" { return "Vidéo" }
        return snapshot.isLivePhoto ? "Live Photo" : "Photo"
    }

    fileprivate static func snapshot(for asset: PHAsset) -> InventoryAssetSnapshot {
        InventoryAssetSnapshot(
            creationDate: asset.creationDate,
            mediaKind: mediaKind(asset.mediaType),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden
        )
    }
}

final class PhotoKitResourceSource: @unchecked Sendable, ArchiveResourceSource {
    private let asset: ArchiveAssetPlan
    private let resourceIndexes: [String: Int]
    private let selectionFilter: InventorySelectionFilter?

    init(asset: ArchiveAssetPlan, selectionFilter: InventorySelectionFilter? = nil) {
        self.asset = asset
        self.selectionFilter = selectionFilter
        self.resourceIndexes = Dictionary(
            uniqueKeysWithValues: asset.resources.enumerated().map { ($0.element.resourceIdentifier, $0.offset) }
        )
    }

    func validate(asset plan: ArchiveAssetPlan) async throws {
        ColdShotLog.photoKit.debug("Validating PhotoKit asset; asset=\(plan.assetIdentifier, privacy: .public)")
        let (photoAsset, resources) = try currentAssetAndResources()
        if let selectionFilter,
           !selectionFilter.includes(PhotoLibraryClient.snapshot(for: photoAsset)) {
            throw PhotoLibraryError.assetNoLongerMatchesSelection(plan.assetIdentifier)
        }
        let currentPlans = PhotoLibraryClient.resourcePlans(
            assetIdentifier: photoAsset.localIdentifier,
            resources: resources
        )
        guard photoAsset.creationDate == plan.creationDate,
              PhotoLibraryClient.mediaKind(photoAsset.mediaType) == plan.mediaKind,
              currentPlans == plan.resources else {
            throw PhotoLibraryError.resourceInventoryChanged(plan.assetIdentifier)
        }
    }

    func consume(
        resource plan: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        ColdShotLog.photoKit.info("Starting PhotoKit resource request; asset=\(self.asset.assetIdentifier, privacy: .public) resource=\(plan.resourceIdentifier, privacy: .public)")
        guard let index = resourceIndexes[plan.resourceIdentifier] else {
            throw PhotoLibraryError.resourceInventoryChanged(plan.resourceIdentifier)
        }
        let (photoAsset, resources) = try currentAssetAndResources()
        guard resources.indices.contains(index) else {
            throw PhotoLibraryError.resourceInventoryChanged(plan.resourceIdentifier)
        }
        let resource = resources[index]
        let currentIdentifier = PhotoLibraryClient.resourceIdentifier(
            assetIdentifier: photoAsset.localIdentifier,
            index: index,
            type: resource.type.rawValue
        )
        guard currentIdentifier == plan.resourceIdentifier,
              resource.originalFilename == plan.originalFilename,
              resource.uniformTypeIdentifier == plan.uniformTypeIdentifier else {
            throw PhotoLibraryError.resourceInventoryChanged(plan.resourceIdentifier)
        }

        let manager = PHAssetResourceManager.default()
        let requestBox = PhotoKitRequestBox(manager: manager)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true

                let requestID = manager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { data in
                        guard requestBox.shouldAcceptData else { return }
                        do {
                            try handler(data)
                        } catch {
                            requestBox.recordConsumerError(error)
                        }
                    },
                    completionHandler: { error in
                        if let completionError = requestBox.completionError(photoKitError: error) {
                            ColdShotLog.photoKit.error("PhotoKit resource request failed; asset=\(self.asset.assetIdentifier, privacy: .public) resource=\(plan.resourceIdentifier, privacy: .public) error=\(ColdShotLog.describe(completionError), privacy: .public)")
                            continuation.resume(throwing: completionError)
                        } else {
                            ColdShotLog.photoKit.info("PhotoKit resource request completed; asset=\(self.asset.assetIdentifier, privacy: .public) resource=\(plan.resourceIdentifier, privacy: .public)")
                            continuation.resume()
                        }
                    }
                )
                requestBox.set(requestID: requestID)
            }
        } onCancel: {
            ColdShotLog.photoKit.notice("Cancelling PhotoKit resource request; asset=\(self.asset.assetIdentifier, privacy: .public) resource=\(plan.resourceIdentifier, privacy: .public)")
            requestBox.cancel()
        }
    }

    private func currentAssetAndResources() throws -> (PHAsset, [PHAssetResource]) {
        try PhotoLibraryClient.assertLibraryAvailable()
        guard let photoAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset.assetIdentifier],
            options: PhotoLibraryClient.personalLibraryFetchOptions()
        ).firstObject else {
            ColdShotLog.photoKit.error("Asset missing during resource access; asset=\(self.asset.assetIdentifier, privacy: .public)")
            throw PhotoLibraryError.assetUnavailable(asset.assetIdentifier)
        }
        try PhotoLibraryClient.assertLibraryAvailable()
        return (photoAsset, PHAssetResource.assetResources(for: photoAsset))
    }
}

private final class PhotoKitRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private let manager: PHAssetResourceManager
    private var requestID: PHAssetResourceDataRequestID?
    private var consumerError: (any Error)?
    private var cancellationRequested = false

    init(manager: PHAssetResourceManager) {
        self.manager = manager
    }

    var shouldAcceptData: Bool {
        lock.withLock { consumerError == nil && !cancellationRequested }
    }

    func set(requestID: PHAssetResourceDataRequestID) {
        let shouldCancel = lock.withLock {
            self.requestID = requestID
            return cancellationRequested || consumerError != nil
        }
        if shouldCancel {
            manager.cancelDataRequest(requestID)
        }
    }

    func recordConsumerError(_ error: any Error) {
        let requestID = lock.withLock { () -> PHAssetResourceDataRequestID? in
            guard consumerError == nil else { return nil }
            // Keep the original file-system/consumer error so the batch engine
            // never mistakes a destination failure for an isolated PhotoKit asset.
            consumerError = error
            return self.requestID
        }
        if let requestID {
            manager.cancelDataRequest(requestID)
        }
    }

    func cancel() {
        let requestID = lock.withLock { () -> PHAssetResourceDataRequestID? in
            cancellationRequested = true
            return self.requestID
        }
        if let requestID {
            manager.cancelDataRequest(requestID)
        }
    }

    func completionError(photoKitError: (any Error)?) -> (any Error)? {
        lock.withLock {
            if let consumerError { return consumerError }
            if cancellationRequested { return CancellationError() }
            return photoKitError
        }
    }
}
