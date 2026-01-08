import SwiftUI

struct ContentView: View {
    @EnvironmentObject var recordingState: RecordingState
    @EnvironmentObject var audioCaptureManager: AudioCaptureManager

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: audioCaptureManager.isRecording ? "record.circle.fill" : "waveform.circle.fill")
                    .font(.title)
                    .foregroundColor(audioCaptureManager.isRecording ? .red : .accentColor)

                Text("MeetsAudioRec")
                    .font(.headline)

                Spacer()

                if audioCaptureManager.isRecording {
                    Text(formatDuration(recordingState.recordingDuration))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.red)
                }
            }

            Divider()

            // Status
            HStack(spacing: 20) {
                StatusBadge(label: "System", isReady: audioCaptureManager.hasSystemAudioPermission)
                StatusBadge(label: "Mic", isReady: audioCaptureManager.hasMicrophonePermission)
            }

            // Level Meters
            VStack(spacing: 8) {
                SimpleLevelMeter(label: "System", level: audioCaptureManager.systemAudioLevel, color: .blue)
                SimpleLevelMeter(label: "Mic", level: audioCaptureManager.microphoneLevel, color: .orange)
                SimpleLevelMeter(label: "Mix", level: audioCaptureManager.mixedLevel, color: .green)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            // Volume sliders
            VStack(spacing: 12) {
                HStack {
                    Text("System")
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $recordingState.systemVolume, in: 0...2)
                        .onChange(of: recordingState.systemVolume) { newValue in
                            audioCaptureManager.updateVolumes(
                                system: newValue,
                                microphone: recordingState.microphoneVolume
                            )
                        }
                    Text("\(Int(recordingState.systemVolume * 100))%")
                        .frame(width: 45)
                }

                HStack {
                    Text("Mic")
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $recordingState.microphoneVolume, in: 0...2)
                        .onChange(of: recordingState.microphoneVolume) { newValue in
                            audioCaptureManager.updateVolumes(
                                system: recordingState.systemVolume,
                                microphone: newValue
                            )
                        }
                    Text("\(Int(recordingState.microphoneVolume * 100))%")
                        .frame(width: 45)
                }
            }

            // Toggles
            HStack(spacing: 20) {
                Toggle("System", isOn: $recordingState.systemAudioEnabled)
                    .onChange(of: recordingState.systemAudioEnabled) { newValue in
                        audioCaptureManager.updateEnabledSources(
                            system: newValue,
                            microphone: recordingState.microphoneEnabled
                        )
                    }
                Toggle("Mic", isOn: $recordingState.microphoneEnabled)
                    .onChange(of: recordingState.microphoneEnabled) { newValue in
                        audioCaptureManager.updateEnabledSources(
                            system: recordingState.systemAudioEnabled,
                            microphone: newValue
                        )
                    }
            }
            .toggleStyle(.checkbox)

            // Microphone picker
            Picker("Input Device", selection: $recordingState.selectedMicrophoneID) {
                Text("Default").tag(nil as String?)
                ForEach(recordingState.availableMicrophones) { device in
                    Text(device.name).tag(device.id as String?)
                }
            }

            // Record button
            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: audioCaptureManager.isRecording ? "stop.fill" : "record.circle")
                    Text(audioCaptureManager.isRecording ? "Stop" : "Record")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(audioCaptureManager.isRecording ? .red : .accentColor)

            // Output folder
            HStack {
                Text(recordingState.outputDirectory.lastPathComponent)
                    .lineLimit(1)
                Spacer()
                Button("Choose...") { selectFolder() }
                Button("Open") { NSWorkspace.shared.open(recordingState.outputDirectory) }
            }
            .font(.caption)
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            loadMicrophones()
            setupCallbacks()
        }
    }

    private func setupCallbacks() {
        audioCaptureManager.onRecordingStarted = { [weak recordingState] url in
            recordingState?.currentRecordingURL = url
            recordingState?.startRecordingTimer()
        }

        audioCaptureManager.onRecordingStopped = { [weak recordingState] url in
            recordingState?.stopRecordingTimer()
            if let url = url {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            }
        }

        audioCaptureManager.onError = { [weak recordingState] error in
            recordingState?.errorMessage = error.localizedDescription
        }
    }

    private func toggleRecording() {
        if audioCaptureManager.isRecording {
            audioCaptureManager.stopRecording()
        } else {
            let url = recordingState.generateRecordingFilename()
            audioCaptureManager.startRecording(
                to: url,
                microphoneUID: recordingState.selectedMicrophoneID,
                systemEnabled: recordingState.systemAudioEnabled,
                micEnabled: recordingState.microphoneEnabled,
                systemVolume: recordingState.systemVolume,
                micVolume: recordingState.microphoneVolume
            )
        }
    }

    private func loadMicrophones() {
        recordingState.availableMicrophones = audioCaptureManager.getAvailableMicrophones()
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            recordingState.outputDirectory = url
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct StatusBadge: View {
    let label: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isReady ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
    }
}

struct SimpleLevelMeter: View {
    let label: String
    let level: Float
    let color: Color

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 50, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                    Rectangle()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(level))
                }
            }
            .frame(height: 6)
            .cornerRadius(3)
        }
    }
}
