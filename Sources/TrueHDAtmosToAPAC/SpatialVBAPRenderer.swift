import Foundation
import AVFAudio

/// Real-time 3D Dual-Layer VBAP (Vector Base Amplitude Panning) spatial renderer.
///
/// Renders decoded Dolby TrueHD Atmos signals (7.1.2 beds + up to 128 dynamic 3D objects with OAMD metadata)
/// into a 12-channel (`kAudioChannelLayoutTag_Atmos_7_1_4`) or 16-channel (`kAudioChannelLayoutTag_Atmos_9_1_6`)
/// floating-point PCM stream ready for hardware/system APAC encoding.
///
/// Includes sample-accurate linear gain ramping across blocks to prevent zipper noise on fast-moving overhead objects.
public final class SpatialVBAPRenderer {
    public let targetLayout: AtmosTargetLayout
    public let sampleRate: Double
    public let speakers: [SpeakerPosition3D]

    /// Previous block's computed speaker gains per object `[objectID: [Float]]` for click-free sample interpolation.
    private var previousGainsByObject: [Int: [Float]] = [:]

    public init(targetLayout: AtmosTargetLayout = .atmos7_1_4, sampleRate: Double = 48000.0) {
        self.targetLayout = targetLayout
        self.sampleRate = sampleRate
        self.speakers = Self.buildSpeakerPositions(for: targetLayout)
    }

    /// Resets the internal gain interpolation state (e.g., on seek or stream flush).
    public func reset() {
        previousGainsByObject.removeAll()
    }

    /// Renders a `TrueHDAtmosBlock` (beds + dynamic 3D objects) into an `AVAudioPCMBuffer`
    /// matching the target Atmos layout (`7.1.4` or `9.1.6`).
    public func render(block: TrueHDAtmosBlock, into outputBuffer: AVAudioPCMBuffer) {
        let frames = block.frameCount
        let numOutChannels = targetLayout.channelCount
        outputBuffer.frameLength = AVAudioFrameCount(frames)

        guard let outChannels = outputBuffer.floatChannelData else { return }

        // Zero-initialize output channels
        for ch in 0..<numOutChannels {
            memset(outChannels[ch], 0, frames * MemoryLayout<Float>.size)
        }

        let invFrames = frames > 1 ? (1.0 / Float(frames)) : 1.0

        for (sigIdx, samples) in block.signals.enumerated() {
            guard sigIdx < block.metadata.count else { continue }
            let meta = block.metadata[sigIdx]
            let targetGains = computeSpeakerGains(for: meta)
            let startGains = previousGainsByObject[meta.objectID] ?? targetGains
            previousGainsByObject[meta.objectID] = targetGains

            // Mix object into active output channels with sample-by-sample gain ramping
            for ch in 0..<numOutChannels {
                let g0 = startGains[ch]
                let g1 = targetGains[ch]
                if g0 < 1e-6 && g1 < 1e-6 { continue }

                let outPtr = outChannels[ch]
                let step = (g1 - g0) * invFrames
                var currentGain = g0
                for i in 0..<frames {
                    outPtr[i] += samples[i] * currentGain
                    currentGain += step
                }
            }
        }
    }

    /// Computes power-preserving 3D speaker gains (constant-power dual-layer Floor + Height panning)
    /// for a given OAMD 3D object position `(x, y, z)`.
    public func computeSpeakerGains(for meta: OAMDObjectMetadata) -> [Float] {
        let numChannels = targetLayout.channelCount
        var gains = [Float](repeating: 0.0, count: numChannels)

        guard meta.linearGain > 0.0 else { return gains }

        // 1. Direct LFE routing
        if meta.isLFE {
            gains[3] = meta.linearGain // Channel 3 is LFE in both Atmos 7.1.4 and 9.1.6
            return gains
        }

        // 2. Pinned Bed channel routing
        if let bedCh = meta.pinnedBedChannel, bedCh >= 0 && bedCh < numChannels {
            gains[bedCh] = meta.linearGain
            return gains
        }

        // 3. 3D Dual-Layer Constant-Power Panning (Floor Layer z=0 vs Height Layer z=1)
        // Elevation angle in [0, pi/2] controlled by z in [0, 1]
        let elevAngle = meta.z * (.pi * 0.5)
        let floorLayerGain = cos(elevAngle)
        let heightLayerGain = sin(elevAngle)

        // Compute horizontal weights within the Floor layer (z == 0)
        if floorLayerGain > 1e-5 {
            let floorWeights = compute2DLayerWeights(x: meta.x, y: meta.y, isHeightLayer: false, spread: meta.spread)
            for (ch, w) in floorWeights {
                gains[ch] += w * floorLayerGain * meta.linearGain
            }
        }

        // Compute overhead weights within the Height/Top layer (z == 1)
        if heightLayerGain > 1e-5 {
            let heightWeights = compute2DLayerWeights(x: meta.x, y: meta.y, isHeightLayer: true, spread: meta.spread)
            for (ch, w) in heightWeights {
                gains[ch] += w * heightLayerGain * meta.linearGain
            }
        }

        // Power normalization across all active speakers so total energy equals meta.linearGain^2
        var energySum: Float = 0.0
        for g in gains { energySum += g * g }
        if energySum > 1e-8 {
            let norm = meta.linearGain / sqrt(energySum)
            for i in 0..<numChannels {
                gains[i] *= norm
            }
        }

        return gains
    }

    private func compute2DLayerWeights(
        x: Float,
        y: Float,
        isHeightLayer: Bool,
        spread: Float
    ) -> [(Int, Float)] {
        let layerSpeakers = speakers.filter { spk in
            if spk.isLFE { return false }
            return isHeightLayer ? (spk.z > 0.5) : (spk.z <= 0.5)
        }

        var rawWeights = [(Int, Float)]()
        rawWeights.reserveCapacity(layerSpeakers.count)

        // Inverse-distance / directional cosine panning on the 2D layer with spread control
        let sharpness: Float = max(1.0, 6.0 * (1.0 - spread * 0.8))

        for spk in layerSpeakers {
            let dx = x - spk.x
            let dy = y - spk.y
            let distSq = dx * dx + dy * dy
            if distSq < 1e-5 {
                // Exact hit on speaker
                return [(spk.channelIndex, 1.0)]
            }
            // Clamped proximity kernel
            let dist = sqrt(distSq)
            let proximity = max(0.0, 1.0 - (dist / 1.85))
            if proximity > 0.0 {
                let weight = pow(proximity, sharpness)
                if weight > 1e-5 {
                    rawWeights.append((spk.channelIndex, weight))
                }
            }
        }

        // Fallback if object is in the center of the ceiling/room equidistant from speakers
        if rawWeights.isEmpty {
            for spk in layerSpeakers {
                let dx = x - spk.x
                let dy = y - spk.y
                let w = 1.0 / (0.1 + dx * dx + dy * dy)
                rawWeights.append((spk.channelIndex, w))
            }
        }

        return rawWeights
    }

    public static func buildSpeakerPositions(for layout: AtmosTargetLayout) -> [SpeakerPosition3D] {
        switch layout {
        case .atmos7_1_4:
            // CoreAudio kAudioChannelLayoutTag_Atmos_7_1_4 order:
            // L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr
            return [
                SpeakerPosition3D(channelIndex: 0,  name: "L",   x: -1.0, y:  1.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 1,  name: "R",   x:  1.0, y:  1.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 2,  name: "C",   x:  0.0, y:  1.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 3,  name: "LFE", x:  0.0, y:  1.0, z: 0.0, isLFE: true),
                SpeakerPosition3D(channelIndex: 4,  name: "Ls",  x: -1.0, y:  0.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 5,  name: "Rs",  x:  1.0, y:  0.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 6,  name: "Rls", x: -1.0, y: -1.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 7,  name: "Rrs", x:  1.0, y: -1.0, z: 0.0),
                // Height channels (z = 1.0)
                SpeakerPosition3D(channelIndex: 8,  name: "Vhl", x: -0.8, y:  0.8, z: 1.0),
                SpeakerPosition3D(channelIndex: 9,  name: "Vhr", x:  0.8, y:  0.8, z: 1.0),
                SpeakerPosition3D(channelIndex: 10, name: "Ltr", x: -0.8, y: -0.8, z: 1.0),
                SpeakerPosition3D(channelIndex: 11, name: "Rtr", x:  0.8, y: -0.8, z: 1.0)
            ]

        case .atmos9_1_6:
            // CoreAudio kAudioChannelLayoutTag_Atmos_9_1_6 order:
            // L R C LFE Ls Rs Rls Rrs Lw Rw Vhl Vhr Ltm Rtm Ltr Rtr
            return [
                SpeakerPosition3D(channelIndex: 0,  name: "L",   x: -1.0, y:  1.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 1,  name: "R",   x:  1.0, y:  1.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 2,  name: "C",   x:  0.0, y:  1.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 3,  name: "LFE", x:  0.0, y:  1.0, z: 0.0, isLFE: true),
                SpeakerPosition3D(channelIndex: 4,  name: "Ls",  x: -1.0, y:  0.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 5,  name: "Rs",  x:  1.0, y:  0.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 6,  name: "Rls", x: -1.0, y: -1.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 7,  name: "Rrs", x:  1.0, y: -1.0, z: 0.0),
                SpeakerPosition3D(channelIndex: 8,  name: "Lw",  x: -1.0, y:  0.5, z: 0.0),
                SpeakerPosition3D(channelIndex: 9,  name: "Rw",  x:  1.0, y:  0.5, z: 0.0),
                // Height channels (z = 1.0)
                SpeakerPosition3D(channelIndex: 10, name: "Vhl", x: -0.8, y:  0.8, z: 1.0),
                SpeakerPosition3D(channelIndex: 11, name: "Vhr", x:  0.8, y:  0.8, z: 1.0),
                SpeakerPosition3D(channelIndex: 12, name: "Ltm", x: -0.8, y:  0.0, z: 1.0),
                SpeakerPosition3D(channelIndex: 13, name: "Rtm", x:  0.8, y:  0.0, z: 1.0),
                SpeakerPosition3D(channelIndex: 14, name: "Ltr", x: -0.8, y: -0.8, z: 1.0),
                SpeakerPosition3D(channelIndex: 15, name: "Rtr", x:  0.8, y: -0.8, z: 1.0)
            ]
        }
    }
}

