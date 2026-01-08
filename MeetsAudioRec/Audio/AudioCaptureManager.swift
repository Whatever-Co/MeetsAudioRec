import Foundation
import AVFoundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.saqoosha.MeetsAudioRec", category: "AudioCapture")

class AudioCaptureManager: ObservableObject {
    private let systemCapture = SystemAudioCapture()
    private let microphoneCapture = MicrophoneCapture()
    private let mixer = AudioMixer()

    @Published var isRecording = false
    @Published var hasSystemAudioPermission = false
    @Published var hasMicrophonePermission = false

    @Published var systemAudioLevel: Float = 0
    @Published var microphoneLevel: Float = 0
    @Published var mixedLevel: Float = 0

    private var recordingTask: Task<Void, Never>?

    var onRecordingStarted: ((URL) -> Void)?
    var onRecordingStopped: ((URL?) -> Void)?
    var onError: ((Error) -> Void)?

    private var currentRecordingURL: URL?

    init() {
        setupDelegates()

        // Request screen capture permission on launch
        let hasAccess = CGPreflightScreenCaptureAccess()
        if !hasAccess {
            logger.info("Requesting screen capture access...")
            CGRequestScreenCaptureAccess()
        }

        checkPermissions()
    }

    private func setupDelegates() {
        systemCapture.delegate = self
        microphoneCapture.delegate = self

        mixer.onLevelUpdate = { [weak self] systemLevel, micLevel, mixedLevel in
            guard let self = self else { return }
            // Only update levels that have valid values (-1 means no update)
            DispatchQueue.main.async {
                if systemLevel >= 0 { self.systemAudioLevel = systemLevel }
                if micLevel >= 0 { self.microphoneLevel = micLevel }
                if mixedLevel >= 0 { self.mixedLevel = mixedLevel }
            }
        }
    }

    func checkPermissions() {
        Task {
            let systemPermission = await SystemAudioCapture.checkPermission()
            let micPermission = MicrophoneCapture.checkPermission()

            logger.info("System Audio Permission: \(systemPermission)")
            logger.info("Microphone Permission: \(micPermission)")

            await MainActor.run {
                self.hasSystemAudioPermission = systemPermission
                self.hasMicrophonePermission = micPermission
            }
        }
    }

    func requestPermissions() async {
        let systemPermission = await SystemAudioCapture.checkPermission()
        let micPermission = await MicrophoneCapture.requestPermission()

        await MainActor.run {
            self.hasSystemAudioPermission = systemPermission
            self.hasMicrophonePermission = micPermission
        }
    }

    func getAvailableMicrophones() -> [AudioDevice] {
        return microphoneCapture.getAvailableMicrophones()
    }

    func startRecording(to url: URL, microphoneUID: String? = nil, systemEnabled: Bool = true, micEnabled: Bool = true, systemVolume: Float = 1.0, micVolume: Float = 1.0) {
        guard !isRecording else { return }

        currentRecordingURL = url

        // Configure mixer
        mixer.systemEnabled = systemEnabled
        mixer.microphoneEnabled = micEnabled
        mixer.systemVolume = systemVolume
        mixer.microphoneVolume = micVolume

        recordingTask = Task {
            do {
                if micEnabled {
                    let micPermission = MicrophoneCapture.checkPermission()
                    if !micPermission {
                        let granted = await MicrophoneCapture.requestPermission()
                        await MainActor.run {
                            self.hasMicrophonePermission = granted
                        }
                    }
                }

                // Start mixer/recording
                try mixer.startRecording(to: url)

                // Start captures
                if micEnabled {
                    try microphoneCapture.startCapture(deviceUID: microphoneUID)
                }

                if systemEnabled {
                    let hasSystemPermission = await SystemAudioCapture.checkPermission()
                    if hasSystemPermission {
                        try await systemCapture.startCapture()
                    }
                }

                await MainActor.run {
                    self.isRecording = true
                    self.onRecordingStarted?(url)
                }
            } catch {
                logger.error("Recording error: \(error.localizedDescription)")
                await MainActor.run {
                    self.onError?(error)
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        recordingTask?.cancel()

        Task {
            // Stop captures
            await systemCapture.stopCapture()
            microphoneCapture.stopCapture()

            // Stop mixer
            mixer.stopRecording()

            let url = currentRecordingURL
            currentRecordingURL = nil

            await MainActor.run {
                self.isRecording = false
                self.systemAudioLevel = 0
                self.microphoneLevel = 0
                self.mixedLevel = 0
                self.onRecordingStopped?(url)
            }
        }
    }

    func updateVolumes(system: Float, microphone: Float) {
        mixer.systemVolume = system
        mixer.microphoneVolume = microphone
    }

    func updateEnabledSources(system: Bool, microphone: Bool) {
        mixer.systemEnabled = system
        mixer.microphoneEnabled = microphone
    }
}

// MARK: - SystemAudioCaptureDelegate
extension AudioCaptureManager: SystemAudioCaptureDelegate {
    func systemAudioCapture(_ capture: SystemAudioCapture, didReceiveAudioBuffer buffer: AVAudioPCMBuffer) {
        mixer.receiveSystemAudio(buffer)
    }

    func systemAudioCapture(_ capture: SystemAudioCapture, didEncounterError error: Error) {
        DispatchQueue.main.async {
            self.onError?(error)
        }
    }
}

// MARK: - MicrophoneCaptureDelegate
extension AudioCaptureManager: MicrophoneCaptureDelegate {
    func microphoneCapture(_ capture: MicrophoneCapture, didReceiveAudioBuffer buffer: AVAudioPCMBuffer) {
        mixer.receiveMicrophoneAudio(buffer)
    }

    func microphoneCapture(_ capture: MicrophoneCapture, didEncounterError error: Error) {
        DispatchQueue.main.async {
            self.onError?(error)
        }
    }
}
