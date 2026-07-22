import ColdShotCore
import SwiftUI

struct SprintZeroView: View {
    @Bindable var model: SprintZeroModel
    @State private var expandedYear: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                overviewPanel
                archivePanel
                if !model.archiveHistory.isEmpty {
                    historyPanel
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "archivebox.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 6) {
                Text("ColdShot — MVP 1")
                    .font(.largeTitle.bold())
                Text("Archive vérifiée de votre photothèque vers un stockage local ou un NAS.")
                    .foregroundStyle(.secondary)
                Label("Aucune suppression dans Photos", systemImage: "lock.shield.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var overviewPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Accès Photos")
                            .font(.headline)
                        Text(model.authorizationLabel)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.authorizationStatus == .notDetermined
                        || model.authorizationStatus == .denied {
                        Button("Autoriser Photos") {
                            Task { await model.requestPhotosAccess() }
                        }
                        .disabled(model.isWorking)
                    }
                }

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "externaldrive.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Destination")
                            .font(.headline)
                        Text(model.destinationURL?.path(percentEncoded: false) ?? "Aucun dossier sélectionné")
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if let message = model.destinationCapacityMessage {
                            Label(message, systemImage: model.destinationCapacityIsWarning
                                ? "exclamationmark.triangle.fill" : "externaldrive")
                                .font(.caption)
                                .foregroundStyle(model.destinationCapacityIsWarning ? .red : .secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button(model.destinationURL == nil ? "Choisir…" : "Changer…") {
                        model.chooseDestination()
                    }
                    .disabled(model.isWorking)
                }

                if model.destinationURL != nil, !model.destinationIsReachable {
                    HStack {
                        Label("Destination indisponible", systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Tester la destination") { model.recheckDestination() }
                            .disabled(model.isWorking)
                    }
                }

                if let message = model.libraryAvailabilityMessage {
                    Label(message, systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.red)
                }

                Divider()

                if let report = model.inventoryReport {
                    HStack(spacing: 24) {
                        SummaryMetric(title: "Éléments indexés", value: report.totalAssetCount.formatted(), systemImage: "photo.stack")
                        SummaryMetric(title: "Années", value: report.years.count.formatted(), systemImage: "calendar")
                        SummaryMetric(title: "Sans date", value: report.undatedAssetCount.formatted(), systemImage: "questionmark.circle")
                        if let lastSync = model.lastPhotoSyncDate {
                            SummaryMetric(
                                title: "Dernière mise à jour",
                                value: lastSync.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                        Spacer(minLength: 16)
                        libraryActions
                    }
                } else {
                    HStack {
                        Text("La photothèque sera indexée automatiquement dès que Photos sera accessible.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        libraryActions
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        label: {
            Label("Accès et photothèque", systemImage: "square.stack.3d.up.fill")
                .font(.headline)
        }
    }

    private var libraryActions: some View {
        HStack {
            if model.isSynchronizingLibrary {
                ProgressView().controlSize(.small)
                Text("Mise à jour…").foregroundStyle(.secondary)
            }
            Button("Actualiser") { Task { await model.synchronizeLibrary() } }
                .disabled(model.isWorking || !model.canScan)
            Button("Vérifier tout") { Task { await model.synchronizeLibrary(forceFullScan: true) } }
                .disabled(model.isWorking || !model.canScan)
        }
        .controlSize(.small)
    }

    private var archivePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Mode", selection: $model.archiveMode) {
                    ForEach(SprintZeroModel.ArchiveMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.archiveMode) { model.filtersDidChange() }
                .disabled(model.isWorking)

                archiveGoal

                if model.isRefreshingArchiveCatalog {
                    archiveCatalogVerification
                } else if showsProgress {
                    progressSummary
                }

                actionBar

                Label(model.statusMessage, systemImage: model.statusSymbol)
                    .foregroundStyle(model.phase == .failed ? .red : .secondary)
                    .textSelection(.enabled)

                Divider()
                selectionSummary

                switch model.archiveMode {
                case .automatic:
                    automaticConfiguration
                case .customRange:
                    customRangeConfiguration
                }

                if !model.unresolvedArchiveIssues.isEmpty {
                    archiveIssues
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        label: {
            Label("Archivage", systemImage: "arrow.down.doc.fill")
                .font(.headline)
        }
    }

    private var archiveGoal: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.isRefreshingArchiveCatalog
                ? "arrow.triangle.2.circlepath" : model.statusSymbol)
                .font(.title2)
                .foregroundStyle(model.isRefreshingArchiveCatalog
                    ? Color.blue
                    : (model.phase == .failed ? Color.red : Color.accentColor))
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 4) {
                Text(archiveGoalTitle)
                    .font(.title2.bold())
                Text(model.archiveModeDescription)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var archiveGoalTitle: String {
        if model.isRefreshingArchiveCatalog {
            return "Vérification des archives en cours…"
        }
        return switch model.phase {
        case .preparingArchive: "Préparation de la sauvegarde…"
        case .archiving: "Sauvegarde en cours…"
        case .pausing: "Mise en pause après l’élément courant…"
        case .paused: "Sauvegarde en pause"
        case .succeeded: "Dernière sauvegarde terminée"
        case .failed: "Sauvegarde interrompue"
        default: model.archiveMode == .automatic ? "Objectif de sauvegarde" : "Période à sauvegarder"
        }
    }

    private var showsProgress: Bool {
        switch model.phase {
        case .preparingArchive, .archiving, .pausing, .paused: true
        default: model.resumableTotalCount > 0
        }
    }

    private var archiveCatalogVerification: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView()
                .progressViewStyle(.linear)
            Label(
                "Lecture des archives NAS et mise à jour des statuts…",
                systemImage: "externaldrive.badge.checkmark"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var automaticConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choisissez le dernier mois à archiver")
                .font(.headline)

            monthlyArchiveOverview

            Divider()
            if let frontier = model.automaticCoverageFrontier {
                Label(
                    "Couverture connue jusqu’au \(frontier.formatted(date: .long, time: .omitted))",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(model.remainingEligibleCount == 0 ? .green : .secondary)
            } else {
                Label("Aucune couverture d’archive connue", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }

            if model.hasLimitedPhotosAccess {
                Label("Accès Photos limité", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }

            if model.unresolvedAutomaticChangeCount > 0 {
                Label(
                    "\(model.unresolvedAutomaticChangeCount) ancien(s) élément(s) à revérifier",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    private var monthlyArchiveOverview: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            if model.archiveYearRows.isEmpty {
                ContentUnavailableView(
                    "Aucun mois à afficher",
                    systemImage: "calendar",
                    description: Text("Actualisez la photothèque ou vérifiez l’accès accordé à Photos.")
                )
                .frame(maxWidth: .infinity)
            } else {
                periodHeader
                ForEach(model.archiveYearRows) { year in
                    yearSummaryRow(year)
                    if expandedYear == year.year {
                        ForEach(model.archiveMonthRows.filter { $0.summary.key.year == year.year }) { row in
                            monthSummaryRow(row)
                        }
                    }
                }
            }
        }
    }

    private var periodHeader: some View {
        periodColumns(period: "Année / mois", photos: "Photos", videos: "Vidéos", volume: "Volume") {
            Text("État")
        } actions: {
            Text("Actions")
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private func yearSummaryRow(_ row: SprintZeroModel.ArchiveYearRow) -> some View {
        periodColumns(
            period: String(row.year), photos: row.photoCount.formatted(),
            videos: row.videoCount.formatted(), volume: format(row.estimatedVolume)
        ) {
            ArchiveStatusLabel(state: row.state, archivedCount: row.archivedCount,
                               totalCount: row.photoCount + row.videoCount, issueCount: row.issueCount)
        } actions: {
            Button(expandedYear == row.year ? "Réduire" : "Voir les mois",
                   systemImage: expandedYear == row.year ? "chevron.up" : "chevron.down") {
                expandedYear = expandedYear == row.year ? nil : row.year
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.callout.bold())
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }

    private func monthSummaryRow(_ row: SprintZeroModel.ArchiveMonthRow) -> some View {
        periodColumns(
            period: monthName(row.summary.key.month), photos: row.summary.photoCount.formatted(),
            videos: row.summary.videoCount.formatted(), volume: format(row.summary.estimatedVolume)
        ) {
            ArchiveStatusLabel(row: row)
        } actions: {
            HStack(spacing: 6) {
                Button("Archiver jusqu’ici", systemImage: row.isSelectedForAutomaticArchive
                    ? "calendar.badge.checkmark" : "calendar.badge.plus") {
                    model.selectAutomaticCutoff(row.summary.key)
                }
                .disabled(model.isWorking)
                Button("Afficher", systemImage: "folder") { model.revealArchiveMonth(row.summary.key) }
                    .disabled(row.archivedCount == 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.leading, 20)
        .padding(.trailing, 8)
    }

    private func periodColumns<Status: View, Actions: View>(
        period: String, photos: String, videos: String, volume: String,
        @ViewBuilder status: () -> Status,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            Text(period).frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
            Text(photos).monospacedDigit().frame(width: 70, alignment: .trailing)
            Text(videos).monospacedDigit().frame(width: 70, alignment: .trailing)
            Text(volume).frame(width: 150, alignment: .trailing)
            status().frame(width: 155, alignment: .leading)
            actions().frame(minWidth: 260, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customRangeConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Période à archiver")
                .font(.headline)
            HStack(spacing: 18) {
                DatePicker("Du", selection: $model.manualStartDate, displayedComponents: .date)
                    .onChange(of: model.manualStartDate) { model.filtersDidChange() }
                DatePicker("Au", selection: $model.manualEndDate, displayedComponents: .date)
                    .onChange(of: model.manualEndDate) { model.filtersDidChange() }
                Spacer()
            }
            .disabled(model.isWorking)
            Text("Une période personnalisée n’avance pas automatiquement la frontière de couverture.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectionSummary: some View {
        if let run = model.archiveRunSummary {
            HStack(spacing: 28) {
                SummaryMetric(title: "À traiter", value: run.assetCount.formatted())
                SummaryMetric(title: "Photos", value: run.photoCount.formatted())
                SummaryMetric(title: "Vidéos", value: run.videoCount.formatted())
                SummaryMetric(title: "Volume estimé", value: format(run.estimatedVolume))
            }
        }

        DisclosureGroup("Options de sélection") {
            HStack(spacing: 18) {
                Toggle("Photos", isOn: $model.includeStandardPhotos)
                Toggle("Live Photos", isOn: $model.includeLivePhotos)
                Toggle("Vidéos", isOn: $model.includeVideos)
                Toggle("Favoris", isOn: $model.includeFavorites)
                Toggle("Masqués", isOn: $model.includeHidden)
            }
            .padding(.top, 8)
            .onChange(of: model.includeStandardPhotos) { model.filtersDidChange() }
            .onChange(of: model.includeLivePhotos) { model.filtersDidChange() }
            .onChange(of: model.includeVideos) { model.filtersDidChange() }
            .onChange(of: model.includeFavorites) { model.filtersDidChange() }
            .onChange(of: model.includeHidden) { model.filtersDidChange() }
            .disabled(model.isWorking)
        }
        .font(.callout)
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.canPauseArchive || model.isPausingArchive {
                Text("Archivage en cours")
                    .font(.headline)
                if let date = model.currentAssetDate {
                    Text("Élément du \(date.formatted(date: .long, time: .omitted))")
                        .font(.title3.bold())
                } else {
                    Text("Préparation du prochain élément…")
                        .foregroundStyle(.secondary)
                }
            } else if model.resumableTotalCount > 0 {
                Text("Archivage en pause")
                    .font(.headline)
            }

            ProgressView(value: model.progressFraction ?? 0)
            HStack {
                Text("\(model.batchCompletedAssetCount)/\(model.batchTotalAssetCount) éléments traités")
                    .monospacedDigit()
                Spacer()
                if let eta = model.estimatedRemainingText {
                    Text(eta)
                } else if model.canPauseArchive {
                    Text("Calcul du temps restant…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        HStack {
            if model.canPauseArchive {
                Button("Mettre en pause", systemImage: "pause.fill") {
                    model.pauseArchive()
                }
            } else if model.isPausingArchive {
                Button("Mise en pause…", systemImage: "pause.circle") {}
                    .disabled(true)
            } else if model.canRetryArchiveIssues {
                Button("Réessayer les \(model.retryableIssueCount) écart(s)", systemImage: "arrow.clockwise") {
                    model.retryArchiveIssues()
                }
                .buttonStyle(.borderedProminent)
            } else if model.resumableTotalCount > 0 {
                Button("Continuer", systemImage: "play.fill") {
                    model.resumeBatchArchive()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canResumeBatch)
            } else {
                Button(model.archiveMode == .automatic ? "Mettre l’archive à jour" : "Archiver cette période",
                       systemImage: "arrow.down.to.line") {
                    model.startBatchArchive()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartBatch)
            }

            if let completed = model.latestCompletedBatch, !model.isWorking {
                Button("Vérifier la dernière archive (\(completed.assets.count))", systemImage: "checkmark.shield") {
                    model.verifyLatestBatch()
                }
                .buttonStyle(.borderless)
                .disabled(!model.canVerifyLatestBatch)
            }

            Spacer()

            Button("Exporter le rapport…", systemImage: "doc.text") {
                model.exportDiagnosticReport()
            }
        }
    }

    private var archiveIssues: some View {
        DisclosureGroup("Écarts à résoudre (\(model.unresolvedArchiveIssues.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.unresolvedArchiveIssues.enumerated()), id: \.element.asset.assetIdentifier) { _, record in
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Date inconnue")
                                .font(.callout.bold())
                            Text(issueCategory(record.failureCategory))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let message = record.lastError {
                                Text(message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.callout)
    }

    private var historyPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.archiveHistory) { campaign in
                    HStack {
                        Image(systemName: campaign.isComplete
                            ? "checkmark.circle.fill"
                            : (campaign.isFinished ? "exclamationmark.triangle.fill" : "pause.circle.fill"))
                            .foregroundStyle(campaign.isComplete ? .green : (campaign.isFinished ? .red : .orange))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(historyDescription(campaign))
                            Text(campaign.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .font(.callout)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        label: {
            Label("Historique récent", systemImage: "clock.arrow.circlepath")
                .font(.headline)
        }
    }

    private func historyDescription(_ campaign: ArchiveCampaignSummary) -> String {
        let period: String
        if let start = campaign.earliestAssetDate, let end = campaign.latestAssetDate {
            period = "du \(start.formatted(.dateTime.month(.twoDigits).year())) au \(end.formatted(.dateTime.month(.twoDigits).year())) inclus"
        } else {
            period = "sur une période sans date exploitable"
        }
        if campaign.isComplete { return "Sauvegarde réussie \(period)" }
        if campaign.isFinished { return "Sauvegarde terminée avec \(campaign.failedCount) écart(s) \(period)" }
        return "Sauvegarde en pause \(period)"
    }

    private func format(_ estimate: InventoryVolumeEstimate) -> String {
        "\(ByteCountFormatter.string(fromByteCount: estimate.lowerBoundBytes, countStyle: .file))–\(ByteCountFormatter.string(fromByteCount: estimate.upperBoundBytes, countStyle: .file))"
    }

    private func monthName(_ month: Int) -> String {
        let symbols = Calendar.current.monthSymbols
        guard symbols.indices.contains(month - 1) else { return String(format: "%02d", month) }
        return symbols[month - 1].capitalized
    }

    private func issueCategory(_ category: ArchiveFailureCategory?) -> String {
        switch category {
        case .hashMismatch: "Hash différent"
        case .sourceChanged: "Élément modifié dans Photos"
        case .assetUnavailable: "Élément indisponible"
        case .sourceHasNoResources: "Aucune ressource exportable"
        case .selectionChanged: "Élément hors sélection"
        case .destination: "Destination"
        case .archiveConflict: "Conflit d’archive"
        case .authorization: "Autorisation Photos"
        case .photoLibrary: "Photothèque indisponible"
        case .journal: "Journal d’archive"
        case .unknown, nil: "Erreur non classée"
        }
    }
}

private struct ArchiveStatusLabel: View {
    let state: SprintZeroModel.MonthArchiveState
    let archivedCount: Int
    let totalCount: Int
    let issueCount: Int

    init(row: SprintZeroModel.ArchiveMonthRow) {
        state = row.state
        archivedCount = row.archivedCount
        totalCount = row.summary.assetCount
        issueCount = row.issueCount
    }

    init(
        state: SprintZeroModel.MonthArchiveState,
        archivedCount: Int,
        totalCount: Int,
        issueCount: Int
    ) {
        self.state = state
        self.archivedCount = archivedCount
        self.totalCount = totalCount
        self.issueCount = issueCount
    }

    var body: some View {
        Label(label, systemImage: symbol)
            .foregroundStyle(color)
            .font(.caption)
    }

    private var label: String {
        switch state {
        case .recent: "Récent"
        case .toArchive: "À archiver"
        case .verifying: "Vérification…"
        case .inProgress: "En cours"
        case .partial: "Partiel \(archivedCount)/\(totalCount)"
        case .archived: "Archivé et vérifié"
        case .attention: "\(issueCount) écart(s)"
        }
    }

    private var symbol: String {
        switch state {
        case .recent: "circle"
        case .toArchive: "archivebox"
        case .verifying: "arrow.triangle.2.circlepath"
        case .inProgress: "arrow.triangle.2.circlepath"
        case .partial: "circle.lefthalf.filled"
        case .archived: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .recent: .secondary
        case .toArchive: .orange
        case .verifying: .blue
        case .inProgress: .yellow
        case .partial: .blue
        case .archived: .green
        case .attention: .red
        }
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String
    let systemImage: String?

    init(title: String, value: String, systemImage: String? = nil) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
        }
    }
}
