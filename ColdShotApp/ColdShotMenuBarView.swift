import AppKit
import SwiftUI

struct ColdShotMenuBarView: View {
    @Bindable var model: SprintZeroModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.menuBarTitle, systemImage: model.menuBarSystemImage)
                    .font(.headline)
                Spacer()
            }

            if model.canPauseArchive || model.isPausingArchive
                || model.resumableTotalCount > 0 || model.canRetryArchiveIssues {
                ProgressView(value: model.progressFraction ?? 0)
                HStack {
                    Text("\(model.batchCompletedAssetCount)/\(model.batchTotalAssetCount) traités")
                        .monospacedDigit()
                    Spacer()
                    if let eta = model.estimatedRemainingText, model.canPauseArchive {
                        Text(eta)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let date = model.currentAssetDate, model.canPauseArchive {
                    Text("Élément du \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout)
                }
            } else {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            HStack {
                if model.canPauseArchive {
                    Button("Mettre en pause") { model.pauseArchive() }
                } else if model.canRetryArchiveIssues {
                    Button("Réessayer les écarts") { model.retryArchiveIssues() }
                } else if model.resumableTotalCount > 0 {
                    Button("Continuer") { model.resumeBatchArchive() }
                        .disabled(!model.canResumeBatch)
                }
                Spacer()
                Button("Ouvrir ColdShot") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
