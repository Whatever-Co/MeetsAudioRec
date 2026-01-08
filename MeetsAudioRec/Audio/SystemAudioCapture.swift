import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

protocol SystemAudioCaptureDelegate: AnyObject {
    func systemAudioCapture(_ capture: SystemAudioCapture, didReceiveAudioBuffer buffer: AVAudioPCMBuffer)
    func systemAudioCapture(_ capture: SystemAudioCapture, didEncounterError error: Error)
}

class SystemAudioCapture: NSObject {
    weak var delegate: SystemAudioCaptureDelegate?

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var isCapturing = false

    let outputFormat: AVAudioFormat

    override init() {
        // Standard format: 48kHz, stereo, float32
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        super.init()
    }

    func startCapture() async throws {
        guard !isCapturing else { return }

        // Get available content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Get the main display
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }

        // Configure stream for audio only
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2

        // We don't need video, but we must configure it minimally
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum
        configuration.showsCursor = false

        // Create content filter for the display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Create and configure stream
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        // Create stream output handler
        let streamOutput = AudioStreamOutput { [weak self] buffer in
            guard let self = self else { return }
            self.delegate?.systemAudioCapture(self, didReceiveAudioBuffer: buffer)
        }
        self.streamOutput = streamOutput

        // Add stream output
        try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

        // Start capturing
        try await stream.startCapture()

        self.stream = stream
        self.isCapturing = true
    }

    func stopCapture() async {
        guard isCapturing, let stream = stream else { return }

        do {
            try await stream.stopCapture()
        } catch {
            print("Error stopping system audio capture: \(error)")
        }

        self.stream = nil
        self.streamOutput = nil
        self.isCapturing = false
    }

    static func checkPermission() async -> Bool {
        // Use CoreGraphics API for accurate permission check
        return CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        // Open System Settings directly to Screen Recording pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - SCStreamDelegate
extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturing = false
        delegate?.systemAudioCapture(self, didEncounterError: error)
    }
}

// MARK: - Audio Stream Output
private class AudioStreamOutput: NSObject, SCStreamOutput {
    private let audioHandler: (AVAudioPCMBuffer) -> Void

    init(audioHandler: @escaping (AVAudioPCMBuffer) -> Void) {
        self.audioHandler = audioHandler
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let buffer = convertToAudioBuffer(sampleBuffer: sampleBuffer) else { return }

        audioHandler(buffer)
    }

    private func convertToAudioBuffer(sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        guard let audioFormat = AVAudioFormat(streamDescription: streamBasicDescription) else {
            return nil
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        audioBuffer.frameLength = AVAudioFrameCount(frameCount)

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)

        guard let sourceData = dataPointer else { return nil }

        // Copy data to audio buffer
        guard let floatChannelData = audioBuffer.floatChannelData else {
            // Non-float format from ScreenCaptureKit is unexpected
            return nil
        }

        let channelCount = Int(audioFormat.channelCount)

        if audioFormat.isInterleaved {
            // Interleaved format - deinterleave
            let sourceFloatData = UnsafeRawPointer(sourceData).bindMemory(to: Float.self, capacity: frameCount * channelCount)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    floatChannelData[channel][frame] = sourceFloatData[frame * channelCount + channel]
                }
            }
        } else {
            // Non-interleaved - copy directly
            let bytesPerChannel = frameCount * MemoryLayout<Float>.size
            for channel in 0..<channelCount {
                memcpy(floatChannelData[channel], sourceData.advanced(by: channel * bytesPerChannel), bytesPerChannel)
            }
        }

        return audioBuffer
    }
}

enum AudioCaptureError: LocalizedError {
    case noDisplayAvailable
    case permissionDenied
    case captureAlreadyRunning
    case captureNotRunning
    case audioEngineError(String)
    case fileWriteError(String)

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for audio capture"
        case .permissionDenied:
            return "Screen recording permission denied"
        case .captureAlreadyRunning:
            return "Capture is already running"
        case .captureNotRunning:
            return "Capture is not running"
        case .audioEngineError(let message):
            return "Audio engine error: \(message)"
        case .fileWriteError(let message):
            return "File write error: \(message)"
        }
    }
}
