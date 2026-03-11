import AVFoundation
import CoreAudio
import Foundation

final class AudioCaptureManager: NSObject, @unchecked Sendable {
    enum Status: String {
        case idle = "Idle"
        case capturing = "Capturing system audio"
        case error = "Error"
    }

    /// Thread-safe shared sample buffer
    private(set) var currentSamples: [Float] {
        get { samplesLock.withLock { _samples } }
        set { samplesLock.withLock { _samples = newValue } }
    }
    private var _samples = [Float]()
    private let samplesLock = NSLock()

    var onStatusChanged: ((Status) -> Void)?

    private var tapID: AudioObjectID = 0
    private var aggDeviceID: AudioDeviceID = 0
    private var audioEngine: AVAudioEngine?
    private var tapDesc: CATapDescription?
    private let bufferSize = 2048

    func startCapture() {
        startProcessTap()
    }

    func stopCapture() {
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        cleanup()
    }

    // MARK: - CoreAudio Process Tap

    private func startProcessTap() {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "WaveBar"
        self.tapDesc = desc

        var newTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard tapStatus == 0 else {
            print("WaveBar: Failed to create process tap: \(tapStatus)")
            updateStatus(.error)
            return
        }
        self.tapID = newTapID

        let aggDesc: CFDictionary = [
            kAudioAggregateDeviceNameKey: "WaveBar",
            kAudioAggregateDeviceUIDKey: "com.wavebar.agg.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString]
            ],
        ] as CFDictionary

        var newAggID: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc, &newAggID)
        guard aggStatus == 0 else {
            print("WaveBar: Failed to create aggregate device: \(aggStatus)")
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            updateStatus(.error)
            return
        }
        self.aggDeviceID = newAggID

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        var deviceID = aggDeviceID
        let setStatus = AudioUnitSetProperty(
            inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setStatus == 0 else {
            print("WaveBar: Failed to set input device: \(setStatus)")
            cleanup()
            updateStatus(.error)
            return
        }

        let nativeFormat = inputNode.inputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            let channelCount = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frameCount)

            if channelCount >= 2, let ch0 = buffer.floatChannelData?[0], let ch1 = buffer.floatChannelData?[1] {
                for i in 0..<frameCount {
                    mono[i] = (ch0[i] + ch1[i]) * 0.5
                }
            } else if let ch0 = buffer.floatChannelData?[0] {
                mono = Array(UnsafeBufferPointer(start: ch0, count: frameCount))
            }

            self.appendSamples(mono)
        }

        do {
            try engine.start()
            self.audioEngine = engine
            updateStatus(.capturing)
            print("WaveBar: Audio engine started")
        } catch {
            print("WaveBar: Failed to start engine: \(error)")
            cleanup()
            updateStatus(.error)
        }
    }

    // MARK: - Helpers

    private func appendSamples(_ newSamples: [Float]) {
        samplesLock.lock()
        _samples.append(contentsOf: newSamples)
        if _samples.count > bufferSize {
            _samples = Array(_samples.suffix(bufferSize))
        }
        samplesLock.unlock()
    }

    private func cleanup() {
        if aggDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggDeviceID)
            aggDeviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    private func updateStatus(_ status: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(status)
        }
    }
}
