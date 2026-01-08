# MeetsAudioRec

macOS menu bar application that records system audio and microphone input simultaneously, mixed into a single M4A file.

## Features

- **System Audio Capture**: Records all system audio using ScreenCaptureKit
- **Microphone Input**: Captures microphone audio with device selection (supports various formats)
- **Real-time Mixing**: Combines both sources with adjustable volume balance
- **Live Controls**: Adjust volume and toggle sources during recording
- **Level Meters**: Visual feedback for system, mic, and mixed audio levels
- **M4A Output**: High-quality AAC encoding at 256kbps, 48kHz stereo

## Requirements

- macOS 13.0 (Ventura) or later
- Screen Recording permission (for system audio)
- Microphone permission

## Building

### Prerequisites

- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional, for project generation)

### Generate Xcode Project

```bash
# Install xcodegen if not already installed
brew install xcodegen

# Generate .xcodeproj
cd MeetsAudioRec
xcodegen generate
```

### Build and Run

1. Open `MeetsAudioRec.xcodeproj` in Xcode
2. Select your development team in Signing & Capabilities
3. Build and run (⌘R)

### Build for Distribution

```bash
# Development build
./scripts/build.sh

# Release build
./scripts/build.sh Release

# Create notarized DMG (requires Apple Developer account)
./scripts/package_dmg.sh
```

#### First-time Setup for Notarization

Store your Apple credentials in Keychain:

```bash
xcrun notarytool store-credentials "notarytool-profile" \
  --apple-id YOUR_APPLE_ID@example.com \
  --team-id YOUR_TEAM_ID
```

## Usage

1. Launch the app (appears in menu bar)
2. Grant required permissions when prompted
3. Select your microphone device from the dropdown
4. Adjust volume sliders and enable/disable sources as needed
5. Click "Record" to begin
6. Adjust volumes or toggle sources in real-time during recording
7. Click "Stop" to finish
8. Recording is saved to `~/Documents/MeetsAudioRec/`

## Permissions

### Screen Recording
Required to capture system audio. Grant in:
**System Settings → Privacy & Security → Screen Recording**

### Microphone
Required to capture microphone input. The app will prompt for permission on first use.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     AudioCaptureManager                      │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────┐                 │
│  │ SystemAudio     │    │ Microphone      │                 │
│  │ Capture         │    │ Capture         │                 │
│  │ (ScreenCapture  │    │ (AVCapture      │                 │
│  │  Kit)           │    │  Session)       │                 │
│  └────────┬────────┘    └────────┬────────┘                 │
│           │                      │                          │
│           └──────────┬───────────┘                          │
│                      ▼                                      │
│            ┌─────────────────┐                              │
│            │   AudioMixer    │                              │
│            │  - Ring buffers │                              │
│            │  - Mix & volume │                              │
│            │  - Level calc   │                              │
│            └────────┬────────┘                              │
│                     ▼                                       │
│            ┌─────────────────┐                              │
│            │  AVAudioFile    │                              │
│            │  (M4A/AAC)      │                              │
│            └─────────────────┘                              │
└─────────────────────────────────────────────────────────────┘
```

## Technical Notes

### Audio Format Handling
- System audio: Float32, 48kHz, stereo (from ScreenCaptureKit)
- Microphone: Various formats supported (auto-converted to Float32 48kHz stereo)
  - Handles interleaved and non-interleaved formats
  - Supports Float32, Int16, Int32 input formats
- Output: AAC 256kbps, 48kHz stereo

### State Management
- `AudioCaptureManager`: Single source of truth for recording state and audio levels
- `RecordingState`: UI preferences (volumes, device selection, output directory)

## License

MIT License
