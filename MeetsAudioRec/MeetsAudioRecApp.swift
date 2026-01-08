import SwiftUI

@main
struct MeetsAudioRecApp: App {
    @StateObject private var recordingState = RecordingState()
    @StateObject private var audioCaptureManager = AudioCaptureManager()

    init() {
        // Write startup log
        let logFile = URL(fileURLWithPath: "/tmp/MeetsAudioRec_log.txt")
        try? "App init at \(Date())\n".write(to: logFile, atomically: true, encoding: .utf8)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordingState)
                .environmentObject(audioCaptureManager)
        }
        .windowResizability(.contentSize)
    }
}
