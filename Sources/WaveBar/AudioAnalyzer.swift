import Accelerate
import Foundation

final class AudioAnalyzer {
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let bandCount: Int
    private var window: [Float]
    private var smoothedBands: [Float]

    /// Per-band peak tracking for auto-normalization
    private var peakBands: [Float]
    private let peakDecay: Float = 0.995

    /// Sensitivity multiplier (higher = more reactive)
    var sensitivity: Float = 1.0

    /// Smoothing factors: fast attack, slow decay
    private let attackFactor: Float = 0.5
    private let decayFactor: Float = 0.15

    init(fftSize: Int = 1024, bandCount: Int = 16) {
        self.fftSize = fftSize
        self.bandCount = bandCount
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        self.smoothedBands = [Float](repeating: 0, count: bandCount)
        self.peakBands = [Float](repeating: 0.001, count: bandCount)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Takes raw PCM float samples and returns normalized frequency band magnitudes (0...1)
    func analyze(samples: [Float]) -> [Float] {
        guard samples.count >= fftSize else {
            return smoothedBands
        }

        let input = Array(samples.suffix(fftSize))

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let halfN = fftSize / 2
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                windowed.withUnsafeBufferPointer { bufPtr in
                    bufPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        // Scale
        var scaleFactor: Float = 1.0 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scaleFactor, &magnitudes, 1, vDSP_Length(halfN))

        // Square root for amplitude
        var count = Int32(halfN)
        vvsqrtf(&magnitudes, magnitudes, &count)

        // Group into logarithmic frequency bands
        let rawBands = groupIntoBands(magnitudes: magnitudes)

        // Per-band auto-normalization + smoothing
        for i in 0..<bandCount {
            // Track peaks with slow decay
            peakBands[i] *= peakDecay
            if rawBands[i] > peakBands[i] {
                peakBands[i] = rawBands[i]
            }
            // Ensure minimum peak to avoid division issues
            let peak = max(peakBands[i], 0.0001)

            // Normalize each band relative to its own peak, apply sensitivity
            let normalized = min(1.0, (rawBands[i] * sensitivity) / peak)

            // Apply slight curve for more dynamic range in the visual
            let curved = pow(normalized, 0.7)

            // Smooth
            if curved > smoothedBands[i] {
                smoothedBands[i] += (curved - smoothedBands[i]) * attackFactor
            } else {
                smoothedBands[i] += (curved - smoothedBands[i]) * decayFactor
            }
        }

        return smoothedBands
    }

    private func groupIntoBands(magnitudes: [Float]) -> [Float] {
        let binCount = magnitudes.count
        var bands = [Float](repeating: 0, count: bandCount)

        let minFreq: Float = 40.0
        let maxFreq: Float = 16000.0
        let sampleRate: Float = 44100.0
        let binResolution = sampleRate / Float(fftSize)

        for band in 0..<bandCount {
            let lowFreq = minFreq * pow(maxFreq / minFreq, Float(band) / Float(bandCount))
            let highFreq = minFreq * pow(maxFreq / minFreq, Float(band + 1) / Float(bandCount))

            let lowBin = max(1, Int(lowFreq / binResolution))
            let highBin = min(binCount - 1, Int(highFreq / binResolution))

            if highBin >= lowBin {
                var maxVal: Float = 0
                for bin in lowBin...highBin {
                    maxVal = max(maxVal, magnitudes[bin])
                }
                bands[band] = maxVal
            }
        }

        return bands
    }
}
