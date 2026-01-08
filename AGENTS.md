# AGENTS.md - AI Agent Instructions

## Project Overview
MeetsAudioRec is a macOS app for recording system audio + microphone simultaneously. Built with SwiftUI and AVFoundation/ScreenCaptureKit.

## Build & Run
```bash
# Build
xcodebuild -scheme MeetsAudioRec -configuration Debug build

# Run (after build)
open ~/Library/Developer/Xcode/DerivedData/MeetsAudioRec-*/Build/Products/Debug/MeetsAudioRec.app
```

## Project Structure
```
MeetsAudioRec/
├── Audio/
│   ├── AudioCaptureManager.swift  # Orchestrates capture & mixing
│   ├── AudioMixer.swift           # Ring buffers, mixing, file writing
│   ├── MicrophoneCapture.swift    # AVCaptureSession-based mic input
│   └── SystemAudioCapture.swift   # ScreenCaptureKit system audio
├── Models/
│   └── RecordingState.swift       # UI state (volumes, device selection)
├── Views/
│   └── ContentView.swift          # Main UI
└── MeetsAudioRecApp.swift         # App entry point
```

## Key Technical Details

### Audio Pipeline
1. **SystemAudioCapture**: Uses `SCStream` from ScreenCaptureKit, outputs Float32 48kHz stereo
2. **MicrophoneCapture**: Uses `AVCaptureSession` (not AVAudioEngine), handles various input formats
3. **AudioMixer**: Ring buffers for each source, mixes with volume control, writes to M4A

### Format Conversion (MicrophoneCapture)
- Receives `CMSampleBuffer` from `AVCaptureAudioDataOutput`
- Extracts `AudioBufferList` using `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`
- Handles both interleaved and **non-interleaved** audio (critical for USB devices like Razer Kiyo Pro)
- Converts Int16/Int32 to Float32 if needed
- Converts to 48kHz stereo via `AVAudioConverter`

### State Architecture
- `AudioCaptureManager.isRecording` is the **single source of truth** for recording state
- UI reads from `AudioCaptureManager` directly, not duplicated state
- Volume/enable changes are live via `updateVolumes()` / `updateEnabledSources()`

## Common Issues & Solutions

### Mic not working with USB devices
- **Cause**: Some USB mics output non-interleaved audio format
- **Solution**: Check `kAudioFormatFlagIsNonInterleaved` flag, iterate `AudioBufferList.mBuffers` per channel

### Recording state mismatch
- **Cause**: UI state set before async recording start
- **Solution**: Use `onRecordingStarted` callback, let `AudioCaptureManager.isRecording` be the truth

### Format conversion failures
- **Cause**: `convertBufferIfNeeded` returns nil on failure
- **Solution**: Drop buffer and log warning, don't pass non-float buffers to ring buffer

## Entitlements Required
- `com.apple.security.device.audio-input` - Microphone access
- `com.apple.security.app-sandbox` - Sandbox enabled
- Screen Recording permission (granted via System Settings, not entitlement)
