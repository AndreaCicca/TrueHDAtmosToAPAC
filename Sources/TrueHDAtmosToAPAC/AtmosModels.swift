import Foundation
import CoreAudioTypes

/// Target spatial bed layouts supported by Apple Positional Audio Codec (APAC)
/// that trigger Dolby MAT 2.0 (Dolby Atmos) output on tvOS over HDMI.
public enum AtmosTargetLayout: String, CaseIterable, Identifiable, Sendable {
    /// 7.1.4 layout (12 channels: L, R, C, LFE, Ls, Rs, Rls, Rrs, Vhl, Vhr, Ltr, Rtr)
    case atmos7_1_4 = "7.1.4"
    /// 9.1.6 layout (16 channels: L, R, C, LFE, Ls, Rs, Rls, Rrs, Lw, Rw, Vhl, Vhr, Ltm, Rtm, Ltr, Rtr)
    case atmos9_1_6 = "9.1.6"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .atmos7_1_4:
            return "Dolby Atmos 7.1.4 (12 ch)"
        case .atmos9_1_6:
            return "Dolby Atmos 9.1.6 (16 ch)"
        }
    }

    public var channelLayoutTag: AudioChannelLayoutTag {
        switch self {
        case .atmos7_1_4:
            return kAudioChannelLayoutTag_Atmos_7_1_4
        case .atmos9_1_6:
            return kAudioChannelLayoutTag_Atmos_9_1_6
        }
    }

    public var channelCount: Int {
        Int(AudioChannelLayoutTag_GetNumberOfChannels(channelLayoutTag))
    }

    public var channelNames: [String] {
        switch self {
        case .atmos7_1_4:
            return [
                "L", "R", "C", "LFE",
                "Ls", "Rs", "Rls", "Rrs",
                "Vhl (TopFrontL)", "Vhr (TopFrontR)", "Ltr (TopRearL)", "Rtr (TopRearR)"
            ]
        case .atmos9_1_6:
            return [
                "L", "R", "C", "LFE",
                "Ls", "Rs", "Rls", "Rrs",
                "Lw", "Rw",
                "Vhl (TopFrontL)", "Vhr (TopFrontR)",
                "Ltm (TopMidL)", "Rtm (TopMidR)",
                "Ltr (TopRearL)", "Rtr (TopRearR)"
            ]
        }
    }

    public var shortChannelNames: [String] {
        switch self {
        case .atmos7_1_4:
            return ["L", "R", "C", "LFE", "Ls", "Rs", "Rls", "Rrs", "Vhl", "Vhr", "Ltr", "Rtr"]
        case .atmos9_1_6:
            return ["L", "R", "C", "LFE", "Ls", "Rs", "Rls", "Rrs", "Lw", "Rw", "Vhl", "Vhr", "Ltm", "Rtm", "Ltr", "Rtr"]
        }
    }

    /// Indices of the height/overhead channels within the layout.
    public var heightChannelIndices: [Int] {
        switch self {
        case .atmos7_1_4:
            return [8, 9, 10, 11]
        case .atmos9_1_6:
            return [10, 11, 12, 13, 14, 15]
        }
    }
}

/// 3D Speaker position in Dolby Atmos room coordinates:
/// - `x`: -1.0 (Left) to +1.0 (Right)
/// - `y`: -1.0 (Rear/Back) to +1.0 (Front/Screen)
/// - `z`:  0.0 (Floor/Ear level) to +1.0 (Ceiling/Overhead)
public struct SpeakerPosition3D: Identifiable, Sendable {
    public var id: Int { channelIndex }
    public let channelIndex: Int
    public let name: String
    public let x: Float
    public let y: Float
    public let z: Float
    public let isLFE: Bool

    public init(channelIndex: Int, name: String, x: Float, y: Float, z: Float, isLFE: Bool = false) {
        self.channelIndex = channelIndex
        self.name = name
        self.x = x
        self.y = y
        self.z = z
        self.isLFE = isLFE
    }
}

/// Represents the per-object spatial metadata extracted from a Dolby TrueHD
/// Presentation 3 (4th substream) OAMD (Object Audio Metadata) payload.
public struct OAMDObjectMetadata: Identifiable, Sendable {
    public var id: Int { objectID }
    /// Object or bed index (0..<totalSignals)
    public let objectID: Int
    /// Horizontal position: -1.0 (Left) ... 0.0 (Center) ... +1.0 (Right)
    public let x: Float
    /// Depth position: -1.0 (Back) ... 0.0 (Mid) ... +1.0 (Front)
    public let y: Float
    /// Elevation/Height position: 0.0 (Ear level) ... +1.0 (Overhead ceiling)
    public let z: Float
    /// Object gain in linear scale (derived from OAMD dB gain)
    public let linearGain: Float
    /// Object spread / size (0.0 = point source, 1.0 = wide diffuse field)
    public let spread: Float
    /// True if this signal is a direct LFE feed
    public let isLFE: Bool
    /// Optional fixed bed channel index if the signal is pinned to a bed speaker
    public let pinnedBedChannel: Int?

    public init(
        objectID: Int,
        x: Float,
        y: Float,
        z: Float,
        linearGain: Float = 1.0,
        spread: Float = 0.0,
        isLFE: Bool = false,
        pinnedBedChannel: Int? = nil
    ) {
        self.objectID = objectID
        self.x = max(-1.0, min(1.0, x))
        self.y = max(-1.0, min(1.0, y))
        self.z = max(0.0, min(1.0, z))
        self.linearGain = linearGain
        self.spread = max(0.0, min(1.0, spread))
        self.isLFE = isLFE
        self.pinnedBedChannel = pinnedBedChannel
    }
}

/// Represents a decoded block of Dolby TrueHD Atmos audio (e.g. 1 Access Unit = 40 samples at 48 kHz,
/// or a coalesced block of Access Units) containing both the discrete object/bed PCM waveforms
/// and their synchronized 3D OAMD coordinates.
public struct TrueHDAtmosBlock: Sendable {
    /// Number of PCM frames per signal in this block
    public let frameCount: Int
    /// Sample rate in Hz (typically 48000)
    public let sampleRate: Double
    /// Deinterleaved PCM Float32 samples for each signal (`signals[signalIdx][sampleIdx]`)
    public let signals: [[Float]]
    /// OAMD 3D metadata for each signal in `signals`
    public let metadata: [OAMDObjectMetadata]

    public init(
        frameCount: Int,
        sampleRate: Double = 48000.0,
        signals: [[Float]],
        metadata: [OAMDObjectMetadata]
    ) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.signals = signals
        self.metadata = metadata
    }
}

