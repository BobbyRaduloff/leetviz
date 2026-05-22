import Accelerate
import Foundation

/// Real-to-complex FFT with band binning, log scaling, and per-frame smoothing.
///
/// Tweakable bits (search for the comments):
///   - `fftSize`       (init arg)   FFT window length. Larger = better freq
///                                  resolution but more latency.
///   - `bandCount`     (init arg)   Number of bars produced for the visualizer.
///   - `attackSmoothing`            How fast bars rise (0 = instant).
///   - `decay`                      How fast bars fall when input drops.
///   - `normDivisor`   (in process) Overall gain after log scaling.
///   - `minHz`         (in process) Lowest frequency the visualizer cares about.
final class FFTProcessor {
    private let fftSize: Int
    private let log2N: vDSP_Length
    private var bandCount: Int
    private let sampleRate: Float

    /// Smoothing applied on attack (new > previous). 0 = instant, 1 = frozen.
    /// Higher = less jitter, more lag. Lower = more transient detail (drum hits
    /// punch through, vocals dance). 0.30 keeps it responsive without strobing.
    var attackSmoothing: Float = 0.30
    /// Multiplied into the previous value each frame when input drops.
    /// Closer to 1 = slower decay. 0.80 lets bars fall fast enough that
    /// successive snare hits actually look distinct.
    var decay: Float = 0.80

    private var fftSetup: FFTSetup
    private var window: [Float]
    private var smoothedBands: [Float]
    /// Per-band perceptual gain. Music has way more energy in the bass than the
    /// highs, so without compensation a kick drum dominates and hi-hats vanish.
    /// We attenuate the lows and boost the highs along a gentle ramp. Tune the
    /// endpoints in `makeBandGains` to taste.
    private var bandGains: [Float]

    init(fftSize: Int = 1024, bandCount: Int = 16, sampleRate: Float = 48_000) {
        precondition(fftSize > 0 && (fftSize & (fftSize - 1)) == 0, "fftSize must be a power of two")
        self.fftSize = fftSize
        self.log2N = vDSP_Length(log2(Float(fftSize)))
        self.bandCount = bandCount
        self.sampleRate = sampleRate
        self.smoothedBands = [Float](repeating: 0, count: bandCount)
        self.bandGains = FFTProcessor.makeBandGains(count: bandCount)
        self.window = [Float](repeating: 0, count: fftSize)
        // Hann window — gives up a touch of frequency resolution for far less
        // spectral leakage, which keeps bars from twitching on steady tones.
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.fftSetup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2))!
    }

    private static func makeBandGains(count: Int) -> [Float] {
        // Bass: 0.22  →  Treble: 2.20. The ramp uses pow(frac, 0.7) so the
        // attenuation in the low end is more aggressive than a straight line,
        // tames the kick drum dominance you get with un-weighted FFT magnitudes.
        let bassGain: Float = 0.22
        let trebleGain: Float = 2.20
        return (0..<count).map { i in
            let frac = Float(i) / Float(max(1, count - 1))
            let curved = powf(frac, 0.7)
            return bassGain + curved * (trebleGain - bassGain)
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func setBandCount(_ count: Int) {
        guard count > 0, count != bandCount else { return }
        bandCount = count
        smoothedBands = [Float](repeating: 0, count: count)
    }

    /// Feed a rolling buffer of mono samples; returns smoothed band magnitudes
    /// roughly in 0...1. Pass a buffer of at least `fftSize` samples — the
    /// processor uses the most recent `fftSize` of them.
    func process(samples: [Float]) -> [Float] {
        guard samples.count >= fftSize else { return smoothedBands }

        // Window the most recent fftSize samples.
        var windowed = Array(samples.suffix(fftSize))
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack the real signal into split-complex form for vDSP, run forward FFT,
        // then take magnitude squared per bin.
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)

        var mags = real.withUnsafeMutableBufferPointer { rPtr -> [Float] in
            imag.withUnsafeMutableBufferPointer { iPtr -> [Float] in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let cmplx = raw.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ctoz(cmplx, 2, &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2N, FFTDirection(FFT_FORWARD))
                var m = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvmags(&split, 1, &m, 1, vDSP_Length(fftSize / 2))
                return m
            }
        }

        // log10(1 + |Z|²) — keeps loud transients from blowing out the meters
        // while still showing quiet content.
        for i in 0..<mags.count {
            mags[i] = log10f(1 + mags[i])
        }

        // Aggregate into log-spaced bands. We skip everything below `minHz`
        // (sub-bass rumble that isn't useful) and stop at Nyquist.
        let nyquist = sampleRate / 2
        let minHz: Float = 40
        let maxHz: Float = nyquist
        let binWidth = nyquist / Float(mags.count)

        var newBands = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let lowFrac = Float(i) / Float(bandCount)
            let highFrac = Float(i + 1) / Float(bandCount)
            let lowHz  = minHz * powf(maxHz / minHz, lowFrac)
            let highHz = minHz * powf(maxHz / minHz, highFrac)
            let lowBin  = max(1, Int(lowHz / binWidth))
            let highBin = max(lowBin + 1, Int(highHz / binWidth))
            var sum: Float = 0
            var n: Float = 0
            for b in lowBin..<min(highBin, mags.count) {
                sum += mags[b]
                n += 1
            }
            newBands[i] = n > 0 ? sum / n : 0
        }

        // Apply per-band perceptual gain (bass attenuation / treble boost).
        for i in 0..<bandCount {
            newBands[i] *= bandGains[i]
        }

        // Normalize + soft-clip. `normDivisor` controls overall sensitivity;
        // the soft-clip curve `1 - exp(-x * k)` asymptotes at 1 (so peaks reach
        // the top instead of capping flat halfway up) while expanding the
        // mid-range so loud bars look meaningfully taller than quiet ones.
        // Lower `normDivisor` = more sensitive; lower `softClipK` = more "drama".
        let normDivisor: Float = 3.2
        let softClipK: Float = 1.8
        for i in 0..<bandCount {
            let x = max(0, newBands[i] / normDivisor)
            newBands[i] = 1 - expf(-x * softClipK)
        }

        // Asymmetric smoothing: fast on the way up, slow on the way down.
        // Mirrors how peak meters feel to the eye.
        for i in 0..<bandCount {
            let prev = smoothedBands[i]
            let next = newBands[i]
            if next > prev {
                smoothedBands[i] = prev + (next - prev) * (1 - attackSmoothing)
            } else {
                smoothedBands[i] = prev * decay
            }
        }

        return smoothedBands
    }
}
