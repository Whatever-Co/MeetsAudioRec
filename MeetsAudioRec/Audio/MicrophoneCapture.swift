import Foundation
import AVFoundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.saqoosha.MeetsAudioRec", category: "MicrophoneCapture")

protocol MicrophoneCaptureDelegate: AnyObject {
    func microphoneCapture(_ capture: MicrophoneCapture, didReceiveAudioBuffer buffer: AVAudioPCMBuffer)
    func microphoneCapture(_ capture: MicrophoneCapture, didEncounterError error: Error)
}

class MicrophoneCapture: NSObject {
    weak var delegate: MicrophoneCaptureDelegate?

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "com.saqoosha.MeetsAudioRec.micCapture", qos: .userInteractive)

    private var isCapturing = false
    private var selectedDeviceUID: String?

    let outputFormat: AVAudioFormat

    override init() {
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        super.init()
    }

    func getAvailableMicrophones() -> [AudioDevice] {
        let devices = AVCaptureDevice.devices(for: .audio)
        return devices.map { device in
            AudioDevice(id: device.uniqueID, name: device.localizedName, uid: device.uniqueID)
        }
    }

    func setInputDevice(uid: String?) {
        selectedDeviceUID = uid
    }

    func startCapture(deviceUID: String? = nil) throws {
        guard !isCapturing else { return }

        logger.info("Starting microphone capture with AVCaptureSession...")

        if let deviceUID = deviceUID {
            logger.info("Setting input device: \(deviceUID)")
            selectedDeviceUID = deviceUID
        }

        // Find the capture device
        let device: AVCaptureDevice?
        if let uid = selectedDeviceUID {
            device = AVCaptureDevice.devices(for: .audio).first { $0.uniqueID == uid }
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }

        guard let captureDevice = device else {
            throw NSError(domain: "MicrophoneCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "No audio device found"])
        }

        logger.info("Using capture device: \(captureDevice.localizedName)")

        // Create capture session
        let session = AVCaptureSession()

        // Create input
        let input = try AVCaptureDeviceInput(device: captureDevice)

        // Create output
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)

        // Configure session
        session.beginConfiguration()

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            throw NSError(domain: "MicrophoneCapture", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input"])
        }

        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            throw NSError(domain: "MicrophoneCapture", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output"])
        }

        session.commitConfiguration()

        // Store references
        captureSession = session
        audioOutput = output

        // Start session
        session.startRunning()

        isCapturing = true

        logger.info("Microphone capture started successfully with AVCaptureSession")
    }

    func stopCapture() {
        guard isCapturing else { return }

        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil
        isCapturing = false
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.format != format else { return buffer }

        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else {
            return nil
        }

        return outputBuffer
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func checkPermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate
extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let sampleRate = asbd.pointee.mSampleRate
        let channelCount = asbd.pointee.mChannelsPerFrame
        let bitsPerChannel = asbd.pointee.mBitsPerChannel
        let formatFlags = asbd.pointee.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        // Create output format (Float32, deinterleaved)
        guard let outputPcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            return
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputPcmFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // For non-interleaved audio, we need to use AudioBufferList
        var blockBuffer: CMBlockBuffer?

        // First, get the required size
        var bufferListSizeNeeded: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )

        // Allocate and get the buffer list
        let audioBufferListRawPtr = UnsafeMutableRawPointer.allocate(byteCount: bufferListSizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { audioBufferListRawPtr.deallocate() }
        let audioBufferListPtr = audioBufferListRawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPtr,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return }

        // Copy and convert audio data to PCM buffer
        let ablPtr = UnsafeMutableAudioBufferListPointer(audioBufferListPtr)
        if let floatData = pcmBuffer.floatChannelData {
            if isFloat && bitsPerChannel == 32 {
                // Float32 data - copy from each buffer to each channel
                for i in 0..<ablPtr.count {
                    let audioBuffer = ablPtr[i]
                    if let data = audioBuffer.mData {
                        let srcFloatPtr = data.assumingMemoryBound(to: Float.self)
                        let channelIndex = isNonInterleaved ? i : 0
                        let samplesToProcess = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size

                        if isNonInterleaved {
                            memcpy(floatData[channelIndex], srcFloatPtr, min(frameCount, samplesToProcess) * MemoryLayout<Float>.size)
                        } else {
                            let framesInBuffer = samplesToProcess / Int(channelCount)
                            for frame in 0..<framesInBuffer {
                                for ch in 0..<Int(channelCount) {
                                    floatData[ch][frame] = srcFloatPtr[frame * Int(channelCount) + ch]
                                }
                            }
                        }
                    }
                }
            } else if isSignedInt && bitsPerChannel == 16 {
                // Int16 - convert to Float32
                let scale: Float = 1.0 / 32768.0
                for i in 0..<ablPtr.count {
                    let audioBuffer = ablPtr[i]
                    if let data = audioBuffer.mData {
                        let srcInt16Ptr = data.assumingMemoryBound(to: Int16.self)
                        let channelIndex = isNonInterleaved ? i : 0
                        let samplesToProcess = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size

                        if isNonInterleaved {
                            for frame in 0..<min(frameCount, samplesToProcess) {
                                floatData[channelIndex][frame] = Float(srcInt16Ptr[frame]) * scale
                            }
                        } else {
                            let framesInBuffer = samplesToProcess / Int(channelCount)
                            for frame in 0..<framesInBuffer {
                                for ch in 0..<Int(channelCount) {
                                    floatData[ch][frame] = Float(srcInt16Ptr[frame * Int(channelCount) + ch]) * scale
                                }
                            }
                        }
                    }
                }
            } else if isSignedInt && bitsPerChannel == 32 {
                // Int32 - convert to Float32
                let scale: Float = 1.0 / 2147483648.0
                for i in 0..<ablPtr.count {
                    let audioBuffer = ablPtr[i]
                    if let data = audioBuffer.mData {
                        let srcInt32Ptr = data.assumingMemoryBound(to: Int32.self)
                        let channelIndex = isNonInterleaved ? i : 0
                        let samplesToProcess = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size

                        if isNonInterleaved {
                            for frame in 0..<min(frameCount, samplesToProcess) {
                                floatData[channelIndex][frame] = Float(srcInt32Ptr[frame]) * scale
                            }
                        } else {
                            let framesInBuffer = samplesToProcess / Int(channelCount)
                            for frame in 0..<framesInBuffer {
                                for ch in 0..<Int(channelCount) {
                                    floatData[ch][frame] = Float(srcInt32Ptr[frame * Int(channelCount) + ch]) * scale
                                }
                            }
                        }
                    }
                }
            } else {
                // Unsupported format
                return
            }
        }

        // Convert to output format if needed
        if let convertedBuffer = convertBuffer(pcmBuffer, to: outputFormat) {
            delegate?.microphoneCapture(self, didReceiveAudioBuffer: convertedBuffer)
        } else {
            delegate?.microphoneCapture(self, didReceiveAudioBuffer: pcmBuffer)
        }
    }
}
