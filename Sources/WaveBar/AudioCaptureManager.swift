import AppKit
import AVFoundation
import CoreAudio
import Foundation

final class AudioCaptureManager: NSObject, @unchecked Sendable {
    enum Status: String {
        case idle = "Idle"
        case capturing = "Capturing system audio"
        case needsPermission = "Waiting for permission..."
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

    // Permission detection
    private var hasShownPermissionAlert = false
    private var gotAudio = false
    private var permissionCheckTimer: Timer?
    private var retryTimer: Timer?

    func startCapture() {
        startProcessTap()
        // First: silently retry once after 2s (covers relaunch where permission is already granted)
        // Only show the popup if still no audio after the retry
        DispatchQueue.main.async { [weak self] in
            self?.permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self, !self.gotAudio else { return }
                // Permission might be granted but tap was stale — retry first
                print("WaveBar: No audio yet, retrying before showing alert...")
                self.restartCapture()
                // Give the retry 1.5s, then show alert if still silent
                Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    self?.checkIfGotAudio()
                }
            }
        }
    }

    func stopCapture() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        if aggDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggDeviceID)
            aggDeviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
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

            // Mix stereo to mono
            let channelCount = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frameCount)

            if channelCount >= 2, let ch0 = buffer.floatChannelData?[0], let ch1 = buffer.floatChannelData?[1] {
                for i in 0..<frameCount {
                    mono[i] = (ch0[i] + ch1[i]) * 0.5
                }
            } else if let ch0 = buffer.floatChannelData?[0] {
                mono = Array(UnsafeBufferPointer(start: ch0, count: frameCount))
            }

            // Track if we ever get real audio
            if !self.gotAudio {
                var maxVal: Float = 0
                for s in mono { maxVal = max(maxVal, abs(s)) }
                if maxVal > 0.0001 {
                    self.gotAudio = true
                    self.updateStatus(.capturing)
                }
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

    // MARK: - Permission Check

    private func checkIfGotAudio() {
        guard !gotAudio else { return }

        if !hasShownPermissionAlert {
            hasShownPermissionAlert = true
            updateStatus(.needsPermission)
            showPermissionAlert()
        }

        // Retry every 3 seconds: tear down and recreate the tap
        // (the tap created before permission was granted stays silent forever)
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.gotAudio {
                timer.invalidate()
                self.retryTimer = nil
                return
            }
            print("WaveBar: Retrying audio capture...")
            self.restartCapture()
        }
    }

    private func restartCapture() {
        // Tear down existing
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        cleanup()

        // Recreate
        startProcessTap()
    }

    // MARK: - Permission Alert

    private func showPermissionAlert() {
        DispatchQueue.main.async {
            // Bring app to front so alert is visible (needed for LSUIElement apps)
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "System Audio Permission Required"
            alert.informativeText = """
                WaveBar needs permission to capture system audio.

                1. Click "Open Settings"
                2. Click the "+" button
                3. Navigate to WaveBar.app and add it
                4. Toggle WaveBar ON

                WaveBar will start visualizing automatically once granted.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Open Privacy & Security > Audio Capture
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)

            }
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
