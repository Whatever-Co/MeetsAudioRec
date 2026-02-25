import Sparkle
import SwiftUI

@main
struct MeetsAudioRecApp: App {
    @StateObject private var recordingState = RecordingState()
    @StateObject private var audioCaptureManager = AudioCaptureManager()
    @StateObject private var zoomMuteMonitor: ZoomMuteStatusMonitor

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        let monitor = ZoomMuteStatusMonitor()
        _zoomMuteMonitor = StateObject(wrappedValue: monitor)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordingState)
                .environmentObject(audioCaptureManager)
                .environmentObject(zoomMuteMonitor)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}
