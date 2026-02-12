import SwiftUI

@main
struct MeetsAudioRecApp: App {
    @StateObject private var recordingState = RecordingState()
    @StateObject private var audioCaptureManager = AudioCaptureManager()
    @StateObject private var zoomMuteMonitor: ZoomMuteStatusMonitor
    @StateObject private var calendarManager: GoogleCalendarManager

    init() {
        let monitor = ZoomMuteStatusMonitor()
        _zoomMuteMonitor = StateObject(wrappedValue: monitor)

        let calendar = GoogleCalendarManager()
        _calendarManager = StateObject(wrappedValue: calendar)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordingState)
                .environmentObject(audioCaptureManager)
                .environmentObject(zoomMuteMonitor)
                .environmentObject(calendarManager)
                .onAppear {
                    calendarManager.audioCaptureManager = audioCaptureManager
                    calendarManager.recordingState = recordingState
                }
        }
        .windowResizability(.contentSize)
    }
}
