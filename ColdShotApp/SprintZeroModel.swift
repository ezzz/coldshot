import AppKit
import ColdShotCore
import Foundation
import Observation
import UniformTypeIdentifiers
@preconcurrency import Photos

@MainActor
@Observable
final class SprintZeroModel {
    enum DestinationCapacityState: Equatable {
        case unavailable
        case local(availableBytes: Int64?)
        case remote(reportedAvailableBytes: Int64?)
        case unknown
    }

    enum MonthArchiveState: String, Equatable {
        case recent
        case toArchive
        case verifying
        case inProgress
        case partial
        case archived
        case attention
    }

    struct ArchiveMonthRow: Identifiable, Equatable {
        let summary: InventoryMonthSummary
        let archivedCount: Int
        let issueCount: Int
        let state: MonthArchiveState
        let isSelectedForAutomaticArchive: Bool

        var id: InventoryMonthKey { summary.key }
    }

    struct ArchiveYearRow: Identifiable, Equatable {
        let year: Int
        let photoCount: Int
        let videoCount: Int
        let estimatedVolume: InventoryVolumeEstimate
        let archivedCount: Int
        let issueCount: Int
        let state: MonthArchiveState

        var id: Int { year }
    }
    enum ArchiveMode: String, CaseIterable, Identifiable {
        case automatic
        case customRange

        var id: Self { self }

        var label: String {
            switch self {
            case .automatic: "Automatique"
            case .customRange: "Période personnalisée"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case preparingArchive
        case archiving
        case pausing
        case paused
        case succeeded
        case failed
    }

    enum ArchiveScope: String, CaseIterable, Identifiable {
        case all
        case year
        case testBatch

        var id: Self { self }

        var label: String {
            switch self {
            case .all: "Toute la sélection"
            case .year: "Une année"
            case .testBatch: "Lot de test"
            }
        }
    }

    struct ArchiveYearChoice: Identifiable, Equatable {
        let id: Int
        let label: String
        let selectedCount: Int
        let remainingCount: Int
    }

    private(set) var phase: Phase = .idle
    private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    private(set) var destinationURL: URL?
    private(set) var destinationAvailableByteCount: Int64?
    private(set) var destinationCapacityState: DestinationCapacityState = .unavailable
    private(set) var destinationIsReachable = false
    private(set) var candidates: [PhotoAssetCandidate] = []
    private(set) var inventoryReport: InventoryReport?
    private(set) var resumableCampaign: ArchiveCampaignJournal?
    private(set) var resumableBatch: BatchArchiveJournal?
    private(set) var latestCompletedBatch: BatchArchiveJournal?
    private(set) var archiveHistory: [ArchiveCampaignSummary] = []
    private(set) var issueCampaign: ArchiveCampaignJournal?
    private(set) var unresolvedArchiveIssues: [ArchiveCampaignAssetRecord] = []
    private(set) var cataloguedAssetIdentifiers: Set<String> = []
    private(set) var batchProgressText: String?
    private(set) var libraryAvailabilityMessage: String?
    private(set) var statusMessage = "Prêt à commencer."
    private(set) var progressFraction: Double?
    private(set) var lastManifestPath: String?
    private(set) var batchCompletedAssetCount = 0
    private(set) var batchTotalAssetCount = 0
    private(set) var currentAssetDate: Date?
    private(set) var isRefreshingArchiveCatalog = false
    private(set) var isSynchronizingLibrary = false
    private(set) var lastPhotoSyncDate: Date?
    private(set) var lastFullPhotoScanDate: Date?
    private(set) var lastSyncUsedPersistentChanges = false
    private(set) var changedAssetIdentifiers: Set<String> = []
    private var cachedEligibleCandidates: [PhotoAssetCandidate] = []
    private var cachedSelectionSummary: InventorySelectionSummary?
    private var timeEstimator = ArchiveTimeEstimator()
    private var displayedEstimatedRemainingDuration: TimeInterval?
    private var lastETARefreshDate: Date?
    private var currentAssetStartedAt: Date?
    private var cachedArchiveMonthBaseRows: [ArchiveMonthRow] = []
    private var hasInitialized = false
    private var lifecycleTasks: [Task<Void, Never>] = []

    var cutoffDate: Date = {
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        return calendar.date(from: DateComponents(year: calendar.component(.year, from: target))) ?? target
    }()
    var selectedAssetIdentifier: String?
    var archiveMode: ArchiveMode = .automatic
    var manualStartDate: Date = {
        Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    }()
    var manualEndDate: Date = Date()
    var batchLimit = 25
    var archiveScope: ArchiveScope = .all
    var selectedArchiveYear: Int?
    var usesCutoffDate = true
    var includeStandardPhotos = true
    var includeLivePhotos = true
    var includeVideos = true
    var includeFavorites = true
    var includeHidden = true

    private let photoLibrary = PhotoLibraryClient()
    private let archiveIndex = ArchiveIndexStore(databaseURL: SprintZeroModel.archiveIndexURL)
    private let bookmarkStore = DestinationBookmarkStore()
    private var archiveTask: Task<Void, Never>?
    private var archiveStateTask: Task<Void, Never>?
    private static let undatedYear = Int.min
    private static let archiveProfileIdentifier = "system-photo-library"

    private static var archiveIndexURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("ColdShot", isDirectory: true)
            .appendingPathComponent("ArchiveIndex.sqlite")
    }

    var selectionSummary: InventorySelectionSummary? {
        cachedSelectionSummary
    }

    var remainingSelectionSummary: InventorySelectionSummary? {
        guard inventoryReport != nil else { return nil }
        return InventoryEstimator().selection(
            from: eligibleCandidates.lazy
                .filter {
                    !self.cataloguedAssetIdentifiers.contains($0.id)
                        || self.changedAssetIdentifiers.contains($0.id)
                }
                .map(\.snapshot),
            matching: InventorySelectionFilter(
                includeStandardPhotos: true,
                includeLivePhotos: true,
                includeVideos: true,
                includeFavorites: true,
                includeHidden: true
            )
        )
    }

    var eligibleCandidates: [PhotoAssetCandidate] {
        cachedEligibleCandidates
    }

    var archiveYearChoices: [ArchiveYearChoice] {
        var selectedCounts: [Int: Int] = [:]
        var remainingCounts: [Int: Int] = [:]
        for candidate in eligibleCandidates {
            let year = archiveYear(for: candidate)
            selectedCounts[year, default: 0] += 1
            if !cataloguedAssetIdentifiers.contains(candidate.id) {
                remainingCounts[year, default: 0] += 1
            }
        }
        return selectedCounts.keys.sorted(by: archiveYearSort).map { year in
            ArchiveYearChoice(
                id: year,
                label: year == Self.undatedYear ? "Sans date" : String(year),
                selectedCount: selectedCounts[year] ?? 0,
                remainingCount: remainingCounts[year] ?? 0
            )
        }
    }

    var archiveRunCandidates: [PhotoAssetCandidate] {
        eligibleCandidates.filter {
            !cataloguedAssetIdentifiers.contains($0.id)
                || changedAssetIdentifiers.contains($0.id)
        }
    }

    var archiveRunSummary: InventorySelectionSummary? {
        guard inventoryReport != nil else { return nil }
        return InventoryEstimator().selection(
            from: archiveRunCandidates.lazy.map(\.snapshot),
            matching: InventorySelectionFilter(
                includeStandardPhotos: true,
                includeLivePhotos: true,
                includeVideos: true,
                includeFavorites: true,
                includeHidden: true
            )
        )
    }

    var cataloguedEligibleCount: Int {
        eligibleCandidates.count {
            cataloguedAssetIdentifiers.contains($0.id)
                && !changedAssetIdentifiers.contains($0.id)
        }
    }

    var remainingEligibleCount: Int {
        archiveRunCandidates.count
    }

    var undatedExcludedCount: Int {
        usesCutoffDate ? (inventoryReport?.undatedAssetCount ?? 0) : 0
    }

    private var selectionFilter: InventorySelectionFilter {
        let calendar = Calendar.current
        let manualStart = calendar.startOfDay(for: manualStartDate)
        let manualEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: manualEndDate)
        )
        return InventorySelectionFilter(
            cutoffDate: archiveMode == .automatic ? cutoffDate : nil,
            rangeStartDate: archiveMode == .customRange ? manualStart : nil,
            rangeEndDate: archiveMode == .customRange ? manualEnd : nil,
            includeStandardPhotos: includeStandardPhotos,
            includeLivePhotos: includeLivePhotos,
            includeVideos: includeVideos,
            includeFavorites: includeFavorites,
            includeHidden: includeHidden
        )
    }

    var automaticCoverageFrontier: Date? {
        guard archiveMode == .automatic else { return nil }
        let calendar = Calendar.current
        // Coverage is intentionally broader than the current UI options: excluding
        // favorites, hidden assets, or a media kind must never hide a real hole.
        let coverageFilter = InventorySelectionFilter(
            cutoffDate: cutoffDate,
            includeStandardPhotos: true,
            includeLivePhotos: true,
            includeVideos: true,
            includeFavorites: true,
            includeHidden: true
        )
        let dated = candidates.filter {
            $0.creationDate != nil && coverageFilter.includes($0.snapshot)
        }
        guard !dated.isEmpty else { return nil }
        if let firstHole = dated.first(where: {
            !cataloguedAssetIdentifiers.contains($0.id)
                || changedAssetIdentifiers.contains($0.id)
        }), let holeDate = firstHole.creationDate {
            return calendar.date(
                byAdding: .day,
                value: -1,
                to: calendar.startOfDay(for: holeDate)
            )
        }
        return calendar.date(byAdding: .day, value: -1, to: cutoffDate)
    }

    var unresolvedAutomaticChangeCount: Int {
        let coverageFilter = InventorySelectionFilter(
            cutoffDate: cutoffDate,
            includeStandardPhotos: true,
            includeLivePhotos: true,
            includeVideos: true,
            includeFavorites: true,
            includeHidden: true
        )
        return candidates.count {
            coverageFilter.includes($0.snapshot)
                && changedAssetIdentifiers.contains($0.id)
        }
    }

    var hasLimitedPhotosAccess: Bool { authorizationStatus == .limited }

    var archiveMonthRows: [ArchiveMonthRow] {
        let activeMonth = currentAssetDate.map(monthKey(for:))
        return cachedArchiveMonthBaseRows.map { base in
            let summary = base.summary
            let isTargeted = archiveMode == .automatic
                && (summary.key.exclusiveEndDate(calendar: .current) ?? .distantFuture) <= cutoffDate
            let state: MonthArchiveState
            if isRefreshingArchiveCatalog {
                state = .verifying
            } else if base.issueCount > 0 {
                state = .attention
            } else if activeMonth == summary.key && canPauseArchive {
                state = .inProgress
            } else if base.archivedCount == summary.assetCount, summary.assetCount > 0 {
                state = .archived
            } else if base.archivedCount > 0 {
                state = .partial
            } else if isTargeted {
                state = .toArchive
            } else {
                state = .recent
            }
            return ArchiveMonthRow(
                summary: summary,
                archivedCount: base.archivedCount,
                issueCount: base.issueCount,
                state: state,
                isSelectedForAutomaticArchive: isTargeted
            )
        }
    }

    var archiveYearRows: [ArchiveYearRow] {
        Dictionary(grouping: archiveMonthRows, by: { $0.summary.key.year })
            .map { year, months in
                let states = Set(months.map(\.state))
                let state: MonthArchiveState
                if states.contains(.verifying) { state = .verifying }
                else if states.contains(.attention) { state = .attention }
                else if states.contains(.inProgress) { state = .inProgress }
                else if states == [.archived] { state = .archived }
                else if states.contains(.partial) || states.contains(.archived) { state = .partial }
                else if states.contains(.toArchive) { state = .toArchive }
                else { state = .recent }
                return ArchiveYearRow(
                    year: year,
                    photoCount: months.reduce(0) { $0 + $1.summary.photoCount },
                    videoCount: months.reduce(0) { $0 + $1.summary.videoCount },
                    estimatedVolume: InventoryVolumeEstimate(
                        lowerBoundBytes: months.reduce(0) { $0 + $1.summary.estimatedVolume.lowerBoundBytes },
                        upperBoundBytes: months.reduce(0) { $0 + $1.summary.estimatedVolume.upperBoundBytes }
                    ),
                    archivedCount: months.reduce(0) { $0 + $1.archivedCount },
                    issueCount: months.reduce(0) { $0 + $1.issueCount },
                    state: state
                )
            }
            .sorted { $0.year < $1.year }
    }

    var archiveModeDescription: String {
        switch archiveMode {
        case .automatic:
            let inclusive = Calendar.current.date(byAdding: .day, value: -1, to: cutoffDate) ?? cutoffDate
            return "Tous les éléments jusqu’à \(inclusive.formatted(.dateTime.month(.wide).year())) inclus"
        case .customRange:
            return "Du \(manualStartDate.formatted(date: .abbreviated, time: .omitted)) au \(manualEndDate.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    var estimatedRemainingDuration: TimeInterval? {
        displayedEstimatedRemainingDuration
    }

    var estimatedRemainingText: String? {
        guard phase == .archiving || phase == .preparingArchive,
              batchCompletedAssetCount < batchTotalAssetCount,
              let duration = estimatedRemainingDuration else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3_600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        guard let value = formatter.string(from: max(duration, 60)) else { return nil }
        return "Environ \(value) restantes"
    }

    var destinationCapacityMessage: String? {
        switch destinationCapacityState {
        case .unavailable:
            return nil
        case .local(let available):
            guard let available, available > 0 else { return nil }
            if let lower = archiveRunSummary?.estimatedVolume.lowerBoundBytes, lower > available {
                return "L’espace du disque local est insuffisant pour l’estimation basse de cette sélection."
            }
            return "Disque local : \(formatBytes(available)) disponibles."
        case .remote(let available):
            guard let available, available > 0 else { return nil }
            return "Le partage réseau annonce environ \(formatBytes(available)) disponibles (valeur indicative)."
        case .unknown:
            return nil
        }
    }

    var destinationCapacityIsWarning: Bool {
        guard case .local(let available) = destinationCapacityState,
              let available,
              available > 0,
              let lower = archiveRunSummary?.estimatedVolume.lowerBoundBytes else { return false }
        return lower > available
    }

    var authorizationLabel: String {
        switch authorizationStatus {
        case .authorized: "Accès complet autorisé"
        case .limited: "Accès limité — seuls les assets autorisés seront visibles"
        case .denied: "Accès refusé dans Réglages Système"
        case .restricted: "Accès restreint par le système"
        case .notDetermined: "Autorisation non demandée"
        @unknown default: "État d’autorisation inconnu"
        }
    }

    var isWorking: Bool {
        switch phase {
        case .scanning, .preparingArchive, .archiving, .pausing:
            true
        case .idle, .ready, .paused, .succeeded, .failed:
            false
        }
    }

    var canScan: Bool {
        !isWorking
            && libraryAvailabilityMessage == nil
            && (authorizationStatus == .authorized || authorizationStatus == .limited)
    }

    var canArchive: Bool {
        !isWorking
            && libraryAvailabilityMessage == nil
            && destinationURL != nil
            && destinationIsReachable
            && selectedAssetIdentifier != nil
            && eligibleCandidates.contains { $0.id == selectedAssetIdentifier }
    }

    var canStartBatch: Bool {
        !isWorking
            && libraryAvailabilityMessage == nil
            && destinationURL != nil
            && destinationIsReachable
            && !archiveRunCandidates.isEmpty
    }

    var canResumeBatch: Bool {
        !isWorking && destinationURL != nil && destinationIsReachable
            && (resumableCampaign != nil || resumableBatch != nil)
    }

    var canRetryArchiveIssues: Bool {
        !isWorking && destinationURL != nil && destinationIsReachable
            && (issueCampaign?.failedCount ?? 0) > 0
    }

    var retryableIssueCount: Int { issueCampaign?.failedCount ?? 0 }

    var resumableCompletedCount: Int {
        resumableCampaign?.completedCount ?? resumableBatch?.completedCount ?? 0
    }

    var resumableTotalCount: Int {
        resumableCampaign?.assets.count ?? resumableBatch?.assets.count ?? 0
    }

    var canVerifyLatestBatch: Bool {
        !isWorking && destinationURL != nil && destinationIsReachable
            && latestCompletedBatch != nil
    }

    var canPauseArchive: Bool {
        phase == .preparingArchive || phase == .archiving
    }

    var isPausingArchive: Bool {
        phase == .pausing
    }

    var menuBarTitle: String {
        if canPauseArchive || isPausingArchive {
            return "\(batchCompletedAssetCount)/\(batchTotalAssetCount)"
        }
        if resumableTotalCount > 0 { return "En pause" }
        if phase == .failed { return "Action requise" }
        return "ColdShot"
    }

    var menuBarSystemImage: String {
        if canPauseArchive || isPausingArchive { return "externaldrive.fill.badge.timemachine" }
        if resumableTotalCount > 0 || phase == .paused { return "pause.circle.fill" }
        if phase == .failed { return "exclamationmark.triangle.fill" }
        return "externaldrive.badge.checkmark"
    }

    var statusSymbol: String {
        switch phase {
        case .idle, .ready: "info.circle"
        case .scanning, .preparingArchive, .archiving, .pausing: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .succeeded: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    func initialize() {
        guard !hasInitialized else { return }
        hasInitialized = true
        ColdShotLog.workflow.info("ColdShot model initialization")
        observeSystemLifecycle()
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        do {
            destinationURL = try bookmarkStore.resolve()
            refreshDestinationCapacity()
            refreshArchiveState()
        } catch {
            ColdShotLog.workflow.error("Failed to restore destination bookmark; error=\(ColdShotLog.describe(error), privacy: .public)")
            statusMessage = "Le dossier mémorisé doit être sélectionné à nouveau : \(error.localizedDescription)"
        }
        Task { await loadIndexAndSynchronizeLibrary() }
    }

    private func observeSystemLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        lifecycleTasks = [
            Task { [weak self] in
                for await _ in center.notifications(named: NSWorkspace.willSleepNotification) {
                    guard !Task.isCancelled else { break }
                    self?.systemWillSleep()
                }
            },
            Task { [weak self] in
                for await _ in center.notifications(named: NSWorkspace.didWakeNotification) {
                    guard !Task.isCancelled else { break }
                    self?.systemDidWake()
                }
            }
        ]
    }

    func systemWillSleep() {
        ColdShotLog.diagnostic(category: "Lifecycle", level: "NOTICE", message: "macOS will sleep")
        if canPauseArchive { pauseArchive() }
    }

    func systemDidWake() {
        ColdShotLog.diagnostic(category: "Lifecycle", level: "NOTICE", message: "macOS did wake")
        refreshDestinationCapacity()
        refreshArchiveState()
        Task { await refreshLibraryAvailability() }
        if destinationURL != nil, !destinationIsReachable {
            phase = .failed
            statusMessage = "La destination d’archive est indisponible. Remontez le NAS puis utilisez Continuer."
        }
    }

    func requestPhotosAccess() async {
        ColdShotLog.workflow.info("Requesting Photos authorization")
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        ColdShotLog.workflow.info("Photos authorization result=\(self.authorizationStatus.rawValue, privacy: .public)")
        switch authorizationStatus {
        case .authorized, .limited:
            statusMessage = "Photos est accessible. Mise à jour de l’index local…"
        case .denied, .restricted:
            statusMessage = "ColdShot ne peut pas inventorier la photothèque sans accès Photos."
        case .notDetermined:
            statusMessage = "L’autorisation Photos n’a pas été déterminée."
        @unknown default:
            statusMessage = "État d’autorisation Photos inconnu."
        }
        await refreshLibraryAvailability()
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            await synchronizeLibrary()
        }
    }

    func refreshLibraryAvailability() async {
        libraryAvailabilityMessage = await photoLibrary.availabilityMessage()
        if let libraryAvailabilityMessage {
            ColdShotLog.workflow.error("System Photo Library unavailable; details=\(libraryAvailabilityMessage, privacy: .public)")
            statusMessage = "Photothèque système indisponible : \(libraryAvailabilityMessage)"
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choisir le dossier d’archive ColdShot"
        panel.message = "Choisissez un dossier vide sur un partage monté par macOS ou sur un disque de test."
        panel.prompt = "Utiliser ce dossier"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try bookmarkStore.save(url: url)
            destinationURL = url
            refreshDestinationCapacity()
            refreshArchiveState()
            ColdShotLog.workflow.info("Archive destination selected; path=\(url.path(percentEncoded: false), privacy: .private)")
            statusMessage = "Destination prête : \(url.path(percentEncoded: false))"
        } catch {
            ColdShotLog.workflow.error("Failed to save archive destination; error=\(ColdShotLog.describe(error), privacy: .public)")
            phase = .failed
            statusMessage = "Impossible de mémoriser la destination : \(error.localizedDescription)"
        }
    }

    func recheckDestination() {
        refreshDestinationCapacity()
        if destinationIsReachable {
            statusMessage = "Destination à nouveau disponible."
            if phase == .failed { phase = resumableTotalCount > 0 ? .paused : .ready }
            refreshArchiveState()
        } else {
            statusMessage = "La destination reste indisponible. Vérifiez le montage du NAS dans le Finder."
        }
    }

    func exportDiagnosticReport() {
        let panel = NSSavePanel()
        panel.title = "Exporter le rapport de diagnostic ColdShot"
        let dateStamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "ColdShot-Diagnostic-\(dateStamp).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let issueSummary = unresolvedArchiveIssues.isEmpty
            ? "Aucun écart non résolu."
            : unresolvedArchiveIssues.map { record in
                let date = record.asset.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "sans date"
                let category = record.failureCategory?.rawValue ?? "unknown"
                let details = record.diagnosticError ?? record.lastError ?? "sans détail"
                return "- asset=\(record.asset.assetIdentifier.prefix(12)) date=\(date) category=\(category) attempts=\(record.attemptCount ?? 0) error=\(details)"
            }.joined(separator: "\n")
        let summary = """
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "développement")
        État: \(String(describing: phase))
        Mode: \(archiveMode.label)
        Photothèque indexée: \(candidates.count) éléments
        Dernière synchronisation: \(lastPhotoSyncDate?.formatted() ?? "jamais")
        Destination configurée: \(destinationURL == nil ? "non" : "oui")
        Progression: \(batchCompletedAssetCount)/\(batchTotalAssetCount)
        Changements à revoir: \(changedAssetIdentifiers.count)
        Écarts d’archive: \(unresolvedArchiveIssues.count)
        Message: \(statusMessage)

        ÉCARTS NON RÉSOLUS
        \(issueSummary)
        """
        let report = DiagnosticRecorder.shared.makeReport(
            summary: summary,
            subsystem: ColdShotLog.diagnosticSubsystem
        )
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Rapport de diagnostic exporté."
        } catch {
            phase = .failed
            statusMessage = "Impossible d’exporter le rapport : \(error.localizedDescription)"
        }
    }

    func scan() async {
        await synchronizeLibrary(forceFullScan: true)
    }

    func filtersDidChange() {
        if archiveMode == .automatic {
            let calendar = Calendar.current
            let normalized = calendar.date(
                from: DateComponents(
                    year: calendar.component(.year, from: cutoffDate),
                    month: calendar.component(.month, from: cutoffDate),
                    day: 1
                )
            ) ?? cutoffDate
            cutoffDate = normalized
            Task {
                try? await archiveIndex.saveTargetCutoffDate(
                    cutoffDate,
                    profileIdentifier: Self.archiveProfileIdentifier
                )
            }
        } else if manualEndDate < manualStartDate {
            manualEndDate = manualStartDate
            return
        }
        rebuildSelectionCache()
        if !eligibleCandidates.contains(where: { $0.id == selectedAssetIdentifier }) {
            selectedAssetIdentifier = eligibleCandidates.first?.id
        }
    }

    func selectAutomaticCutoff(_ month: InventoryMonthKey) {
        guard let boundary = month.exclusiveEndDate(calendar: .current) else { return }
        cutoffDate = boundary
        archiveMode = .automatic
        filtersDidChange()
    }

    func revealArchiveMonth(_ month: InventoryMonthKey) {
        guard let destinationURL else { return }
        let yearURL = destinationURL
            .appendingPathComponent("ColdShotArchive/assets", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", month.year), isDirectory: true)
        let monthURL = yearURL
            .appendingPathComponent(String(format: "%02d", month.month), isDirectory: true)
        let url: URL
        if FileManager.default.fileExists(atPath: monthURL.path) {
            url = monthURL
        } else if FileManager.default.fileExists(atPath: yearURL.path) {
            url = yearURL
        } else {
            statusMessage = "Le dossier de ce mois n’existe pas encore sur la destination."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func loadIndexAndSynchronizeLibrary() async {
        do {
            if let profile = try await archiveIndex.profile(
                identifier: Self.archiveProfileIdentifier
            ) {
                if let targetCutoffDate = profile.targetCutoffDate {
                    cutoffDate = targetCutoffDate
                }
                lastPhotoSyncDate = profile.lastDeltaScanAt
                lastFullPhotoScanDate = profile.lastFullScanAt
            }
            try await reloadCandidatesFromIndex()
        } catch {
            ColdShotLog.workflow.error("Failed to load local archive index; error=\(ColdShotLog.describe(error), privacy: .public)")
            statusMessage = "L’index local doit être reconstruit : \(error.localizedDescription)"
        }
        await refreshLibraryAvailability()
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            await synchronizeLibrary()
        }
    }

    func synchronizeLibrary(forceFullScan: Bool = false) async {
        guard !isSynchronizingLibrary,
              libraryAvailabilityMessage == nil,
              authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        isSynchronizingLibrary = true
        ColdShotLog.diagnostic(
            category: "PhotoKit",
            level: "INFO",
            message: forceFullScan ? "Full library synchronization started" : "Incremental library synchronization started"
        )
        phase = .scanning
        statusMessage = forceFullScan
            ? "Vérification complète de la photothèque…"
            : "Recherche des changements dans Photos…"
        defer { isSynchronizingLibrary = false }

        do {
            let profile = try await archiveIndex.profile(
                identifier: Self.archiveProfileIdentifier
            )
            let result = try await photoLibrary.synchronize(
                previousTokenData: profile?.photoKitChangeToken,
                forceFullScan: forceFullScan
            )
            try await archiveIndex.apply(
                result.batch,
                profileIdentifier: Self.archiveProfileIdentifier
            )
            lastPhotoSyncDate = result.batch.synchronizedAt
            if result.batch.isFullScan {
                lastFullPhotoScanDate = result.batch.synchronizedAt
            }
            lastSyncUsedPersistentChanges = result.usedPersistentChanges
            try await reloadCandidatesFromIndex()
            phase = .ready
            statusMessage = result.usedPersistentChanges
                ? "Photothèque à jour."
                : "Photothèque entièrement indexée."
            ColdShotLog.workflow.info("Local PhotoKit index synchronized; full=\(result.batch.isFullScan, privacy: .public) changed=\(result.batch.assets.count, privacy: .public) deleted=\(result.batch.deletedAssetIdentifiers.count, privacy: .public)")
            ColdShotLog.diagnostic(
                category: "PhotoKit",
                level: "INFO",
                message: "Synchronization completed; full=\(result.batch.isFullScan) changed=\(result.batch.assets.count) deleted=\(result.batch.deletedAssetIdentifiers.count)"
            )
        } catch {
            phase = .failed
            statusMessage = "La photothèque n’a pas pu être mise à jour. Exportez le rapport pour obtenir le détail."
            ColdShotLog.workflow.error("Local PhotoKit index synchronization failed; error=\(ColdShotLog.describe(error), privacy: .public)")
            ColdShotLog.diagnostic(category: "PhotoKit", level: "ERROR", message: ColdShotLog.describe(error))
        }
    }

    private func reloadCandidatesFromIndex() async throws {
        let indexedAssets = try await archiveIndex.assets()
        candidates = indexedAssets.map { asset in
            let snapshot = asset.inventorySnapshot
            return PhotoAssetCandidate(
                id: asset.assetIdentifier,
                displayName: asset.mediaKind == "video"
                    ? "Vidéo"
                    : (asset.isLivePhoto ? "Live Photo" : "Photo"),
                snapshot: snapshot,
                modificationDate: asset.modificationDate
            )
        }
        changedAssetIdentifiers = Set(
            indexedAssets.lazy.filter(\.needsReview).map(\.assetIdentifier)
        )
        inventoryReport = InventoryEstimator().buildReport(
            from: indexedAssets.lazy.map(\.inventorySnapshot)
        )
        rebuildSelectionCache()
        selectedAssetIdentifier = eligibleCandidates.first?.id
        if !candidates.isEmpty, phase == .idle {
            phase = .ready
        }
    }

    private func rebuildSelectionCache() {
        guard inventoryReport != nil else {
            cachedEligibleCandidates = []
            cachedSelectionSummary = nil
            selectedArchiveYear = nil
            cachedArchiveMonthBaseRows = []
            return
        }
        let filter = selectionFilter
        cachedEligibleCandidates = candidates.filter { filter.includes($0.snapshot) }
        cachedSelectionSummary = InventoryEstimator().selection(
            from: candidates.lazy.map(\.snapshot),
            matching: filter
        )
        let years = archiveYearChoices.map(\.id)
        if selectedArchiveYear == nil || !years.contains(selectedArchiveYear ?? Self.undatedYear) {
            selectedArchiveYear = years.first
        }
        rebuildArchiveOverviewCache()
    }

    private func rebuildArchiveOverviewCache() {
        guard let inventoryReport else {
            cachedArchiveMonthBaseRows = []
            return
        }
        let identifiersByMonth = Dictionary(grouping: candidates.compactMap { candidate -> (InventoryMonthKey, String)? in
            guard let date = candidate.creationDate else { return nil }
            return (monthKey(for: date), candidate.id)
        }, by: \.0)
        let issueCounts = Dictionary(grouping: unresolvedArchiveIssues.compactMap {
            $0.asset.creationDate.map(monthKey(for:))
        }, by: { $0 }).mapValues(\.count)
        cachedArchiveMonthBaseRows = inventoryReport.years.flatMap(\.months).map { summary in
            let identifiers = identifiersByMonth[summary.key]?.map(\.1) ?? []
            return ArchiveMonthRow(
                summary: summary,
                archivedCount: identifiers.count {
                    cataloguedAssetIdentifiers.contains($0) && !changedAssetIdentifiers.contains($0)
                },
                issueCount: issueCounts[summary.key] ?? 0,
                state: .recent,
                isSelectedForAutomaticArchive: false
            )
        }
    }

    private func archiveYear(for candidate: PhotoAssetCandidate) -> Int {
        guard let creationDate = candidate.creationDate else { return Self.undatedYear }
        return Calendar.current.component(.year, from: creationDate)
    }

    private func archiveYearSort(_ lhs: Int, _ rhs: Int) -> Bool {
        if lhs == Self.undatedYear { return false }
        if rhs == Self.undatedYear { return true }
        return lhs < rhs
    }

    func startArchive() {
        guard archiveTask == nil,
              let destinationURL,
              let selected = candidates.first(where: { $0.id == selectedAssetIdentifier }) else { return }

        phase = .preparingArchive
        progressFraction = 0
        batchCompletedAssetCount = 0
        batchTotalAssetCount = 0
        lastManifestPath = nil
        statusMessage = "Préparation de l’archive…"
        let filter = selectionFilter

        archiveTask = Task { [weak self] in
            guard let self else { return }
            await self.performArchive(
                candidate: selected,
                selectionFilter: filter,
                destinationURL: destinationURL
            )
        }
    }

    func startBatchArchive() {
        refreshDestinationCapacity()
        guard archiveTask == nil,
              let destinationURL,
              destinationIsReachable,
              !archiveRunCandidates.isEmpty else { return }

        let selectedCandidates = archiveRunCandidates
        ColdShotLog.workflow.info("User started archive campaign; mode=\(self.archiveMode.rawValue, privacy: .public) assets=\(selectedCandidates.count, privacy: .public)")
        ColdShotLog.diagnostic(category: "Archive", level: "INFO", message: "Campaign requested; mode=\(archiveMode.rawValue) assets=\(selectedCandidates.count)")
        phase = .preparingArchive
        progressFraction = 0
        batchCompletedAssetCount = 0
        batchTotalAssetCount = selectedCandidates.count
        batchProgressText = "Préparation de la campagne de \(selectedCandidates.count) assets…"
        statusMessage = batchProgressText ?? "Préparation de la campagne…"
        timeEstimator.reset()
        displayedEstimatedRemainingDuration = nil
        lastETARefreshDate = nil
        currentAssetStartedAt = nil
        let filter = selectionFilter

        archiveTask = Task { [weak self] in
            guard let self else { return }
            await self.performArchiveCampaign(
                candidates: selectedCandidates,
                cutoffDate: filter.cutoffDate,
                selectionFilter: filter,
                destinationURL: destinationURL
            )
        }
    }

    func resumeBatchArchive() {
        refreshDestinationCapacity()
        guard archiveTask == nil, let destinationURL, destinationIsReachable else { return }

        if let resumableCampaign {
            ColdShotLog.workflow.info("User resumed archive campaign; campaign=\(resumableCampaign.identifier.uuidString, privacy: .public) completed=\(resumableCampaign.completedCount, privacy: .public) total=\(resumableCampaign.assets.count, privacy: .public)")
        } else if let resumableBatch {
            ColdShotLog.workflow.info("User resumed legacy archive batch; job=\(resumableBatch.identifier.uuidString, privacy: .public) completed=\(resumableBatch.completedCount, privacy: .public) total=\(resumableBatch.assets.count, privacy: .public)")
        } else {
            return
        }

        phase = .preparingArchive
        batchCompletedAssetCount = resumableCompletedCount
        batchTotalAssetCount = resumableTotalCount
        progressFraction = batchProgress
        batchProgressText = "Vérification des éléments terminés, puis reprise de la campagne…"
        statusMessage = batchProgressText ?? "Reprise de la campagne…"
        timeEstimator.reset()
        displayedEstimatedRemainingDuration = nil
        lastETARefreshDate = nil
        currentAssetStartedAt = nil

        archiveTask = Task { [weak self] in
            guard let self else { return }
            if let campaign = self.resumableCampaign {
                await self.performCampaignResume(
                    identifier: campaign.identifier,
                    selectionFilter: campaign.selectionFilter,
                    destinationURL: destinationURL
                )
            } else if let batch = self.resumableBatch {
                await self.performBatchResume(
                    identifier: batch.identifier,
                    selectionFilter: batch.selectionFilter,
                    destinationURL: destinationURL
                )
            }
        }
    }

    func retryArchiveIssues() {
        refreshDestinationCapacity()
        guard archiveTask == nil,
              let destinationURL,
              destinationIsReachable,
              let issueCampaign,
              issueCampaign.failedCount > 0 else { return }

        phase = .preparingArchive
        batchCompletedAssetCount = issueCampaign.processedCount - issueCampaign.failedCount
        batchTotalAssetCount = issueCampaign.assets.count
        progressFraction = batchProgress
        batchProgressText = "Préparation d’une nouvelle tentative pour \(issueCampaign.failedCount) écart(s)…"
        statusMessage = batchProgressText ?? "Préparation…"
        timeEstimator.reset()
        displayedEstimatedRemainingDuration = nil
        lastETARefreshDate = nil
        currentAssetStartedAt = nil

        archiveTask = Task { [weak self] in
            guard let self else { return }
            await self.performCampaignResume(
                identifier: issueCampaign.identifier,
                selectionFilter: issueCampaign.selectionFilter,
                destinationURL: destinationURL,
                retryFailures: true
            )
        }
    }

    func pauseArchive() {
        guard archiveTask != nil else { return }
        ColdShotLog.workflow.notice("User requested a safe archive pause")
        ColdShotLog.diagnostic(category: "Archive", level: "NOTICE", message: "Safe pause requested")
        phase = .pausing
        statusMessage = "Mise en pause au prochain checkpoint sûr…"
        archiveTask?.cancel()
    }

    func verifyLatestBatch() {
        guard archiveTask == nil,
              let destinationURL,
              let latestCompletedBatch else { return }

        ColdShotLog.workflow.info("User started batch verification; job=\(latestCompletedBatch.identifier.uuidString, privacy: .public) assets=\(latestCompletedBatch.assets.count, privacy: .public)")

        phase = .preparingArchive
        batchCompletedAssetCount = 0
        batchTotalAssetCount = latestCompletedBatch.assets.count
        progressFraction = batchProgress
        batchProgressText = "Vérification du dernier lot : 0/\(batchTotalAssetCount) assets…"
        statusMessage = batchProgressText ?? "Vérification du dernier lot…"
        timeEstimator.reset()
        displayedEstimatedRemainingDuration = nil
        lastETARefreshDate = nil
        currentAssetStartedAt = nil

        archiveTask = Task { [weak self] in
            guard let self else { return }
            await self.performBatchVerification(
                identifier: latestCompletedBatch.identifier,
                destinationURL: destinationURL
            )
        }
    }

    private func performArchive(
        candidate: PhotoAssetCandidate,
        selectionFilter: InventorySelectionFilter,
        destinationURL: URL
    ) async {
        let accessStarted = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                destinationURL.stopAccessingSecurityScopedResource()
            }
            archiveTask = nil
        }

        do {
            ColdShotLog.archive.info("Single asset archive started; asset=\(candidate.id, privacy: .public)")
            guard let plan = try await photoLibrary.prepareArchivePlans(
                for: [candidate],
                matching: selectionFilter
            ).first else {
                throw PhotoLibraryError.assetUnavailable(candidate.id)
            }
            let engine = ArchiveEngine()
            let source = PhotoKitResourceSource(asset: plan, selectionFilter: selectionFilter)
            let manifest = try await engine.archive(
                asset: plan,
                source: source,
                destination: destinationURL
            ) { [weak self] event in
                guard Self.shouldForwardToInterface(event) else { return }
                Task { @MainActor in
                    self?.handle(event: event)
                }
            }
            phase = .succeeded
            progressFraction = 1
            cataloguedAssetIdentifiers.insert(candidate.id)
            try? await archiveIndex.markArchived([candidate.id])
            changedAssetIdentifiers.remove(candidate.id)
            rebuildSelectionCache()
            ColdShotLog.archive.info("Single asset archive completed; asset=\(candidate.id, privacy: .public) resources=\(manifest.resources.count, privacy: .public)")
            statusMessage = "Archive vérifiée : \(manifest.resources.count) ressource(s), aucun changement dans Photos."
        } catch is CancellationError {
            phase = .paused
            ColdShotLog.archive.notice("Single asset archive cancelled; asset=\(candidate.id, privacy: .public)")
            statusMessage = "Transfert mis en pause. L’élément en cours sera repris proprement au prochain essai."
        } catch {
            phase = .failed
            ColdShotLog.archive.error("Single asset archive failed; asset=\(candidate.id, privacy: .public) error=\(ColdShotLog.describe(error), privacy: .public)")
            statusMessage = "Échec de l’archive : \(error.localizedDescription) \(recoveryGuidance(for: error))"
        }
    }

    private func performArchiveCampaign(
        candidates: [PhotoAssetCandidate],
        cutoffDate: Date?,
        selectionFilter: InventorySelectionFilter,
        destinationURL: URL
    ) async {
        let accessStarted = destinationURL.startAccessingSecurityScopedResource()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Archivage ColdShot demandé par l’utilisateur"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            if accessStarted { destinationURL.stopAccessingSecurityScopedResource() }
            archiveTask = nil
        }

        let total = candidates.count
        ColdShotLog.archive.info("Persistent campaign requested; assets=\(total, privacy: .public) securityScope=\(accessStarted, privacy: .public)")

        do {
            let journal = try await ArchiveCampaignEngine().start(
                assets: candidates.map {
                    ArchiveCampaignAsset(assetIdentifier: $0.id, creationDate: $0.creationDate)
                },
                cutoffDate: cutoffDate,
                selectionFilter: selectionFilter,
                destination: destinationURL,
                planProvider: { [photoLibrary] identifiers, filter in
                    try await photoLibrary.prepareArchivePlans(
                        forIdentifiers: identifiers,
                        matching: filter
                    )
                },
                planRefresher: { [photoLibrary] frozenPlan in
                    try await photoLibrary.prepareArchivePlan(
                        forIdentifier: frozenPlan.assetIdentifier,
                        matching: selectionFilter
                    )
                },
                sourceFactory: { plan in
                    PhotoKitResourceSource(asset: plan, selectionFilter: selectionFilter)
                },
                onEvent: { [weak self] event in
                    guard Self.shouldForwardToInterface(event) else { return }
                    Task { @MainActor in self?.handle(campaignEvent: event) }
                }
            )

            phase = .succeeded
            progressFraction = 1
            batchCompletedAssetCount = total
            batchTotalAssetCount = total
            resumableCampaign = nil
            let archivedIdentifiers = Set(journal.assets.lazy
                .filter { $0.state == .archived }
                .map(\.asset.assetIdentifier))
            cataloguedAssetIdentifiers.formUnion(archivedIdentifiers)
            try? await archiveIndex.markArchived(archivedIdentifiers)
            changedAssetIdentifiers.subtract(archivedIdentifiers)
            rebuildSelectionCache()
            issueCampaign = journal.failedCount > 0 ? journal : nil
            unresolvedArchiveIssues = journal.assets.filter { $0.state == .failed }
            batchCompletedAssetCount = journal.processedCount
            batchProgressText = journal.failedCount == 0
                ? "Campagne terminée : \(journal.completedCount)/\(total) éléments, \(formatBytes(journal.archivedByteCount))."
                : "Transfert terminé : \(journal.completedCount) archivés, \(journal.failedCount) écart(s)."
            statusMessage = batchProgressText ?? "Campagne terminée."
            clearETA()
            ColdShotLog.archive.info("Persistent campaign completed; campaign=\(journal.identifier.uuidString, privacy: .public) assets=\(total, privacy: .public) bytes=\(journal.archivedByteCount, privacy: .public)")
            refreshArchiveState()
        } catch is CancellationError {
            let effectiveCompleted = batchCompletedAssetCount
            phase = .paused
            clearETA()
            refreshArchiveState()
            ColdShotLog.archive.notice("Persistent campaign paused; completed=\(effectiveCompleted, privacy: .public)/\(total, privacy: .public)")
            statusMessage = "Campagne en pause après \(effectiveCompleted)/\(total) éléments. Tous les éléments vérifiés sont conservés ; utilisez « Continuer »."
        } catch {
            let effectiveCompleted = batchCompletedAssetCount
            let toleranceReached = (error as? BatchArchiveError).map {
                if case .failureToleranceReached = $0 { return true }
                return false
            } ?? false
            phase = toleranceReached ? .paused : .failed
            clearETA()
            refreshArchiveState()
            ColdShotLog.archive.error("Persistent campaign failed; completed=\(effectiveCompleted, privacy: .public)/\(total, privacy: .public) error=\(ColdShotLog.describe(error), privacy: .public)")
            statusMessage = toleranceReached
                ? "10 écarts ont été enregistrés. Le transfert est en pause de sécurité ; examinez-les puis utilisez « Réessayer les écarts »."
                : "Le transfert s’est arrêté après \(effectiveCompleted)/\(total) éléments. Les éléments vérifiés sont conservés ; exportez le rapport avant de continuer."
        }
    }

    private func performCampaignResume(
        identifier: UUID,
        selectionFilter: InventorySelectionFilter?,
        destinationURL: URL,
        retryFailures: Bool = false
    ) async {
        let accessStarted = destinationURL.startAccessingSecurityScopedResource()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Reprise d’une campagne ColdShot"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            if accessStarted { destinationURL.stopAccessingSecurityScopedResource() }
            archiveTask = nil
        }

        do {
            let planProvider: ArchiveCampaignEngine.PlanProvider = { [photoLibrary] identifiers, filter in
                    try await photoLibrary.prepareArchivePlans(
                        forIdentifiers: identifiers,
                        matching: filter
                    )
                }
            let planRefresher: BatchArchiveEngine.PlanRefresher = { [photoLibrary] frozenPlan in
                    try await photoLibrary.prepareArchivePlan(
                        forIdentifier: frozenPlan.assetIdentifier,
                        matching: selectionFilter
                    )
                }
            let sourceFactory: BatchArchiveEngine.SourceFactory = { plan in
                    PhotoKitResourceSource(asset: plan, selectionFilter: selectionFilter)
                }
            let eventHandler: ArchiveCampaignEngine.EventHandler = { [weak self] event in
                    guard Self.shouldForwardToInterface(event) else { return }
                    Task { @MainActor in self?.handle(campaignEvent: event) }
                }
            let engine = ArchiveCampaignEngine()
            let journal: ArchiveCampaignJournal
            if retryFailures {
                journal = try await engine.retryFailures(
                    campaignIdentifier: identifier,
                    destination: destinationURL,
                    planProvider: planProvider,
                    planRefresher: planRefresher,
                    sourceFactory: sourceFactory,
                    onEvent: eventHandler
                )
            } else {
                journal = try await engine.resume(
                    campaignIdentifier: identifier,
                    destination: destinationURL,
                    planProvider: planProvider,
                    planRefresher: planRefresher,
                    sourceFactory: sourceFactory,
                    onEvent: eventHandler
                )
            }
            resumableCampaign = nil
            let archivedIdentifiers = Set(journal.assets.lazy
                .filter { $0.state == .archived }
                .map(\.asset.assetIdentifier))
            cataloguedAssetIdentifiers.formUnion(archivedIdentifiers)
            try? await archiveIndex.markArchived(archivedIdentifiers)
            changedAssetIdentifiers.subtract(archivedIdentifiers)
            rebuildSelectionCache()
            phase = .succeeded
            batchCompletedAssetCount = journal.processedCount
            batchTotalAssetCount = journal.assets.count
            progressFraction = 1
            issueCampaign = journal.failedCount > 0 ? journal : nil
            unresolvedArchiveIssues = journal.assets.filter { $0.state == .failed }
            batchProgressText = journal.failedCount == 0
                ? "Campagne terminée : \(journal.completedCount)/\(journal.assets.count) éléments, \(formatBytes(journal.archivedByteCount))."
                : "Transfert terminé : \(journal.completedCount) archivés, \(journal.failedCount) écart(s)."
            statusMessage = batchProgressText ?? "Campagne terminée."
            clearETA()
            ColdShotLog.archive.info("Persistent campaign resume completed; campaign=\(identifier.uuidString, privacy: .public) assets=\(journal.assets.count, privacy: .public)")
            refreshArchiveState()
        } catch is CancellationError {
            phase = .paused
            clearETA()
            refreshArchiveState()
            statusMessage = "Campagne en pause. Tous les éléments vérifiés sont conservés ; utilisez « Continuer »."
            ColdShotLog.archive.notice("Persistent campaign resume paused; campaign=\(identifier.uuidString, privacy: .public)")
        } catch {
            let toleranceReached = (error as? BatchArchiveError).map {
                if case .failureToleranceReached = $0 { return true }
                return false
            } ?? false
            phase = toleranceReached ? .paused : .failed
            clearETA()
            refreshArchiveState()
            statusMessage = toleranceReached
                ? "10 écarts ont été enregistrés. La campagne est en pause de sécurité ; utilisez « Réessayer les écarts »."
                : "La reprise s’est arrêtée. Les éléments vérifiés sont conservés ; exportez le rapport avant de continuer."
            ColdShotLog.archive.error("Persistent campaign resume failed; campaign=\(identifier.uuidString, privacy: .public) error=\(ColdShotLog.describe(error), privacy: .public)")
        }
    }

    private func performBatchResume(
        identifier: UUID,
        selectionFilter: InventorySelectionFilter?,
        destinationURL: URL
    ) async {
        await runBatch(destinationURL: destinationURL) {
            try await BatchArchiveEngine().resume(
                jobIdentifier: identifier,
                destination: destinationURL,
                planRefresher: { [photoLibrary] frozenPlan in
                    try await photoLibrary.prepareArchivePlan(
                        forIdentifier: frozenPlan.assetIdentifier,
                        matching: selectionFilter
                    )
                },
                sourceFactory: { plan in
                    PhotoKitResourceSource(asset: plan, selectionFilter: selectionFilter)
                },
                onEvent: { [weak self] event in
                    guard Self.shouldForwardToInterface(event) else { return }
                    Task { @MainActor in self?.handle(batchEvent: event) }
                }
            )
        }
    }

    private func runBatch(
        destinationURL: URL,
        operation: () async throws -> BatchArchiveJournal
    ) async {
        let accessStarted = destinationURL.startAccessingSecurityScopedResource()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Reprise d’un archivage ColdShot"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            if accessStarted { destinationURL.stopAccessingSecurityScopedResource() }
            archiveTask = nil
        }

        do {
            let journal = try await operation()
            resumableBatch = journal.isComplete ? nil : journal
            latestCompletedBatch = journal.isComplete ? journal : latestCompletedBatch
            cataloguedAssetIdentifiers.formUnion(
                journal.assets.lazy.filter { $0.state == .archived }.map(\.asset.assetIdentifier)
            )
            let archivedIdentifiers = Set(
                journal.assets.lazy.filter { $0.state == .archived }.map(\.asset.assetIdentifier)
            )
            try? await archiveIndex.markArchived(archivedIdentifiers)
            changedAssetIdentifiers.subtract(archivedIdentifiers)
            rebuildSelectionCache()
            phase = .succeeded
            clearETA()
            progressFraction = 1
            batchCompletedAssetCount = journal.completedCount
            batchTotalAssetCount = journal.assets.count
            batchProgressText = "Lot terminé : \(journal.completedCount)/\(journal.assets.count) assets, \(formatBytes(journal.archivedByteCount))."
            statusMessage = batchProgressText ?? "Lot terminé."
            ColdShotLog.archive.info("Resumed batch completed; job=\(journal.identifier.uuidString, privacy: .public) completed=\(journal.completedCount, privacy: .public)/\(journal.assets.count, privacy: .public) bytes=\(journal.archivedByteCount, privacy: .public)")
        } catch is CancellationError {
            phase = .paused
            clearETA()
            refreshArchiveState()
            ColdShotLog.archive.notice("Resumed batch cancelled")
            statusMessage = "Transfert en pause. Le journal permet de continuer sans recommencer les éléments vérifiés."
        } catch {
            phase = .failed
            clearETA()
            refreshArchiveState()
            ColdShotLog.archive.error("Resumed batch failed; error=\(ColdShotLog.describe(error), privacy: .public)")
            statusMessage = "Échec du lot : \(error.localizedDescription) \(recoveryGuidance(for: error))"
        }
    }

    private func performBatchVerification(identifier: UUID, destinationURL: URL) async {
        let accessStarted = destinationURL.startAccessingSecurityScopedResource()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Vérification d’une archive ColdShot"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            if accessStarted { destinationURL.stopAccessingSecurityScopedResource() }
            archiveTask = nil
        }

        do {
            let journal = try await BatchArchiveEngine().verify(
                jobIdentifier: identifier,
                destination: destinationURL,
                onEvent: { [weak self] event in
                    Task { @MainActor in self?.handle(verificationEvent: event) }
                }
            )
            phase = .succeeded
            batchCompletedAssetCount = journal.assets.count
            batchTotalAssetCount = journal.assets.count
            progressFraction = 1
            statusMessage = "Dernier lot vérifié : \(journal.assets.count) assets, tous les fichiers et SHA-256 sont valides."
            ColdShotLog.archive.info("Batch verification completed; job=\(journal.identifier.uuidString, privacy: .public) assets=\(journal.assets.count, privacy: .public) bytes=\(journal.archivedByteCount, privacy: .public)")
        } catch is CancellationError {
            phase = .paused
            ColdShotLog.archive.notice("Batch verification cancelled; job=\(identifier.uuidString, privacy: .public)")
            statusMessage = "Vérification du lot annulée. Aucune archive n’a été modifiée."
        } catch {
            phase = .failed
            ColdShotLog.archive.error("Batch verification failed; job=\(identifier.uuidString, privacy: .public) error=\(ColdShotLog.describe(error), privacy: .public)")
            statusMessage = "Échec de la vérification du dernier lot : \(error.localizedDescription)"
        }
    }

    private func refreshArchiveState() {
        archiveStateTask?.cancel()
        guard let destinationURL else {
            resumableCampaign = nil
            resumableBatch = nil
            latestCompletedBatch = nil
            archiveHistory = []
            issueCampaign = nil
            unresolvedArchiveIssues = []
            cataloguedAssetIdentifiers = []
            isRefreshingArchiveCatalog = false
            archiveStateTask = nil
            return
        }
        let expectedDestination = destinationURL.standardizedFileURL
        guard destinationIsReachable else {
            isRefreshingArchiveCatalog = false
            archiveStateTask = nil
            return
        }
        isRefreshingArchiveCatalog = true
        archiveStateTask = Task { [weak self] in
            guard let self else { return }
            let accessStarted = destinationURL.startAccessingSecurityScopedResource()
            defer { if accessStarted { destinationURL.stopAccessingSecurityScopedResource() } }
            let batchEngine = BatchArchiveEngine()
            let campaignEngine = ArchiveCampaignEngine()
            let archiveEngine = ArchiveEngine()
            let campaign: ArchiveCampaignJournal?
            do {
                campaign = try await campaignEngine.latestIncompleteCampaign(destination: destinationURL)
            } catch {
                campaign = nil
                ColdShotLog.archive.error("Failed to read incomplete campaign journal; error=\(ColdShotLog.describe(error), privacy: .public)")
            }
            guard !Task.isCancelled,
                  self.destinationURL?.standardizedFileURL == expectedDestination else { return }
            self.resumableCampaign = campaign

            let resumable: BatchArchiveJournal?
            do {
                resumable = campaign == nil
                    ? try await batchEngine.latestIncompleteJob(destination: destinationURL)
                    : nil
            } catch {
                resumable = nil
                ColdShotLog.archive.error("Failed to read incomplete batch journal; error=\(ColdShotLog.describe(error), privacy: .public)")
            }
            guard !Task.isCancelled,
                  self.destinationURL?.standardizedFileURL == expectedDestination else { return }
            self.resumableBatch = resumable

            let completed: BatchArchiveJournal?
            do {
                completed = try await batchEngine.latestCompletedJob(destination: destinationURL)
            } catch {
                completed = nil
                ColdShotLog.archive.error("Failed to read completed batch journal; error=\(ColdShotLog.describe(error), privacy: .public)")
            }
            guard !Task.isCancelled,
                  self.destinationURL?.standardizedFileURL == expectedDestination else { return }
            self.latestCompletedBatch = completed

            do {
                self.archiveHistory = try await campaignEngine.campaignHistory(
                    destination: destinationURL,
                    limit: 5
                )
            } catch {
                self.archiveHistory = []
                ColdShotLog.archive.error("Failed to read campaign history; error=\(ColdShotLog.describe(error), privacy: .public)")
            }

            do {
                let finishedWithIssues = try await campaignEngine.latestCampaignWithIssues(
                    destination: destinationURL
                )
                self.issueCampaign = (campaign?.failedCount ?? 0) > 0 ? campaign : finishedWithIssues
                self.unresolvedArchiveIssues = try await campaignEngine.unresolvedFailureRecords(
                    destination: destinationURL
                )
            } catch {
                self.issueCampaign = (campaign?.failedCount ?? 0) > 0 ? campaign : nil
                self.unresolvedArchiveIssues = campaign?.assets.filter { $0.state == .failed } ?? []
                ColdShotLog.archive.error("Failed to read persistent archive issues; error=\(ColdShotLog.describe(error), privacy: .public)")
            }

            do {
                let cataloguedIdentifiers = try await archiveEngine.cataloguedAssetIdentifiers(
                    destination: destinationURL
                )
                guard !Task.isCancelled,
                      self.destinationURL?.standardizedFileURL == expectedDestination else { return }
                self.cataloguedAssetIdentifiers = cataloguedIdentifiers
                try await self.archiveIndex.replaceArchivedIdentifiers(cataloguedIdentifiers)
            } catch {
                ColdShotLog.archive.error("Failed to refresh archive catalog; error=\(ColdShotLog.describe(error), privacy: .public)")
                ColdShotLog.diagnostic(category: "Destination", level: "ERROR", message: "Archive catalog refresh failed; local archive state preserved; error=\(ColdShotLog.describe(error))")
            }
            self.rebuildSelectionCache()
            self.isRefreshingArchiveCatalog = false
        }
    }

    private func refreshDestinationCapacity() {
        guard let destinationURL else {
            destinationAvailableByteCount = nil
            destinationCapacityState = .unavailable
            destinationIsReachable = false
            return
        }
        let accessStarted = destinationURL.startAccessingSecurityScopedResource()
        defer { if accessStarted { destinationURL.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: destinationURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            destinationAvailableByteCount = nil
            destinationCapacityState = .unavailable
            destinationIsReachable = false
            return
        }
        destinationIsReachable = true
        do {
            let values = try destinationURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeIsLocalKey]
            )
            destinationAvailableByteCount = values.volumeAvailableCapacityForImportantUsage
            if values.volumeIsLocal == true {
                destinationCapacityState = .local(availableBytes: destinationAvailableByteCount)
            } else if values.volumeIsLocal == false {
                destinationCapacityState = .remote(reportedAvailableBytes: destinationAvailableByteCount)
            } else {
                destinationCapacityState = .unknown
            }
        } catch {
            destinationAvailableByteCount = nil
            destinationCapacityState = .unknown
            ColdShotLog.workflow.notice("Destination reachable but capacity unavailable; error=\(ColdShotLog.describe(error), privacy: .public)")
        }
    }

    private func monthKey(for date: Date) -> InventoryMonthKey {
        let calendar = Calendar.current
        return InventoryMonthKey(
            year: calendar.component(.year, from: date),
            month: calendar.component(.month, from: date)
        )
    }

    private func handle(campaignEvent: ArchiveCampaignEvent) {
        switch campaignEvent {
        case .started(let identifier, let assetCount, let completedCount):
            phase = .archiving
            batchCompletedAssetCount = completedCount
            batchTotalAssetCount = assetCount
            progressFraction = batchProgress
            batchProgressText = "Archivage : \(completedCount)/\(assetCount) éléments terminés."
            statusMessage = batchProgressText ?? statusMessage
            ColdShotLog.archive.info("Persistent campaign started or resumed; campaign=\(identifier.uuidString, privacy: .public) completed=\(completedCount, privacy: .public)/\(assetCount, privacy: .public)")
        case .assetStarted(let index, let total, let assetIdentifier, let creationDate):
            currentAssetDate = creationDate
            currentAssetStartedAt = Date()
            ColdShotLog.archive.info("Campaign asset started; asset=\(assetIdentifier, privacy: .public) globalIndex=\(index, privacy: .public)/\(total, privacy: .public)")
            let diagnosticDate = creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
            ColdShotLog.diagnostic(category: "Archive", level: "INFO", message: "Asset started; id=\(assetIdentifier.prefix(12)) index=\(index)/\(total) date=\(diagnosticDate)")
            if let creationDate {
                statusMessage = "Élément du \(creationDate.formatted(date: .abbreviated, time: .omitted)) en cours — \(batchCompletedAssetCount)/\(total) terminés."
            } else {
                statusMessage = "Élément sans date en cours — \(batchCompletedAssetCount)/\(total) terminés."
            }
        case .assetRetrying(let index, let total, let assetIdentifier, let attempt, let message):
            currentAssetStartedAt = Date()
            ColdShotLog.archive.notice("Campaign asset retry; asset=\(assetIdentifier, privacy: .public) globalIndex=\(index, privacy: .public)/\(total, privacy: .public) attempt=\(attempt, privacy: .public) error=\(message, privacy: .public)")
            ColdShotLog.diagnostic(category: "Archive", level: "NOTICE", message: "Asset retry; id=\(assetIdentifier.prefix(12)) index=\(index)/\(total) attempt=\(attempt) error=\(message)")
            statusMessage = "Nouvelle tentative automatique pour l’élément \(index)/\(total)…"
        case .archiveEvent(let assetIdentifier, let event):
            logArchiveDetail(assetIdentifier: assetIdentifier, event: event)
        case .assetCompleted(let index, let total, let assetIdentifier, let byteCount):
            batchCompletedAssetCount = min(batchCompletedAssetCount + 1, total)
            batchTotalAssetCount = total
            if let currentAssetStartedAt {
                timeEstimator.recordAssetDuration(Date().timeIntervalSince(currentAssetStartedAt))
                refreshDisplayedETA()
            }
            currentAssetStartedAt = nil
            progressFraction = batchProgress
            batchProgressText = "\(batchCompletedAssetCount)/\(total) éléments terminés."
            statusMessage = batchProgressText ?? statusMessage
            ColdShotLog.archive.info("Campaign asset completed and verified; asset=\(assetIdentifier, privacy: .public) globalIndex=\(index, privacy: .public)/\(total, privacy: .public) bytes=\(byteCount, privacy: .public)")
            ColdShotLog.diagnostic(category: "Archive", level: "INFO", message: "Asset verified; id=\(assetIdentifier.prefix(12)) index=\(index)/\(total) bytes=\(byteCount)")
        case .assetFailed(let index, let total, let assetIdentifier, let message):
            currentAssetStartedAt = nil
            batchCompletedAssetCount = min(batchCompletedAssetCount + 1, total)
            batchTotalAssetCount = total
            progressFraction = batchProgress
            ColdShotLog.archive.error("Campaign asset failed; asset=\(assetIdentifier, privacy: .public) globalIndex=\(index, privacy: .public)/\(total, privacy: .public) error=\(message, privacy: .public)")
            ColdShotLog.diagnostic(category: "Archive", level: "ERROR", message: "Asset failed; id=\(assetIdentifier.prefix(12)) index=\(index)/\(total) error=\(message)")
            statusMessage = "Écart enregistré sur l’élément \(index)/\(total) ; le transfert poursuit les autres éléments."
        case .checkpoint(let completedCount, let total):
            batchCompletedAssetCount = completedCount
            batchTotalAssetCount = total
            progressFraction = batchProgress
            ColdShotLog.archive.info("Campaign checkpoint committed; completed=\(completedCount, privacy: .public)/\(total, privacy: .public)")
        case .completed(let identifier, let byteCount):
            progressFraction = 1
            batchCompletedAssetCount = batchTotalAssetCount
            clearETA()
            ColdShotLog.archive.info("Campaign journal completed; campaign=\(identifier.uuidString, privacy: .public) bytes=\(byteCount, privacy: .public)")
        case .completedWithIssues(let identifier, let byteCount, let failedCount):
            progressFraction = 1
            batchCompletedAssetCount = batchTotalAssetCount
            clearETA()
            statusMessage = "Transfert terminé avec \(failedCount) écart(s) à résoudre."
            ColdShotLog.archive.notice("Campaign completed with issues; campaign=\(identifier.uuidString, privacy: .public) failed=\(failedCount, privacy: .public) bytes=\(byteCount, privacy: .public)")
        }
    }

    private func handle(
        batchEvent: BatchArchiveEvent,
        completedOffset: Int = 0,
        overallTotal: Int? = nil
    ) {
        switch batchEvent {
        case .started(let jobIdentifier, let assetCount, let completedCount):
            ColdShotLog.archive.info("Batch started; job=\(jobIdentifier.uuidString, privacy: .public) assets=\(assetCount, privacy: .public) alreadyCompleted=\(completedCount, privacy: .public)")
            batchCompletedAssetCount = completedOffset + completedCount
            batchTotalAssetCount = overallTotal ?? assetCount
            progressFraction = batchProgress
            batchProgressText = "Archivage : \(batchCompletedAssetCount)/\(batchTotalAssetCount) assets terminés."
        case .assetStarted(let index, let total, let assetIdentifier):
            ColdShotLog.archive.info("Asset started; asset=\(assetIdentifier, privacy: .public) batchIndex=\(index, privacy: .public)/\(total, privacy: .public) globalIndex=\(completedOffset + index, privacy: .public)/\(overallTotal ?? total, privacy: .public)")
            let globalIndex = completedOffset + index
            batchProgressText = "Asset \(globalIndex)/\(overallTotal ?? total) en cours — \(batchCompletedAssetCount)/\(batchTotalAssetCount) terminés."
        case .assetRetrying(let index, let total, let assetIdentifier, let attempt, let message):
            ColdShotLog.archive.notice("Asset retry; asset=\(assetIdentifier, privacy: .public) batchIndex=\(index, privacy: .public)/\(total, privacy: .public) attempt=\(attempt, privacy: .public) error=\(message, privacy: .public)")
            batchProgressText = "Nouvelle tentative automatique pour l’élément \(completedOffset + index)/\(overallTotal ?? total)…"
        case .archiveEvent(let assetIdentifier, let event):
            logArchiveDetail(assetIdentifier: assetIdentifier, event: event)
            handleBatchDetail(event: event)
        case .assetCompleted(let index, let total, let assetIdentifier, let byteCount):
            ColdShotLog.archive.info("Asset completed and verified; asset=\(assetIdentifier, privacy: .public) batchIndex=\(index, privacy: .public)/\(total, privacy: .public) bytes=\(byteCount, privacy: .public)")
            batchCompletedAssetCount = completedOffset + index
            batchTotalAssetCount = overallTotal ?? total
            progressFraction = batchProgress
            batchProgressText = "\(batchCompletedAssetCount)/\(batchTotalAssetCount) assets terminés — dernier asset : \(formatBytes(byteCount))."
            statusMessage = batchProgressText ?? statusMessage
        case .assetFailed(let index, let total, let assetIdentifier, let message):
            ColdShotLog.archive.error("Asset failed; asset=\(assetIdentifier, privacy: .public) batchIndex=\(index, privacy: .public)/\(total, privacy: .public) globalIndex=\(completedOffset + index, privacy: .public)/\(overallTotal ?? total, privacy: .public) error=\(message, privacy: .public)")
            batchProgressText = "Le transfert nécessite une action sur l’élément \(completedOffset + index)/\(overallTotal ?? total)."
            statusMessage = batchProgressText ?? statusMessage
        case .completed(let jobIdentifier, let byteCount):
            ColdShotLog.archive.info("Batch completed; job=\(jobIdentifier.uuidString, privacy: .public) bytes=\(byteCount, privacy: .public)")
            batchProgressText = "Sous-lot vérifié — \(formatBytes(byteCount))."
            statusMessage = batchProgressText ?? statusMessage
        case .completedWithIssues(let jobIdentifier, let byteCount, let failedCount):
            ColdShotLog.archive.notice("Batch completed with issues; job=\(jobIdentifier.uuidString, privacy: .public) failed=\(failedCount, privacy: .public) bytes=\(byteCount, privacy: .public)")
            batchProgressText = "Sous-lot terminé avec \(failedCount) écart(s)."
            statusMessage = batchProgressText ?? statusMessage
        }
    }

    private func handle(verificationEvent: BatchVerificationEvent) {
        switch verificationEvent {
        case .started(_, let assetCount):
            batchCompletedAssetCount = 0
            batchTotalAssetCount = assetCount
            progressFraction = batchProgress
            batchProgressText = "Vérification : 0/\(assetCount) assets."
        case .assetVerified(let index, let total, _):
            batchCompletedAssetCount = index
            batchTotalAssetCount = total
            progressFraction = batchProgress
            batchProgressText = "Vérification : \(index)/\(total) assets."
            statusMessage = batchProgressText ?? statusMessage
        case .completed(_, let byteCount):
            batchProgressText = "Lot vérifié — \(formatBytes(byteCount))."
        }
    }

    private var batchProgress: Double {
        Double(batchCompletedAssetCount) / Double(max(batchTotalAssetCount, 1))
    }

    private func refreshDisplayedETA(now: Date = Date()) {
        guard let raw = timeEstimator.estimatedRemainingTime(
            forRemainingAssetCount: max(batchTotalAssetCount - batchCompletedAssetCount, 0)
        ) else { return }
        if let lastETARefreshDate, now.timeIntervalSince(lastETARefreshDate) < 60 { return }
        let interval: TimeInterval = raw >= 3_600 ? 600 : (raw >= 600 ? 300 : 60)
        let rounded = max((raw / interval).rounded() * interval, 60)
        if let previous = displayedEstimatedRemainingDuration {
            let meaningfulChange = max(previous * 0.1, interval)
            guard abs(previous - rounded) >= meaningfulChange else {
                self.lastETARefreshDate = now
                return
            }
        }
        displayedEstimatedRemainingDuration = rounded
        lastETARefreshDate = now
    }

    private func clearETA() {
        displayedEstimatedRemainingDuration = nil
        lastETARefreshDate = nil
        currentAssetStartedAt = nil
    }

    nonisolated private static func shouldForwardToInterface(_ event: ArchiveEvent) -> Bool {
        if case .resourceBytes = event { return false }
        return true
    }

    nonisolated private static func shouldForwardToInterface(_ event: ArchiveCampaignEvent) -> Bool {
        if case .archiveEvent(_, .resourceBytes) = event { return false }
        return true
    }

    nonisolated private static func shouldForwardToInterface(_ event: BatchArchiveEvent) -> Bool {
        if case .archiveEvent(_, .resourceBytes) = event { return false }
        return true
    }

    private func handleBatchDetail(event: ArchiveEvent) {
        switch event {
        case .started(let resourceCount):
            statusMessage = "Asset en cours : \(resourceCount) ressource(s)."
        case .resourceStarted(let index, let total, let filename):
            statusMessage = "Asset en cours — ressource \(index)/\(total) : \(filename)"
        case .resourceBytes(_, let byteCount):
            statusMessage = "Asset en cours — \(formatBytes(byteCount)) transférés ; \(batchCompletedAssetCount)/\(batchTotalAssetCount) assets terminés."
        case .resourceVerified(let index, let total, let filename):
            statusMessage = "Asset en cours — ressource \(index)/\(total) vérifiée : \(filename)"
        case .completed(let manifestRelativePath):
            lastManifestPath = manifestRelativePath
        }
    }

    private func logArchiveDetail(assetIdentifier: String, event: ArchiveEvent) {
        switch event {
        case .started(let resourceCount):
            ColdShotLog.archive.debug("Asset resource archive started; asset=\(assetIdentifier, privacy: .public) resources=\(resourceCount, privacy: .public)")
        case .resourceStarted(let index, let total, let filename):
            ColdShotLog.archive.debug("Resource transfer started; asset=\(assetIdentifier, privacy: .public) index=\(index, privacy: .public)/\(total, privacy: .public) filename=\(filename, privacy: .private)")
        case .resourceBytes:
            break
        case .resourceVerified(let index, let total, let filename):
            ColdShotLog.archive.debug("Resource verified; asset=\(assetIdentifier, privacy: .public) index=\(index, privacy: .public)/\(total, privacy: .public) filename=\(filename, privacy: .private)")
        case .completed(let manifestRelativePath):
            ColdShotLog.archive.debug("Asset manifest committed; asset=\(assetIdentifier, privacy: .public) manifest=\(manifestRelativePath, privacy: .private)")
        }
    }

    private func formatBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func recoveryGuidance(for error: any Error) -> String {
        if let archiveError = error as? ArchiveError {
            switch archiveError {
            case .existingArchiveInvalid, .existingFileConflict, .manifestConflict:
                return "L’archive existante doit être inspectée ou mise en quarantaine ; ColdShot ne l’écrasera pas. Ne reprenez le lot qu’après avoir corrigé cette incohérence."
            default:
                return "Vérifiez l’état et la capacité de la destination, puis utilisez « Reprendre »."
            }
        }
        if error is BatchArchiveError {
            return "Le journal ou son manifeste doit être inspecté avant toute reprise ; démarrez un nouveau lot seulement après avoir conservé ce diagnostic."
        }
        guard let photoError = error as? PhotoLibraryError else {
            return "Corrigez la cause indiquée, puis utilisez « Reprendre »."
        }
        switch photoError {
        case .resourceInventoryChanged:
            return "Photos a changé pendant ce transfert. Utilisez « Continuer » : ColdShot rafraîchira cet élément avant de le reprendre."
        case .assetUnavailable, .sourceHasNoResources, .assetNoLongerMatchesSelection:
            return "Cet élément n’est plus archivable avec la sélection actuelle. Relancez l’analyse pour confirmer son nouvel état."
        case .libraryUnavailable:
            return "Rendez la photothèque de nouveau disponible, puis utilisez « Reprendre »."
        case .authorizationRequired:
            return "Rétablissez l’accès Photos, puis utilisez « Reprendre »."
        case .resourceConsumerFailed:
            return "Vérifiez la destination, puis utilisez « Reprendre »."
        }
    }

    private func handle(event: ArchiveEvent) {
        switch event {
        case .started(let resourceCount):
            statusMessage = "Archivage de \(resourceCount) ressource(s)…"
        case .resourceStarted(let index, let total, let filename):
            progressFraction = Double(index - 1) / Double(max(total, 1))
            statusMessage = "Ressource \(index)/\(total) : \(filename)"
        case .resourceBytes(_, let byteCount):
            statusMessage = "Transfert : \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))"
        case .resourceVerified(let index, let total, let filename):
            progressFraction = Double(index) / Double(max(total, 1))
            statusMessage = "Vérifiée \(index)/\(total) : \(filename)"
        case .completed(let manifestRelativePath):
            lastManifestPath = manifestRelativePath
        }
    }
}
