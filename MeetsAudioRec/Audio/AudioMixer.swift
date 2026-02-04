import Foundation
import AVFoundation
import Accelerate
import os.log

private let logger = Logger(subsystem: "com.saqoosha.MeetsAudioRec", category: "AudioMixer")

class AudioMixer {
    private var audioFile: AVAudioFile?
    private let outputFormat: AVAudioFormat

    private let writeQueue = DispatchQueue(label: "com.saqoosha.MeetsAudioRec.mixer.write", qos: .userInteractive)

    // Ring buffers for each source
    private var systemRingBuffer: RingBuffer
    private var micRingBuffer: RingBuffer

    private let bufferSize: AVAudioFrameCount = 4096
    private var mixBuffer: AVAudioPCMBuffer?

    var systemVolume: Float = 1.0
    var microphoneVolume: Float = 1.0
    var systemEnabled = true
    var microphoneEnabled = true

    var onLevelUpdate: ((Float, Float, Float) -> Void)?

    private var isRecording = false
    private var writeTimer: DispatchSourceTimer?
    private var finalOutputURL: URL?

    init() {
        // Processing format: 48kHz, stereo, float32
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!

        // Create ring buffers (1 second capacity each)
        let ringCapacity = AVAudioFrameCount(48000)
        self.systemRingBuffer = RingBuffer(capacity: ringCapacity, channels: 2)
        self.micRingBuffer = RingBuffer(capacity: ringCapacity, channels: 2)

        // Create mix buffer
        self.mixBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize)
    }

    func startRecording(to url: URL) throws {
        finalOutputURL = url
        let tempURL = url.appendingPathExtension("recording")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 256000
        ]

        audioFile = try AVAudioFile(
            forWriting: tempURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        isRecording = true

        // Start periodic write timer (every ~85ms = 4096 samples at 48kHz)
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(85))
        timer.setEventHandler { [weak self] in
            self?.mixAndWrite()
        }
        timer.resume()
        writeTimer = timer
    }

    func stopRecording() {
        isRecording = false
        writeTimer?.cancel()
        writeTimer = nil

        // Flush remaining data
        writeQueue.sync {
            mixAndWrite()
        }

        audioFile = nil

        // Rename temp file to final output
        if let finalURL = finalOutputURL {
            let tempURL = finalURL.appendingPathExtension("recording")
            do {
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
            } catch {
                logger.error("Failed to rename recording file: \(error.localizedDescription)")
            }
        }
        finalOutputURL = nil

        systemRingBuffer.reset()
        micRingBuffer.reset()
    }

    func receiveSystemAudio(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, systemEnabled else { return }

        // Convert to output format if needed
        guard let converted = convertBufferIfNeeded(buffer, to: outputFormat) else {
            logger.warning("System audio: format conversion failed, dropping buffer")
            return
        }
        systemRingBuffer.write(converted)

        // Calculate and report level
        let level = calculateRMSLevel(buffer)
        DispatchQueue.main.async {
            self.onLevelUpdate?(level * self.systemVolume, -1, -1)
        }
    }

    func receiveMicrophoneAudio(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, microphoneEnabled else { return }

        // Convert to output format if needed
        guard let converted = convertBufferIfNeeded(buffer, to: outputFormat) else {
            logger.warning("Microphone audio: format conversion failed, dropping buffer")
            return
        }
        micRingBuffer.write(converted)

        // Calculate and report level
        let level = calculateRMSLevel(buffer)
        DispatchQueue.main.async {
            self.onLevelUpdate?(-1, level * self.microphoneVolume, -1)
        }
    }

    private func mixAndWrite() {
        guard isRecording, let mixBuffer = mixBuffer, let audioFile = audioFile else { return }

        let frameCount = bufferSize
        mixBuffer.frameLength = frameCount

        guard let floatChannelData = mixBuffer.floatChannelData else { return }

        // Clear mix buffer
        for channel in 0..<2 {
            memset(floatChannelData[channel], 0, Int(frameCount) * MemoryLayout<Float>.size)
        }

        var hasData = false

        // Read from system ring buffer
        if systemEnabled {
            if let systemBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) {
                let readFrames = systemRingBuffer.read(into: systemBuffer, frameCount: frameCount)
                if readFrames > 0, let sysData = systemBuffer.floatChannelData {
                    hasData = true
                    for channel in 0..<2 {
                        vDSP_vsma(sysData[channel], 1,
                                  [systemVolume],
                                  floatChannelData[channel], 1,
                                  floatChannelData[channel], 1,
                                  vDSP_Length(readFrames))
                    }
                }
            }
        }

        // Read from mic ring buffer
        if microphoneEnabled {
            if let micBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) {
                let readFrames = micRingBuffer.read(into: micBuffer, frameCount: frameCount)
                if readFrames > 0, let micData = micBuffer.floatChannelData {
                    hasData = true
                    for channel in 0..<2 {
                        vDSP_vsma(micData[channel], 1,
                                  [microphoneVolume],
                                  floatChannelData[channel], 1,
                                  floatChannelData[channel], 1,
                                  vDSP_Length(readFrames))
                    }
                }
            }
        }

        // Write to file if we have data
        if hasData {
            // Calculate mixed level
            let mixedLevel = calculateRMSLevel(mixBuffer)
            DispatchQueue.main.async {
                self.onLevelUpdate?(-1, -1, mixedLevel)
            }

            do {
                try audioFile.write(from: mixBuffer)
            } catch {
                print("Error writing audio: \(error)")
            }
        }
    }

    /// Converts buffer to target format if needed.
    /// Returns the original buffer if formats match, converted buffer on success, or nil on conversion failure.
    private func convertBufferIfNeeded(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // No conversion needed if formats match
        guard buffer.format != format else { return buffer }

        // Ensure input buffer has float data (required for ring buffer)
        guard buffer.floatChannelData != nil else {
            logger.error("Input buffer is not float format")
            return nil
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            logger.error("Failed to create converter from \(buffer.format) to \(format)")
            return nil
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCapacity) else {
            logger.error("Failed to create output buffer")
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else {
            logger.error("Conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }

        return outputBuffer
    }

    private func calculateRMSLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(floatData[0], 1, &rms, vDSP_Length(buffer.frameLength))

        // Convert to dB and normalize to 0-1 range
        let db = 20 * log10(max(rms, 0.00001))
        let normalized = (db + 60) / 60 // -60dB to 0dB -> 0 to 1

        return max(0, min(1, normalized))
    }
}

// MARK: - Ring Buffer

class RingBuffer {
    private var buffer: [[Float]]
    private let capacity: AVAudioFrameCount
    private let channels: Int
    private var writeIndex: AVAudioFrameCount = 0
    private var readIndex: AVAudioFrameCount = 0
    private var availableFrames: AVAudioFrameCount = 0
    private let lock = NSLock()

    init(capacity: AVAudioFrameCount, channels: Int) {
        self.capacity = capacity
        self.channels = channels
        self.buffer = (0..<channels).map { _ in [Float](repeating: 0, count: Int(capacity)) }
    }

    func write(_ audioBuffer: AVAudioPCMBuffer) {
        guard let floatData = audioBuffer.floatChannelData else { return }

        lock.lock()
        defer { lock.unlock() }

        let framesToWrite = min(audioBuffer.frameLength, capacity - availableFrames)
        guard framesToWrite > 0 else { return }

        for channel in 0..<min(channels, Int(audioBuffer.format.channelCount)) {
            for i in 0..<Int(framesToWrite) {
                let destIndex = Int((writeIndex + AVAudioFrameCount(i)) % capacity)
                buffer[channel][destIndex] = floatData[channel][i]
            }
        }

        writeIndex = (writeIndex + framesToWrite) % capacity
        availableFrames += framesToWrite
    }

    func read(into audioBuffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) -> AVAudioFrameCount {
        guard let floatData = audioBuffer.floatChannelData else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        let framesToRead = min(frameCount, availableFrames)
        guard framesToRead > 0 else {
            audioBuffer.frameLength = 0
            return 0
        }

        for channel in 0..<min(channels, Int(audioBuffer.format.channelCount)) {
            for i in 0..<Int(framesToRead) {
                let srcIndex = Int((readIndex + AVAudioFrameCount(i)) % capacity)
                floatData[channel][i] = buffer[channel][srcIndex]
            }
        }

        readIndex = (readIndex + framesToRead) % capacity
        availableFrames -= framesToRead
        audioBuffer.frameLength = framesToRead

        return framesToRead
    }

    func reset() {
        lock.lock()
        defer { lock.unlock()  }

        writeIndex = 0
        readIndex = 0
        availableFrames = 0
    }
}
