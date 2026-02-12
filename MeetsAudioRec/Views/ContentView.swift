import SwiftUI

struct ContentView: View {
    @EnvironmentObject var recordingState: RecordingState
    @EnvironmentObject var audioCaptureManager: AudioCaptureManager
    @EnvironmentObject var zoomMuteMonitor: ZoomMuteStatusMonitor
    @EnvironmentObject var calendarManager: GoogleCalendarManager

    @State private var showingError = false

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let errorMessage = recordingState.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(errorMessage)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        recordingState.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }

            // Show different UI based on permission state
            if !audioCaptureManager.hasSystemAudioPermission {
                systemAudioPermissionView
            } else if !audioCaptureManager.hasMicrophonePermission {
                microphonePermissionView
            } else if recordingState.zoomSyncEnabled && !zoomMuteMonitor.hasAccessibilityPermission {
                accessibilityPermissionView
            } else {
                mainRecordingView
            }
        }
        .frame(width: 360)
        .onAppear {
            loadMicrophones()
            setupCallbacks()
            zoomMuteMonitor.checkAccessibilityPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check accessibility permission when app becomes active (user may have granted it in System Settings)
            zoomMuteMonitor.checkAccessibilityPermission()
        }
    }

    // MARK: - System Audio Permission View
    private var systemAudioPermissionView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            // Title
            Text("System Audio Recording")
                .font(.title2)
                .fontWeight(.semibold)

            // Description
            Text("MeetsAudioRec needs permission to record system audio. Please enable Screen Recording in System Settings.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)

            // Open Settings button
            Button(action: openSystemSettings) {
                Text("Open System Settings")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.top, 8)

            Spacer()
        }
        .padding(.vertical, 40)
    }

    // MARK: - Microphone Permission View
    private var microphonePermissionView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            // Title
            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.semibold)

            // Description
            Text("To record audio from your microphone, please grant microphone access.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)

            // Request permission button
            Button(action: requestMicrophonePermission) {
                Text("Allow Microphone Access")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.top, 8)

            Spacer()
        }
        .padding(.vertical, 40)
    }

    // MARK: - Accessibility Permission View
    private var accessibilityPermissionView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            // Title
            Text("Accessibility Access")
                .font(.title2)
                .fontWeight(.semibold)

            // Description
            Text("Zoom Sync requires Accessibility access to read Zoom's mute status. Please grant access in System Settings.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)

            // Request permission button
            Button(action: {
                zoomMuteMonitor.requestAccessibilityPermission()
            }) {
                Text("Open Accessibility Settings")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.top, 8)

            // Skip button
            Button(action: {
                recordingState.zoomSyncEnabled = false
            }) {
                Text("Disable Zoom Sync")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding(.vertical, 40)
    }

    // MARK: - Main Recording View
    private var mainRecordingView: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: audioCaptureManager.isRecording ? "record.circle.fill" : "waveform.circle.fill")
                    .font(.title2)
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
            .padding(.top, 20)
            .padding(.horizontal, 20)

            // System Audio Group
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.blue)
                        .frame(width: 20)
                    Text("System Audio")
                        .font(.headline)
                    Spacer()
                    Toggle(isOn: $recordingState.systemAudioEnabled) {
                        Text("")
                    }
                    .toggleStyle(.switch)
                    .onChange(of: recordingState.systemAudioEnabled) { newValue in
                        audioCaptureManager.updateEnabledSources(
                            system: newValue,
                            microphone: recordingState.microphoneEnabled
                        )
                    }
                    .help(recordingState.systemAudioEnabled ? "System audio is enabled" : "System audio is muted")
                }

                // Level meter
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geo.size.width * CGFloat(audioCaptureManager.systemAudioLevel))
                    }
                }
                .frame(height: 8)
                .cornerRadius(4)

                // Volume slider
                HStack {
                    Slider(value: $recordingState.systemVolume, in: 0...2)
                        .onChange(of: recordingState.systemVolume) { newValue in
                            audioCaptureManager.updateVolumes(
                                system: newValue,
                                microphone: recordingState.microphoneVolume
                            )
                        }
                        .disabled(!recordingState.systemAudioEnabled)

                    Text("\(Int(recordingState.systemVolume * 100))%")
                        .frame(width: 50, alignment: .trailing)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(recordingState.systemAudioEnabled ? .primary : .secondary)
                }
            }
            .padding(12)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            .padding(.horizontal, 20)

            // Microphone Group
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "mic.fill")
                        .foregroundColor(.orange)
                        .frame(width: 20)
                    Text("Microphone")
                        .font(.headline)
                    Spacer()
                    Toggle(isOn: $recordingState.microphoneEnabled) {
                        Text("")
                    }
                    .toggleStyle(.switch)
                    .onChange(of: recordingState.microphoneEnabled) { _ in
                        syncMicWithZoom()
                    }
                    .help(recordingState.microphoneEnabled ? "Microphone is enabled" : "Microphone is muted")
                }

                // Level meter
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: geo.size.width * CGFloat(audioCaptureManager.microphoneLevel))
                    }
                }
                .frame(height: 8)
                .cornerRadius(4)

                // Volume slider
                HStack {
                    Slider(value: $recordingState.microphoneVolume, in: 0...2)
                        .onChange(of: recordingState.microphoneVolume) { newValue in
                            audioCaptureManager.updateVolumes(
                                system: recordingState.systemVolume,
                                microphone: newValue
                            )
                        }
                        .disabled(!recordingState.microphoneEnabled)

                    Text("\(Int(recordingState.microphoneVolume * 100))%")
                        .frame(width: 50, alignment: .trailing)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(recordingState.microphoneEnabled ? .primary : .secondary)
                }

                // Device picker
                Picker("Input Device", selection: $recordingState.selectedMicrophoneID) {
                    Text("Default").tag(nil as String?)
                    ForEach(recordingState.availableMicrophones) { device in
                        Text(device.name).tag(device.id as String?)
                    }
                }
            }
            .padding(12)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            .padding(.horizontal, 20)

zoomMuteStatusView

calendarAutoRecordView

            // Output Directory Group
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    Text("Output Folder")
                        .font(.headline)
                }

                // Folder path
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    Text(recordingState.outputDirectory.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)

                // Action buttons
                HStack(spacing: 8) {
                    Button(action: selectFolder) {
                        Label("Choose Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)

                    Button(action: { NSWorkspace.shared.open(recordingState.outputDirectory) }) {
                        Label("Open in Finder", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            .padding(.horizontal, 20)

            // Record button
            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: audioCaptureManager.isRecording ? "stop.fill" : "record.circle")
                    Text(audioCaptureManager.isRecording ? "Stop Recording" : "Start Recording")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(audioCaptureManager.isRecording ? .red : .accentColor)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

private var zoomMuteStatusView: some View {
  VStack(alignment: .leading, spacing: 8) {
    HStack {
      Image(systemName: "video.fill")
        .foregroundColor(.purple)
        .frame(width: 20)
      Text("Zoom Sync")
        .font(.headline)
      Spacer()
      Toggle(isOn: $recordingState.zoomSyncEnabled) {
        Text("")
      }
      .toggleStyle(.switch)
      .onChange(of: recordingState.zoomSyncEnabled) { newValue in
        // Start/stop monitoring based on recording state
        if audioCaptureManager.isRecording {
          if newValue {
            zoomMuteMonitor.startMonitoring()
            syncMicWithZoom()
          } else {
            zoomMuteMonitor.stopMonitoring()
          }
        }
      }
      .help(recordingState.zoomSyncEnabled ? "Mic mute synced with Zoom" : "Mic mute not synced")
    }

    if audioCaptureManager.isRecording && recordingState.zoomSyncEnabled {
      HStack {
        Text("Zoom Status")
          .foregroundColor(.secondary)
        Spacer()
        HStack(spacing: 4) {
          Circle()
            .fill(zoomStatusColor)
            .frame(width: 8, height: 8)
          Text(zoomMuteMonitor.statusLabel)
            .font(.system(.body, design: .monospaced))
        }
      }

      if zoomMuteMonitor.status == .muted {
        Text("Mic is muted (synced with Zoom)")
          .font(.caption)
          .foregroundColor(.orange)
      }

      if zoomMuteMonitor.status == .noAccessibility {
        Button(action: openAccessibilitySettings) {
          Label("Grant Accessibility Access", systemImage: "hand.raised.fill")
        }
        .buttonStyle(.bordered)
      }
    } else if recordingState.zoomSyncEnabled && !audioCaptureManager.isRecording {
      Text("Will sync when recording starts")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }
  .padding(12)
  .background(Color.gray.opacity(0.05))
  .cornerRadius(8)
  .padding(.horizontal, 20)
  .onChange(of: zoomMuteMonitor.status) { _ in
    syncMicWithZoom()
  }
}

private var zoomStatusColor: Color {
  switch zoomMuteMonitor.status {
  case .muted: return .orange
  case .unmuted: return .green
  case .unknown: return .gray
  case .notRunning: return .gray
  case .noAccessibility: return .red
  }
}

// MARK: - Calendar Auto-Record View

private var calendarAutoRecordView: some View {
  VStack(alignment: .leading, spacing: 8) {
    HStack {
      Image(systemName: "calendar")
        .foregroundColor(.green)
        .frame(width: 20)
      Text("Calendar Auto-Record")
        .font(.headline)
      Spacer()
      Toggle(isOn: $calendarManager.autoRecordEnabled) {
        Text("")
      }
      .toggleStyle(.switch)
      .onChange(of: calendarManager.autoRecordEnabled) { newValue in
        if newValue && calendarManager.isSignedIn {
          calendarManager.startPolling()
        } else if !newValue {
          calendarManager.stopPolling()
        }
      }
      .help(calendarManager.autoRecordEnabled ? "Auto-record meetings from Google Calendar" : "Auto-record disabled")
    }

    if !calendarManager.isConfigured {
      Text("Set Google OAuth credentials in GoogleCalendarManager.swift to enable this feature.")
        .font(.caption)
        .foregroundColor(.secondary)
    } else if !calendarManager.isSignedIn {
      Button(action: { calendarManager.signIn() }) {
        Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)

      if let status = calendarManager.statusMessage {
        Text(status)
          .font(.caption)
          .foregroundColor(.orange)
      }
    } else {
      // Signed in state
      HStack {
        if let email = calendarManager.userEmail {
          Text(email)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        Spacer()
        Button("Sign Out") {
          calendarManager.signOut()
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundColor(.red)
      }

      if calendarManager.autoRecordEnabled {
        if calendarManager.isAutoRecording, let event = calendarManager.currentEvent {
          HStack(spacing: 4) {
            Circle()
              .fill(Color.red)
              .frame(width: 8, height: 8)
            Text("Recording: \(event.title)")
              .font(.caption)
              .foregroundColor(.red)
              .lineLimit(1)
          }
        } else if let next = calendarManager.nextMeeting {
          HStack(spacing: 4) {
            Circle()
              .fill(Color.green)
              .frame(width: 8, height: 8)
            Text("Next: \(next.title)")
              .font(.caption)
              .foregroundColor(.secondary)
              .lineLimit(1)
            Spacer()
            Text(formatEventTime(next.startTime))
              .font(.system(.caption, design: .monospaced))
              .foregroundColor(.secondary)
          }
        } else if calendarManager.upcomingMeetings.isEmpty {
          Text("No upcoming meetings with video links")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        // Show upcoming meetings list (max 3)
        if calendarManager.upcomingMeetings.count > 0 {
          ForEach(Array(calendarManager.upcomingMeetings.prefix(3))) { event in
            HStack {
              Image(systemName: event.meetingType == .googleMeet ? "video.fill" : "video.circle.fill")
                .font(.caption)
                .foregroundColor(event.meetingType == .googleMeet ? .green : .blue)
                .frame(width: 16)
              Text(event.title)
                .font(.caption)
                .lineLimit(1)
              Spacer()
              Text(formatEventTime(event.startTime))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
            }
          }
        }
      }
    }
  }
  .padding(12)
  .background(Color.gray.opacity(0.05))
  .cornerRadius(8)
  .padding(.horizontal, 20)
}

private func formatEventTime(_ date: Date) -> String {
  let now = Date()
  let diff = date.timeIntervalSince(now)
  if diff < 0 {
    return "now"
  } else if diff < 3600 {
    return "\(Int(diff / 60))m"
  } else {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}

private var effectiveMicEnabled: Bool {
  if recordingState.zoomSyncEnabled && zoomMuteMonitor.status == .muted {
    return false
  }
  return recordingState.microphoneEnabled
}

private func syncMicWithZoom() {
  guard recordingState.zoomSyncEnabled else { return }

  // Actually move the mic switch based on Zoom status
  let shouldMicBeEnabled: Bool
  switch zoomMuteMonitor.status {
  case .muted:
    shouldMicBeEnabled = false
  case .unmuted:
    shouldMicBeEnabled = true
  default:
    // Don't change for unknown/notRunning/noAccessibility
    return
  }

  if recordingState.microphoneEnabled != shouldMicBeEnabled {
    recordingState.microphoneEnabled = shouldMicBeEnabled
    audioCaptureManager.updateEnabledSources(
      system: recordingState.systemAudioEnabled,
      microphone: shouldMicBeEnabled
    )
  }
}

    // MARK: - Actions
    private func openSystemSettings() {
        audioCaptureManager.requestSystemAudioPermission()
    }

    private func requestMicrophonePermission() {
        Task {
            await audioCaptureManager.requestMicrophonePermission()
        }
    }

private func openAccessibilitySettings() {
  if let url = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  {
    NSWorkspace.shared.open(url)
  }
}

    private func setupCallbacks() {
        audioCaptureManager.onRecordingStarted = { [weak recordingState, weak zoomMuteMonitor] url in
            recordingState?.currentRecordingURL = url
            recordingState?.startRecordingTimer()
            // Start Zoom sync monitoring if enabled
            if recordingState?.zoomSyncEnabled == true {
                zoomMuteMonitor?.startMonitoring()
            }
        }

        audioCaptureManager.onRecordingStopped = { [weak recordingState, weak zoomMuteMonitor, weak calendarManager] url in
            recordingState?.stopRecordingTimer()
            // Stop Zoom sync monitoring
            zoomMuteMonitor?.stopMonitoring()
            // Reset auto-record state if recording was manually stopped
            calendarManager?.recordingWasManuallyStopped()
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
