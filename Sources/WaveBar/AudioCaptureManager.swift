import AppKit
import AVFoundation
import CoreAudio
import Foundation

final class AudioCaptureManager: NSObject, @unchecked Sendable {
    enum Status: String {
        case idle = "Idle"
        case capturing = "Capturing system audio"
        case error = "Error"
        case reconnecting = "Reconnecting..."
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
    private var healthCheckTimer: Timer?
    private var isRestarting = false
    private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    func startCapture() {
        listenForWake()
        startProcessTap()
        startHealthCheck()
        // Register output device listener after a short delay so the initial
        // aggregate device creation doesn't trigger a spurious restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.listenForOutputDeviceChanges()
        }
    }

    func stopCapture() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        removeOutputDeviceListener()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        tearDownAudioEngine()
        cleanup()
    }

    // MARK: - CoreAudio Process Tap

    private func startProcessTap() {
        tearDownAudioEngine()
        cleanup()

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

            if channelCount >= 2, let ch0 = buffer.floatChannelData?[0], let ch1 = buffer.floatChannelData?[1] {
                let mono = [Float](unsafeUninitializedCapacity: frameCount) { buf, count in
                    for i in 0..<frameCount {
                        buf[i] = (ch0[i] + ch1[i]) * 0.5
                    }
                    count = frameCount
                }
                self.appendSamples(mono)
            } else if let ch0 = buffer.floatChannelData?[0] {
                self.appendSamples(UnsafeBufferPointer(start: ch0, count: frameCount))
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
            updateStatus(.capturing)
            print("WaveBar: Audio engine started successfully")
        } catch {
            print("WaveBar: Failed to start engine: \(error)")
            cleanup()
            updateStatus(.error)
        }
    }

    // MARK: - Auto-Recovery

    /// Listen for default output device changes via CoreAudio property listener
    private func listenForOutputDeviceChanges() {
        guard outputDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            print("WaveBar: Default output device changed, restarting capture...")
            self?.restartCapture()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )

        if status == noErr {
            outputDeviceListenerBlock = block
        } else {
            print("WaveBar: Failed to add output device listener: \(status)")
        }
    }

    private func removeOutputDeviceListener() {
        guard let block = outputDeviceListenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        outputDeviceListenerBlock = nil
    }

    private func listenForWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleWake(_ notification: Notification) {
        print("WaveBar: System woke from sleep, restarting capture...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.restartCapture()
        }
    }

    private func restartCapture() {
        guard !isRestarting else { return }
        isRestarting = true
        updateStatus(.reconnecting)

        removeOutputDeviceListener()
        tearDownAudioEngine()
        cleanup()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.startProcessTap()
            self.isRestarting = false
            // Re-register after the engine has settled
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.listenForOutputDeviceChanges()
            }
        }
    }

    /// Periodic check: if the engine stopped unexpectedly, restart
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isRestarting else { return }
            if let engine = self.audioEngine, !engine.isRunning {
                print("WaveBar: Health check — engine stopped, restarting...")
                self.restartCapture()
            } else if self.audioEngine == nil && self.tapID == 0 {
                print("WaveBar: Health check — no active session, restarting...")
                self.restartCapture()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    // MARK: - Helpers

    private func tearDownAudioEngine() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
    }

    private func appendSamples(_ newSamples: [Float]) {
        samplesLock.lock()
        _samples.append(contentsOf: newSamples)
        if _samples.count > bufferSize {
            _samples.removeFirst(_samples.count - bufferSize)
        }
        samplesLock.unlock()
    }

    private func appendSamples(_ newSamples: UnsafeBufferPointer<Float>) {
        samplesLock.lock()
        _samples.append(contentsOf: newSamples)
        if _samples.count > bufferSize {
            _samples.removeFirst(_samples.count - bufferSize)
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
