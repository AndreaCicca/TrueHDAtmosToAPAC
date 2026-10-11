import Foundation

/// Protocol for any source that decodes a Dolby TrueHD Atmos stream (Presentation 3 / Substream 4)
/// into discrete bed/object waveforms and 3D OAMD coordinates.
public protocol TrueHDAtmosStreamSource {
    var sampleRate: Double { get }
    /// Pulls the next decoded Access Unit or coalesced block of TrueHD Atmos audio + 3D OAMD metadata.
    mutating func nextBlock() -> TrueHDAtmosBlock?
}

/// Real-time synthetic generator of a Dolby TrueHD Atmos Presentation 3 stream.
///
/// Simulates a 7.1 bed plus dynamic 3D overhead objects (moving in a circle across the ceiling
/// `z = 1.0` through `Vhl`, `Vhr`, `Rtr`, `Ltr`) using TrueHD Access Unit timing (multiples of 40 samples at 48 kHz).
public struct SyntheticTrueHDAtmosSource: TrueHDAtmosStreamSource {
    public let sampleRate: Double = 48000.0
    public let totalDurationSeconds: Double
    public let blockFrameCount: Int // 160 samples = 4 TrueHD Access Units (3.33 ms)

    private var currentSample: Int = 0
    private var totalSamples: Int { Int(totalDurationSeconds * sampleRate) }

    public init(durationSeconds: Double = 3.0, accessUnitsPerBlock: Int = 4) {
        self.totalDurationSeconds = durationSeconds
        self.blockFrameCount = 40 * max(1, accessUnitsPerBlock)
    }

    public mutating func nextBlock() -> TrueHDAtmosBlock? {
        guard currentSample < totalSamples else { return nil }
        let frames = min(blockFrameCount, totalSamples - currentSample)

        var sig0 = [Float](repeating: 0.0, count: frames)
        var sig1 = [Float](repeating: 0.0, count: frames)
        var sig2 = [Float](repeating: 0.0, count: frames)
        var sig3 = [Float](repeating: 0.0, count: frames)

        for i in 0..<frames {
            let t = Double(currentSample + i) / sampleRate
            sig0[i] = Float(sin(2.0 * .pi * 220.0 * t)) * 0.35
            sig1[i] = Float(sin(2.0 * .pi * 60.0 * t)) * 0.25
            sig2[i] = Float(sin(2.0 * .pi * 550.0 * t)) * 0.50
            sig3[i] = Float(sin(2.0 * .pi * 880.0 * t)) * 0.45
        }

        let midTime = (Double(currentSample) + Double(frames) * 0.5) / sampleRate
        let orbitAngle = Float(2.0 * .pi * (midTime / max(0.5, totalDurationSeconds)))
        let obj1X = 0.8 * cos(orbitAngle)
        let obj1Y = 0.8 * sin(orbitAngle)
        let obj1Z: Float = 1.0

        let metadata: [OAMDObjectMetadata] = [
            OAMDObjectMetadata(objectID: 0, x: 0.0, y: 1.0, z: 0.0, linearGain: 1.0, pinnedBedChannel: 2),
            OAMDObjectMetadata(objectID: 1, x: 0.0, y: 1.0, z: 0.0, linearGain: 1.0, isLFE: true),
            OAMDObjectMetadata(objectID: 2, x: obj1X, y: obj1Y, z: obj1Z, linearGain: 1.0, spread: 0.05),
            OAMDObjectMetadata(objectID: 3, x: 0.8, y: -0.8, z: 1.0, linearGain: 1.0, spread: 0.0)
        ]

        currentSample += frames
        return TrueHDAtmosBlock(
            frameCount: frames,
            sampleRate: sampleRate,
            signals: [sig0, sig1, sig2, sig3],
            metadata: metadata
        )
    }
}
