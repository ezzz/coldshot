import SwiftUI

@main
struct ColdShotApp: App {
    @State private var model = SprintZeroModel()

    var body: some Scene {
        Window("ColdShot", id: "main") {
            SprintZeroView(model: model)
                .task {
                    model.initialize()
                }
        }
        .defaultSize(width: 1_100, height: 760)

        MenuBarExtra {
            ColdShotMenuBarView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.menuBarSystemImage)
                if model.canPauseArchive || model.isPausingArchive {
                    Text("\(model.batchCompletedAssetCount)/\(model.batchTotalAssetCount)")
                        .monospacedDigit()
                }
            }
            .accessibilityLabel(model.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
