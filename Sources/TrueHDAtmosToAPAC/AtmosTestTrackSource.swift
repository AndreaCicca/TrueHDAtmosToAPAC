import Foundation

/// Built-in spatial audio test track presets designed to test Dolby TrueHD Atmos -> 3D VBAP -> APAC -> Dolby MAT 2.0.
public enum AtmosTestTrackPreset: String, CaseIterable, Identifiable, Sendable {
    case channelSweep = "channel_sweep"
    case singleChannel = "single_channel"
    case ceilingOrbit = "ceiling_orbit"
    case elevationSweep = "elevation_sweep"
    case frontToBackFlyover = "front_to_back"
    case domeSpiral = "dome_spiral"
    case lfeSubTest = "lfe_sub"
    case fullAtmosDemo = "full_atmos_demo"
    case manualObject3D = "manual_object_3d"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .channelSweep:
            return "Giro Canali Singoli (Speaker Walk)"
        case .singleChannel:
            return "Isolamento Singolo Diffusore"
        case .ceilingOrbit:
            return "Oggetto 3D in Orbita sul Soffitto (z = 1.0)"
        case .elevationSweep:
            return "Sweep di Elevazione Floor ↔ Height"
        case .frontToBackFlyover:
            return "Sorvolo Orizzontale Fronte ↔ Retro"
        case .domeSpiral:
            return "Spirale 3D Emisferica (Pavimento → Soffitto)"
        case .lfeSubTest:
            return "Test Subwoofer LFE (30–90 Hz Sweep + Pulse)"
        case .fullAtmosDemo:
            return "Scena Completa TrueHD Atmos (Bed 7.1 + Oggetti 3D)"
        case .manualObject3D:
            return "Posizionamento Manuale Oggetto 3D (X, Y, Z)"
        }
    }

    public var subtitle: String {
        switch self {
        case .channelSweep:
            return "Attiva in sequenza ogni singolo canale del layout 7.1.4 (12ch) o 9.1.6 (16ch) per 1.2s ciascuno."
        case .singleChannel:
            return "Invia il segnale di test esclusivamente al diffusore selezionato (Floor, LFE o Height/Overhead)."
        case .ceilingOrbit:
            return "Oggetto OAMD 3D in rotazione continua a 360° sul piano superiore (Vhl → Vhr → Rtr → Ltr)."
        case .elevationSweep:
            return "Transizione verticale continua da z = 0.0 (Floor Bed) a z = 1.0 (Overhead Height) e ritorno."
        case .frontToBackFlyover:
            return "Traiettoria longitudinale sopra la testa dal fronte schermo (y = +1) al retro stanza (y = -1)."
        case .domeSpiral:
            return "Oggetto 3D con modulazione spaziale che sale a spirale dal pavimento fino allo zenit del soffitto."
        case .lfeSubTest:
            return "Segnale dedicato al canale LFE (Ch 3) con sweep sinusoidale 30–90 Hz e impulsi sub-bass."
        case .fullAtmosDemo:
            return "Simula la Presentation 3 TrueHD completa: Bed 7.1 armonico, LFE e 2 oggetti 3D indipendenti sul soffitto."
        case .manualObject3D:
            return "Muovi manualmente un oggetto OAMD nello spazio 3D (X, Y, Z, Spread) in tempo reale."
        }
    }

    public var iconName: String {
        switch self {
        case .channelSweep:
            return "speaker.wave.3.fill"
        case .singleChannel:
            return "dot.radiowaves.right"
        case .ceilingOrbit:
            return "rotate.3d"
        case .elevationSweep:
            return "arrow.up.and.down.circle.fill"
        case .frontToBackFlyover:
            return "airplane"
        case .domeSpiral:
            return "tornado"
        case .lfeSubTest:
            return "waveform.path.ecg"
        case .fullAtmosDemo:
            return "sparkles.tv.fill"
        case .manualObject3D:
            return "move.3d"
        }
    }

    public var badgeText: String {
        switch self {
        case .channelSweep:
            return "12/16 CH WALK"
        case .singleChannel:
            return "SOLO CH"
        case .ceilingOrbit:
            return "HEIGHT 360°"
        case .elevationSweep:
            return "Z-AXIS SWEEP"
        case .frontToBackFlyover:
            return "OVERHEAD FLY"
        case .domeSpiral:
            return "3D SPIRAL"
        case .lfeSubTest:
            return "SUB LFE"
        case .fullAtmosDemo:
            return "BED + OAMD"
        case .manualObject3D:
            return "INTERACTIVE 3D"
        }
    }
}

/// Dynamic, configurable spatial audio generator implementing `TrueHDAtmosStreamSource`
/// for interactive real-time testing of all presets.
public final class ConfigurableAtmosTestSource: TrueHDAtmosStreamSource {
    public let sampleRate: Double = 48000.0
    public let blockFrameCount: Int

    public var preset: AtmosTestTrackPreset
    public var targetLayout: AtmosTargetLayout
    public var selectedSingleChannel: Int = 8 // Default Vhl (TopFrontL)
    public var manualX: Float = 0.0
    public var manualY: Float = 0.8
    public var manualZ: Float = 1.0
    public var manualSpread: Float = 0.05

    private(set) public var currentSample: Int64 = 0
    private(set) public var activeStatusDescription: String = ""
    private(set) public var activeHighlightedChannel: Int? = nil

    /// Deterministic PRNG state for broadband spatial localization texture
    private var noiseSeed: UInt64 = 0x1234_5678_9ABC_DEF0

    public init(
        preset: AtmosTestTrackPreset = .channelSweep,
        targetLayout: AtmosTargetLayout = .atmos7_1_4,
        accessUnitsPerBlock: Int = 4
    ) {
        self.preset = preset
        self.targetLayout = targetLayout
        self.blockFrameCount = 40 * max(1, accessUnitsPerBlock)
    }

    public func resetTimeline() {
        currentSample = 0
    }

    private func nextPinkishNoise() -> Float {
        // Xorshift64* for click-free deterministic localization texture
        noiseSeed ^= noiseSeed >> 12
        noiseSeed ^= noiseSeed << 25
        noiseSeed ^= noiseSeed >> 27
        let val = noiseSeed &* 2685821657736338717
        let normalized = Float(Int32(bitPattern: UInt32(val >> 32))) / Float(Int32.max)
        return normalized
    }

    public func nextBlock() -> TrueHDAtmosBlock? {
        let frames = blockFrameCount
        let midTime = (Double(currentSample) + Double(frames) * 0.5) / sampleRate

        let block: TrueHDAtmosBlock
        switch preset {
        case .channelSweep:
            block = generateChannelSweepBlock(frames: frames, midTime: midTime)
        case .singleChannel:
            block = generateSingleChannelBlock(frames: frames, midTime: midTime)
        case .ceilingOrbit:
            block = generateCeilingOrbitBlock(frames: frames, midTime: midTime)
        case .elevationSweep:
            block = generateElevationSweepBlock(frames: frames, midTime: midTime)
        case .frontToBackFlyover:
            block = generateFrontToBackBlock(frames: frames, midTime: midTime)
        case .domeSpiral:
            block = generateDomeSpiralBlock(frames: frames, midTime: midTime)
        case .lfeSubTest:
            block = generateLFESubTestBlock(frames: frames, midTime: midTime)
        case .fullAtmosDemo:
            block = generateFullAtmosDemoBlock(frames: frames, midTime: midTime)
        case .manualObject3D:
            block = generateManualObjectBlock(frames: frames, midTime: midTime)
        }

        currentSample += Int64(frames)
        return block
    }

    // MARK: - 1. Channel Sweep (Speaker Walk)
    private func generateChannelSweepBlock(frames: Int, midTime: Double) -> TrueHDAtmosBlock {
        let slotDuration = 1.25 // seconds per speaker
        let numCh = targetLayout.channelCount
        let slotIndex = Int(midTime / slotDuration) % numCh
        let timeInSlot = midTime.truncatingRemainder(dividingBy: slotDuration)

        let speakers = SpatialVBAPRenderer.buildSpeakerPositions(for: targetLayout)
        let spk = speakers[slotIndex]
        let isHeight = targetLayout.heightChannelIndices.contains(slotIndex)
        let fullNames = targetLayout.channelNames

        activeHighlightedChannel = slotIndex
        let layerTag = spk.isLFE ? "LFE SUB" : (isHeight ? "HEIGHT / OVERHEAD" : "FLOOR / BED")
        activeStatusDescription = "Canale \(slotIndex + 1)/\(numCh): \(fullNames[slotIndex]) [\(layerTag)]"

        var sig = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Double(currentSample + Int64(i)) / sampleRate
            let localT = (t).truncatingRemainder(dividingBy: slotDuration)
            // Smooth fade-in (80ms) and fade-out (150ms) inside each speaker slot
            let fadeIn = Float(min(1.0, localT / 0.08))
            let fadeOut = Float(min(1.0, max(0.0, (slotDuration - localT) / 0.15)))
            let env = fadeIn * fadeOut

            if spk.isLFE {
                let lfeTone = Float(sin(2.0 * .pi * 55.0 * t) + 0.5 * sin(2.0 * .pi * 82.5 * t)) * 0.45
                sig[i] = lfeTone * env
            } else if isHeight {
                // Crystalline harmonic triad (523.25 Hz C5 + 659.25 Hz E5 + 783.99 Hz G5) + localization air
                let chord = Float(
                    0.45 * sin(2.0 * .pi * 523.25 * t) +
                    0.35 * sin(2.0 * .pi * 659.25 * t) +
                    0.25 * sin(2.0 * .pi * 783.99 * t)
                )
                let air = nextPinkishNoise() * 0.08
                sig[i] = (chord + air) * 0.55 * env
            } else {
                // Warm floor harmonic chord (220 Hz A3 + 329.63 Hz E4 + 440 Hz A4) + subtle texture
                let chord = Float(
                    0.50 * sin(2.0 * .pi * 220.0 * t) +
                    0.30 * sin(2.0 * .pi * 329.63 * t) +
                    0.20 * sin(2.0 * .pi * 440.0 * t)
                )
                let tex = nextPinkishNoise() * 0.06
                sig[i] = (chord + tex) * 0.50 * env
            }
        }

        // Route via exact 3D coordinates for height speakers, or pinned bed / LFE for floor
        let meta: OAMDObjectMetadata
        if spk.isLFE {
            meta = OAMDObjectMetadata(objectID: 0, x: 0.0, y: 1.0, z: 0.0, linearGain: 1.0, isLFE: true)
        } else if isHeight {
            meta = OAMDObjectMetadata(objectID: 0, x: spk.x, y: spk.y, z: 1.0, linearGain: 1.0, spread: 0.0)
        } else {
            meta = OAMDObjectMetadata(objectID: 0, x: spk.x, y: spk.y, z: 0.0, linearGain: 1.0, pinnedBedChannel: slotIndex)
        }
        _ = timeInSlot
        return TrueHDAtmosBlock(frameCount: frames, sampleRate: sampleRate, signals: [sig], metadata: [meta])
    }

    // MARK: - 2. Single Speaker Isolation
    private func generateSingleChannelBlock(frames: Int, midTime: Double) -> TrueHDAtmosBlock {
        let numCh = targetLayout.channelCount
        let chIdx = max(0, min(numCh - 1, selectedSingleChannel))
        let speakers = SpatialVBAPRenderer.buildSpeakerPositions(for: targetLayout)
        let spk = speakers[chIdx]
        let isHeight = targetLayout.heightChannelIndices.contains(chIdx)
        let fullNames = targetLayout.channelNames

        activeHighlightedChannel = chIdx
        let layerTag = spk.isLFE ? "LFE SUB" : (isHeight ? "HEIGHT / OVERHEAD" : "FLOOR / BED")
        activeStatusDescription = "Isolamento Canale \(chIdx): \(fullNames[chIdx]) [\(layerTag)]"

        var sig = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Double(currentSample + Int64(i)) / sampleRate
            // Gentle rhythmic pulse every 1.0s so listener can clearly judge speaker attack & localization
            let pulseEnv = Float(0.65 + 0.35 * sin(2.0 * .pi * 1.5 * t))
            if spk.isLFE {
                sig[i] = Float(sin(2.0 * .pi * 55.0 * t)) * 0.55 * pulseEnv
            } else if isHeight {
                let tone = Float(0.55 * sin(2.0 * .pi * 587.33 * t) + 0.35 * sin(2.0 * .pi * 880.0 * t))
                let air = nextPinkishNoise() * 0.08
                sig[i] = (tone + air) * 0.55 * pulseEnv
            } else {
                let tone = Float(0.55 * sin(2.0 * .pi * 261.63 * t) + 0.35 * sin(2.0 * .pi * 392.0 * t))
                let tex = nextPinkishNoise() * 0.06
                sig[i] = (tone + tex) * 0.50 * pulseEnv
            }
        }

        let meta: OAMDObjectMetadata
        if spk.isLFE {
            meta = OAMDObjectMetadata(objectID: 0, x: 0.0, y: 1.0, z: 0.0, linearGain: 1.0, isLFE: true)
        } else if isHeight {
            meta = OAMDObjectMetadata(objectID: 0, x: spk.x, y: spk.y, z: 1.0, linearGain: 1.0, spread: 0.0)
        } else {
            meta = OAMDObjectMetadata(objectID: 0, x: spk.x, y: spk.y, z: 0.0, linearGain: 1.0, pinnedBedChannel: chIdx)
        }
        _ = midTime
        return TrueHDAtmosBlock(frameCount: frames, sampleRate: sampleRate, signals: [sig], metadata: [meta])
    }

    // MARK: - 3. 3D Overhead Ceiling Orbit (z = 1.0)
    private func generateCeilingOrbitBlock(frames: Int, midTime: Double) -> TrueHDAtmosBlock {
        activeHighlightedChannel = nil
        let period = 5.0 // 5 seconds per full 360° ceiling revolution
        let angle = Float(2.0 * .pi * (midTime / period))
        let ox = 0.82 * sin(angle)
        let oy = 0.82 * cos(angle)
        let oz: Float = 1.0

        let deg = Int(((midTime / period).truncatingRemainder(dividingBy: 1.0)) * 360.0)
        activeStatusDescription = String(format: "Orbita Soffitto 360°: Azimut %d° (x: %+.2f, y: %+.2f, z: 1.00)", deg, ox, oy)

        var overheadSig = [Float](repeating: 0.0, count: frames)
        var centerAnchorSig = [Float](repeating: 0.0, count: frames)

        for i in 0..<frames {
            let t = Double(currentSample + Int64(i)) / sampleRate
            let shimmer = Float(
                0.50 * sin(2.0 * .pi * 550.0 * t) +
                0.30 * sin(2.0 * .pi * 825.0 * t) +
                0.10 * Double(nextPinkishNoise())
            )
            overheadSig[i] = shimmer * 0.55
            // Subtle Front Center floor reference anchor so height elevation contrast is unmistakable
            centerAnchorSig[i] = Float(sin(2.0 * .pi * 165.0 * t)) * 0.14
        }

        let metadata: [OAMDObjectMetadata] = [
            OAMDObjectMetadata(objectID: 0, x: ox, y: oy, z: oz, linearGain: 1.0, spread: 0.05),
            OAMDObjectMetadata(objectID: 1, x: 0.0, y: 1.0, z: 0.0, linearGain: 1.0, pinnedBedChannel: 2)
        ]
        return TrueHDAtmosBlock(frameCount: frames, sampleRate: sampleRate, signals: [overheadSig, centerAnchorSig], metadata: metadata)
    }

    // MARK: - 4. Vertical Elevation Sweep (Floor z=0 <-> Height z=1)
    private func generateElevationSweepBlock(frames: Int, midTime: Double) -> TrueHDAtmosBlock {
        activeHighlightedChannel = nil
        let cycle = 4.0 // 4 seconds up and down
        let zNorm = Float(0.5 - 0.5 * cos(2.0 * .pi * (midTime / cycle)))

        activeStatusDescription = String(format: "Sweep Elevazione Verticale: z = %.2f (%d%% Height / %d%% Floor)",
                                         zNorm, Int(zNorm * 100), Int((1.0 - zNorm) * 100))

        var leftSweepSig = [Float](repeating: 0.0, count: frames)
        var rightSweepSig = [Float](repeating: 0.0, count: frames)

        // Frequency rises smoothly with elevation z from 240 Hz (Floor) to 640 Hz (Ceiling)
        let instFreq = 240.0 + 400.0 * Double(zNorm)

        for i in 0..<frames {
            let t = Double(currentSample + Int64(i)) / sampleRate
            let waveL = Float(0.6 * sin(2.0 * .pi * instFreq * t) + 0.3 * sin(2.0 * .pi * (instFreq * 1.5) * t))
            let waveR = Float(0.6 * sin(2.0 * .pi * (instFreq * 1.25) * t) + 0.3 * sin(2.0 * .pi * (instFreq * 1.5) * t))
            let noise = nextPinkishNoise() * 0.06
            leftSweepSig[i] = (waveL + noise) * 0.45
            rightSweepSig[i] = (waveR + noise) * 0.45
        }

        let metadata: [OAMDObjectMetadata] = [
            OAMDObjectMetadata(objectID: 0, x: -0.8, y: 0.8, z: zNorm, linearGain: 1.0, spread: 0.05),
            OAMDObjectMetadata(objectID: 1, x:  0.8, y: 0.8, z: zNorm, linearGain: 1.0, spread: 0.05)
        ]
        return TrueHDAtmosBlock(frameCount: frames, sampleRate: sampleRate, signals: [leftSweepSig, rightSweepSig], metadata: metadata)
    }

    // MARK: - 5. Front-to-Back Longitudinal Flyover
    private func generateFrontToBackBlock(frames: Int, midTime: Double) -> TrueHDAtmosBlock {
        activeHighlightedChannel = nil
        let cycle = 4.5
        let yPos = Float(cos(2.0 * .pi * (midTime / cycle))) // +1.0 (Front) -> -1.0 (Rear) -> +1.0 (Front)
        // Slight arc in elevation: z = 0.35 at ends, z = 1.0 directly overhead (y = 0)
        let zPos: Float = max(0.35, 1.0 - 0.55 * (yPos * yPos))

        activeStatusDescription = String(format: "Sorvolo Fronte ↔ Retro: y = %+.2f, z = %.2f", yPos, zPos)

        var flyoverSig = [Float](repeating: 0.0, count: frames)
        // Subtle Doppler shift around 440 Hz
        let velocity = -Float(sin(2.0 * .pi * (midTime / cycle)))
        let dopplerFreq = 440.0 * Double(1.0 + 0.12 * velocity)

        for i in 0..<frames {
            let t = Double(currentSample + Int64(i)) / sampleRate
            let jetTone = Float(0.55 * sin(2.0 * .pi * dopplerFreq * t) + 0.30 * sin(2.0 * .pi * (dopplerFreq * 0.5) * t))
            let rush = nextPinkishNoise() * 0.15
            flyoverSig[i] = (jetTone + rush) * 0.55
        }

        let metadata: [OAMDObjectMetadata] = [
            OAMDObjectMetadata(objectID: 0, x: 0.0, y: yPos, z: zPos, linearGain: 1.0, spread: 0.12)
        ]
        return TrueHDAtmosBlock(frameCount: frames, sampleRate: sampleRate, signals: [flyoverSig], metadata: metadata)
    }

    // MARK: - 6. 3D Dome Spiral (Helicopter Ascent/Descent)
    private func generateDomeSpiralBlock(frames: Int, midTime: Double) -> TrueHDAtmosBlock {
        activeHighlightedChannel = nil
        let spiralCycle = 8.0
        let zPos = Float(0.5 - 0.5 * cos(2.0 * .pi * (midTime / spiralCycle)))
        // Radius narrows slightly as it reaches the zenith of the dome
        let radius = Float(0.95 - 0.30 * zPos)
        let angle = Float(2.0 * .pi * (midTime / 2.2))
        let xPos = radius * sin(angle)
        let yPos = radius * cos(angle)

        activeStatusDescription = String(format: "Spirale 3D Emisferica: (x: %+.2f, y: %+.2f, z: %.2f)", xPos, yPos, zPos)

        var spiralSig = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Double(currentSample + Int64(i)) / sampleRate
            // Rotor blade amplitude modulation (11 Hz) over harmonic drone + broadband air
            let bladeMod = Float(0.55 + 0.45 * sin(2.0 * .pi * 11.0 * t))
            let drone = Float(0.45 * sin(2.0 * .pi * 180.0 * t) + 0.35 * sin(2.0 * .pi * 540.0 * t))
            let rotorNoise = nextPinkishNoise() * 0.22
            spiralSig[i] = (drone + rotorNoise) * bladeMod * 0.60
        }

        let metadata: [OAMDObjectMetadata] = [
            OAMDObjectMetadata(objectID: 0, x: xPos, y: yPos, z: zPos, linearGain: 1.0, spread: 0.08)
        ]
        return TrueHDAtmosBlock(frameCount: frames, sampleRate: sampleRate, signals: [spiralSig], metadata: metadata)
    }

    // MARK: - 7. LFE Sub-Bass Test
    private func generateLFESubTestBlock(frames: Int, midTime: Double) -> TrueHDAtmosBlock {
        activeHighlightedChannel = 3 // Channel 3 is always LFE
        let cycle = 4.0
        let sweepFactor = 0.5 - 0.5 * cos(2.0 * .pi * (midTime / cycle))
        let lfeFreq = 32.0 + 58.0 * sweepFactor // 32 Hz -> 90 Hz

        activeStatusDescription = String(format: "Subwoofer LFE (Canale 4): %.1f Hz Sub-Bass Sweep", lfeFreq)

        var lfeSig = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let t = Double(currentSample + Int64(i)) / sampleRate
            let pulse = Float(0.75 + 0.25 * sin(2.0 * .pi * 2.0 * t))
            lfeSig[i] = Float(sin(2.0 * .pi * lfeFreq * t)) * 0.60 * pulse
        }

        let metadata: [OAMDObjectMetadata] = [
            OAMDObjectMetadata(objectID: 0, x: 0.0, y: 1.0, z: 0.0, linearGain: 1.0, isLFE: true)
        ]
        return TrueHDAtmosBlock(frameCount: frames, sampleRate: sampleRate, signals: [lfeSig], metadata: metadata)
    }

    // MARK: - 8. Full TrueHD Atmos Presentation 3 Demo (Bed + Dynamic 3D Objects)
    private func generateFullAtmosDemoBlock(frames: Int, midTime: Double) -> TrueHDAtmosBlock {
        activeHighlightedChannel = nil
        let angle1 = Float(2.0 * .pi * (midTime / 3.5))
        let angle2 = -Float(2.0 * .pi * (midTime / 5.0)) + (.pi * 0.5)

        let o1x = 0.82 * cos(angle1)
        let o1y = 0.82 * sin(angle1)
        let o2x = 0.80 * cos(angle2)
        let o2y = 0.80 * sin(angle2)
        let o2z: Float = Float(0.65 + 0.35 * sin(2.0 * .pi * (midTime / 2.8)))

        activeStatusDescription = String(format: "TrueHD Pres. 3: Bed 7.1 + LFE + 2 Oggetti 3D (z1=1.00, z2=%.2f)", o2z)

        var bedCenter = [Float](repeating: 0.0, count: frames)
        var bedLFE = [Float](repeating: 0.0, count: frames)
        var obj1Sig = [Float](repeating: 0.0, count: frames)
        var obj2Sig = [Float](repeating: 0.0, count: frames)

        for i in 0..<frames {
            let t = Double(currentSample + Int64(i)) / sampleRate
            bedCenter[i] = Float(sin(2.0 * .pi * 220.0 * t)) * 0.30
            bedLFE[i] = Float(sin(2.0 * .pi * 60.0 * t)) * 0.25
            obj1Sig[i] = (Float(sin(2.0 * .pi * 550.0 * t)) + nextPinkishNoise() * 0.05) * 0.48
            obj2Sig[i] = (Float(sin(2.0 * .pi * 880.0 * t)) + nextPinkishNoise() * 0.05) * 0.42
        }

        let metadata: [OAMDObjectMetadata] = [
            OAMDObjectMetadata(objectID: 0, x: 0.0, y: 1.0, z: 0.0, linearGain: 1.0, pinnedBedChannel: 2),
            OAMDObjectMetadata(objectID: 1, x: 0.0, y: 1.0, z: 0.0, linearGain: 1.0, isLFE: true),
            OAMDObjectMetadata(objectID: 2, x: o1x, y: o1y, z: 1.0, linearGain: 1.0, spread: 0.05),
            OAMDObjectMetadata(objectID: 3, x: o2x, y: o2y, z: o2z, linearGain: 1.0, spread: 0.08)
        ]
        return TrueHDAtmosBlock(
            frameCount: frames,
            sampleRate: sampleRate,
            signals: [bedCenter, bedLFE, obj1Sig, obj2Sig],
            metadata: metadata
        )
    }

    // MARK: - 9. Manual Interactive 3D Object
    private func generateManualObjectBlock(frames: Int, midTime: Double) -> TrueHDAtmosBlock {
        activeHighlightedChannel = nil
        activeStatusDescription = String(format: "Oggetto Manuale 3D: X=%+.2f, Y=%+.2f, Z=%.2f, Spread=%.2f",
                                         manualX, manualY, manualZ, manualSpread)

        var sig = [Float](repeating: 0.0, count: frames)
        let baseFreq = 280.0 + 380.0 * Double(manualZ)
        for i in 0..<frames {
            let t = Double(currentSample + Int64(i)) / sampleRate
            let tone = Float(0.55 * sin(2.0 * .pi * baseFreq * t) + 0.35 * sin(2.0 * .pi * (baseFreq * 1.498) * t))
            let tex = nextPinkishNoise() * 0.08
            sig[i] = (tone + tex) * 0.55
        }
        _ = midTime

        let metadata: [OAMDObjectMetadata] = [
            OAMDObjectMetadata(objectID: 0, x: manualX, y: manualY, z: manualZ, linearGain: 1.0, spread: manualSpread)
        ]
        return TrueHDAtmosBlock(frameCount: frames, sampleRate: sampleRate, signals: [sig], metadata: metadata)
    }
}

