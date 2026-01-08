# Review (Temporary)

## High Priority Findings
- Recording continues even when mic permission is denied, resulting in silent files. The permission result is not used to abort recording. (AudioCaptureManager.swift:99-122)
- System audio conversion assumes float data, so non-float buffers are dropped in the mixer. This can lead to silent system audio. (SystemAudioCapture.swift:128-176, AudioMixer.swift:193-201)

## Medium Priority Findings
- Mic input formats outside Float32/Int16/Int32 are silently discarded with no error propagation. (MicrophoneCapture.swift:167-301)
- Output format is fixed to 48kHz/2ch; mono or different sample rates can fail conversion and drop audio. (AudioMixer.swift:31-47, 193-214)

## Low Priority Findings
- `requestPermissions()` checks system permission but does not request it, which is misleading for callers. (AudioCaptureManager.swift:72-79)
- Errors are stored but never shown in the UI, so failures are invisible. (ContentView.swift:133-149, RecordingState.swift:7)

## Open Questions
- Should system audio always be coerced to Float32, or should the mixer accept non-float buffers?
- For unsupported mic formats (e.g., 24-bit), should we fail fast or convert?

## Suggested Next Steps
- Abort recording when mic permission is denied.
- Ensure system audio buffers are converted to Float32 before passing to the mixer, or update the mixer to accept non-float formats.
- Decide on a single output format strategy (fixed vs input-following) and enforce it consistently.
- Surface errors in the UI so failures are actionable.
