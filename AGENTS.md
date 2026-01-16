# AGENTS.md - AI Agent Instructions

## Project Overview
MeetsAudioRec is a macOS app for recording system audio + microphone simultaneously. Built with SwiftUI and AVFoundation/ScreenCaptureKit.

## Build & Run
```bash
# Build (Debug)
./scripts/build.sh

# Build (Release)
./scripts/build.sh Release

# Run (after build)
open build/DerivedData/Build/Products/Debug/MeetsAudioRec.app
```

## Release Procedure

See `.claude/commands/release.md` for detailed workflow, or run:

```bash
./scripts/release.sh <version>
```

## Version Control

This project uses `jj` (Jujutsu) instead of git. Use `jj` commands for all VCS operations.

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

scripts/
├── build.sh          # Build Debug/Release
├── notarize.sh       # Sign and notarize app
├── package_dmg.sh    # Create notarized DMG
├── release.sh        # Full release workflow
└── generate_icon.py  # Generate app icon
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

### Zoom Mute Status (test)
- `ZoomMuteStatusMonitor` reads Zoom menu bar items via Accessibility (AXUIElement)
- Requires Accessibility permission and currently checks English menu labels ("Mute Audio" / "Unmute Audio")

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
- `com.apple.security.app-sandbox` - Set to `false` (sandbox disabled for ScreenCaptureKit)
- Screen Recording permission (granted via System Settings, not entitlement)

## Code Signing Notes
- `notarize.sh` must include `--entitlements` flag when signing
- Without entitlements, microphone permission dialogs won't appear in distributed builds
