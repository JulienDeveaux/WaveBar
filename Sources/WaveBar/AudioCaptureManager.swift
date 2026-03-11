import AVFoundation
import Foundation
import ScreenCaptureKit

final class AudioCaptureManager: NSObject, @unchecked Sendable {
    enum Status: String {
        case idle = "Idle"
        case requestingPermission = "Requesting permission..."
        case capturing = "Capturing system audio"
        case permissionDenied = "Screen Recording permission required"
        case error = "Error"
        case micFallback = "Using microphone (fallback)"
    }

    /// Thread-safe shared sample buffer
    private(set) var currentSamples: [Float] {
        get { samplesLock.withLock { _samples } }
        set { samplesLock.withLock { _samples = newValue } }
    }
    private var _samples = [Float]()
    private let samplesLock = NSLock()

    /// Status updated on main thread
    var onStatusChanged: ((Status) -> Void)?

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.wavebar.audio", qos: .userInteractive)
    private let bufferSize = 2048

    // Microphone fallback
    private var audioEngine: AVAudioEngine?

    func startCapture() {
        Task {
            await requestAndStartScreenCapture()
        }
    }

    func stopCapture() {
        if let stream = stream {
            Task {
                try? await stream.stopCapture()
            }
            self.stream = nil
        }
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    // MARK: - ScreenCaptureKit

    private func requestAndStartScreenCapture() async {
        updateStatus(.requestingPermission)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            guard let display = content.displays.first else {
                print("WaveBar: No display found")
                updateStatus(.error)
                startMicrophoneFallback()
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.channelCount = 1
            config.sampleRate = 44100
            // Minimize video overhead
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()

            self.stream = stream
            updateStatus(.capturing)
            print("WaveBar: System audio capture started")

        } catch {
            let nsError = error as NSError
            print("WaveBar: ScreenCaptureKit error: \(nsError.domain) \(nsError.code) - \(error.localizedDescription)")

            if nsError.code == -3801 || nsError.domain == "com.apple.ScreenCaptureKit" {
                updateStatus(.permissionDenied)
                showPermissionAlert()
            } else {
                updateStatus(.error)
            }
            startMicrophoneFallback()
        }
    }

    // MARK: - Microphone Fallback

    private func startMicrophoneFallback() {
        print("WaveBar: Falling back to microphone input")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            let frameCount = Int(buffer.frameLength)
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            self.appendSamples(samples)
        }

        do {
            try engine.start()
            self.audioEngine = engine
            updateStatus(.micFallback)
            print("WaveBar: Microphone fallback active")
        } catch {
            print("WaveBar: Microphone fallback failed: \(error)")
            updateStatus(.error)
        }
    }

    // MARK: - Permission Alert

    private func showPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = """
                WaveBar needs Screen Recording permission to visualize system audio.

                Click "Open Settings" to grant permission, then restart WaveBar.

                In the meantime, WaveBar will use microphone input as a fallback.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Continue with Mic")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - Sample Processing

    private func appendSamples(_ newSamples: [Float]) {
        samplesLock.lock()
        _samples.append(contentsOf: newSamples)
        if _samples.count > bufferSize {
            _samples = Array(_samples.suffix(bufferSize))
        }
        samplesLock.unlock()
    }

    private func updateStatus(_ status: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(status)
        }
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)

        let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)
        guard status == kCMBlockBufferNoErr else { return }

        appendSamples(data)
    }
}

// MARK: - SCStreamDelegate

extension AudioCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("WaveBar: Stream stopped with error: \(error)")
        updateStatus(.error)
    }
}
