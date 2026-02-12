import Foundation
import Combine

class RecordingState: ObservableObject {
    @Published var recordingDuration: TimeInterval = 0
    @Published var currentRecordingURL: URL?
    @Published var errorMessage: String?

    @Published var selectedMicrophoneID: String?
    @Published var availableMicrophones: [AudioDevice] = []
    @Published var outputDirectory: URL

    @Published var systemAudioEnabled = true
    @Published var microphoneEnabled = true
    @Published var systemVolume: Float = 1.0
    @Published var microphoneVolume: Float = 1.0

    @Published var zoomSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(zoomSyncEnabled, forKey: "zoomSyncEnabled")
        }
    }

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?

    init() {
        // Default to Documents folder
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsPath = documentsPath.appendingPathComponent("MeetsAudioRec", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: recordingsPath, withIntermediateDirectories: true)

        self.outputDirectory = recordingsPath
        self.zoomSyncEnabled = UserDefaults.standard.bool(forKey: "zoomSyncEnabled")
    }

    func startRecordingTimer() {
        recordingStartTime = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
    }

    func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
    }

    func resetDuration() {
        recordingDuration = 0
    }

    func generateRecordingFilename() -> URL {
        return generateRecordingFilename(eventTitle: nil)
    }

    func generateRecordingFilename(eventTitle: String?) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())

        if let title = eventTitle {
            let sanitized = title
                .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
                .joined()
                .replacingOccurrences(of: " ", with: "_")
                .prefix(60)
            return outputDirectory.appendingPathComponent("\(sanitized)_\(timestamp).m4a")
        }
        return outputDirectory.appendingPathComponent("Recording_\(timestamp).m4a")
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let uid: String
}
