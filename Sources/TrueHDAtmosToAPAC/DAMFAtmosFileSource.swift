import Foundation
import AVFAudio

/// Streams multichannel bed + object audio from a Core Audio Format (`.caf`) or multichannel WAV/PCM file
/// produced by `truehdd decode --presentation 3` alongside dynamic or static OAMD object coordinates.
public final class MultichannelCAFAtmosSource: TrueHDAtmosStreamSource {
    public let sampleRate: Double
    public let blockFrameCount: Int
    private let audioFile: AVAudioFile
    private let channelCount: Int
    private let readBuffer: AVAudioPCMBuffer
    private var framesRemaining: AVAudioFramePosition

    public init(cafURL: URL, accessUnitsPerBlock: Int = 16) throws {
        self.audioFile = try AVAudioFile(forReading: cafURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.sampleRate = audioFile.processingFormat.sampleRate
        self.channelCount = Int(audioFile.processingFormat.channelCount)
        self.blockFrameCount = 40 * max(1, accessUnitsPerBlock)
        self.framesRemaining = audioFile.length
        self.readBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: AVAudioFrameCount(self.blockFrameCount)
        )!
    }

    public func nextBlock() -> TrueHDAtmosBlock? {
        guard framesRemaining > 0 else { return nil }
        let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(blockFrameCount), framesRemaining))
        do {
            try audioFile.read(into: readBuffer, frameCount: framesToRead)
        } catch {
            return nil
        }

        let actualFrames = Int(readBuffer.frameLength)
        guard actualFrames > 0, let floatData = readBuffer.floatChannelData else { return nil }
        framesRemaining -= AVAudioFramePosition(actualFrames)

        var signals = [[Float]]()
        signals.reserveCapacity(channelCount)
        var metadata = [OAMDObjectMetadata]()
        metadata.reserveCapacity(channelCount)

        // Default 7.1.2 bed mapping (channels 0..<10) + dynamic objects (channels 10..<N)
        for ch in 0..<channelCount {
            let ptr = UnsafeBufferPointer(start: floatData[ch], count: actualFrames)
            signals.append(Array(ptr))

            if ch == 3 {
                metadata.append(OAMDObjectMetadata(objectID: ch, x: 0.0, y: 1.0, z: 0.0, isLFE: true))
            } else if ch < 8 {
                // Standard 7.1 floor bed channels (L, R, C, LFE, Ls, Rs, Rls, Rrs)
                metadata.append(OAMDObjectMetadata(objectID: ch, x: 0.0, y: 0.0, z: 0.0, pinnedBedChannel: ch))
            } else if ch == 8 {
                // 7.1.2 Left Top Middle -> overhead left (x = -0.8, y = 0.0, z = 1.0)
                metadata.append(OAMDObjectMetadata(objectID: ch, x: -0.8, y: 0.0, z: 1.0))
            } else if ch == 9 {
                // 7.1.2 Right Top Middle -> overhead right (x = +0.8, y = 0.0, z = 1.0)
                metadata.append(OAMDObjectMetadata(objectID: ch, x: 0.8, y: 0.0, z: 1.0))
            } else {
                // Additional Atmos object tracks distributed across overhead hemisphere
                let objIdx = ch - 10
                let angle = Float(objIdx) * (.pi * 0.5) + (.pi * 0.25)
                metadata.append(
                    OAMDObjectMetadata(
                        objectID: ch,
                        x: 0.8 * cos(angle),
                        y: 0.8 * sin(angle),
                        z: 1.0
                    )
                )
            }
        }

        return TrueHDAtmosBlock(
            frameCount: actualFrames,
            sampleRate: sampleRate,
            signals: signals,
            metadata: metadata
        )
    }
}

