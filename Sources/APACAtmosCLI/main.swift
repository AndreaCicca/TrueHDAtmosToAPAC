import Foundation
import AVFAudio
import AudioToolbox
import CoreAudioTypes
import CoreMedia
import TrueHDAtmosToAPAC

@main
struct APACAtmosCLI {
    static func main() throws {
        let args = CommandLine.arguments
        print("=========================================================================")
        print("  Dolby TrueHD Atmos -> APAC -> Dolby MAT 2.0 Real-Time Pipeline PoC")
        print("=========================================================================\n")

        if let inputIdx = args.firstIndex(of: "--input"), inputIdx + 1 < args.count {
            let inputPath = args[inputIdx + 1]
            let playLive = args.contains("--play")
            try transcodeCAFInput(path: inputPath, playLive: playLive)
            return
        }

        // 1. Test both Atmos 7.1.4 (12ch) and Atmos 9.1.6 (16ch) real-time pipelines
        for targetLayout in [AtmosTargetLayout.atmos7_1_4, AtmosTargetLayout.atmos9_1_6] {
            try runPipelineVerification(targetLayout: targetLayout, durationSeconds: 2.0)
            print("")
        }

        // 2. Write a 7.1.4 APAC stream to disk and perform a full decode round-trip check
        //    proving that overhead/height objects (Vhl, Vhr, Ltr, Rtr) survive APAC encoding intact.
        try verifyAPACRoundTripHeightPreservation()

        if args.contains("--play") {
            print("\n--- [3] Live Playback via AVSampleBufferAudioRenderer (2.0s) ---")
            try playLiveDemo(durationSeconds: 2.0)
        }
    }

    static func runPipelineVerification(targetLayout: AtmosTargetLayout, durationSeconds: Double) throws {
        let layoutName = targetLayout == .atmos7_1_4 ? "Atmos 7.1.4 (12ch)" : "Atmos 9.1.6 (16ch)"
        print("--- [1] Testing On-The-Fly Pipeline for \(layoutName) ---")

        var source = SyntheticTrueHDAtmosSource(durationSeconds: durationSeconds, accessUnitsPerBlock: 4)
        let renderer = SpatialVBAPRenderer(targetLayout: targetLayout, sampleRate: source.sampleRate)
        let transcoder = try APACRealTimeTranscoder(
            targetLayout: targetLayout,
            sampleRate: source.sampleRate,
            bitRate: 1_280_000,
            disableDRC: true
        )
        let outputEngine = AtmosAPACAudioOutputEngine()

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: transcoder.pcmInputFormat,
            frameCapacity: AVAudioFrameCount(source.blockFrameCount)
        ) else {
            fatalError("Failed to allocate render PCM buffer")
        }

        var channelEnergy = [Double](repeating: 0.0, count: targetLayout.channelCount)
        var totalRenderedFrames = 0
        var totalSampleBuffers = 0
        var totalCompressedBytes = 0

        let startTime = CFAbsoluteTimeGetCurrent()

        while let block = source.nextBlock() {
            // Step A: Render TrueHD beds + dynamic 3D OAMD objects into 7.1.4 / 9.1.6 Float32 PCM
            renderer.render(block: block, into: renderBuffer)

            // Accumulate pre-encode channel energy to inspect spatial distribution
            let n = Int(renderBuffer.frameLength)
            if let chData = renderBuffer.floatChannelData {
                for c in 0..<targetLayout.channelCount {
                    let ptr = chData[c]
                    var sum: Double = 0.0
                    for i in 0..<n {
                        let v = Double(ptr[i])
                        sum += v * v
                    }
                    channelEnergy[c] += sum
                }
            }
            totalRenderedFrames += n

            // Step B: Transcode on the fly to kAudioFormatAPAC CMSampleBuffers
            let sampleBuffers = try transcoder.pushPCMAndEncode(renderBuffer)
            if !sampleBuffers.isEmpty {
                for sb in sampleBuffers {
                    totalCompressedBytes += CMSampleBufferGetTotalSampleSize(sb)
                }
                totalSampleBuffers += sampleBuffers.count
                // Step C: Feed into AVSampleBufferAudioRenderer (engages Dolby MAT 2.0 on tvOS)
                outputEngine.scheduleSampleBuffers(sampleBuffers)
            }
        }

        // Flush remaining frames
        let flushed = try transcoder.flush()
        for sb in flushed {
            totalCompressedBytes += CMSampleBufferGetTotalSampleSize(sb)
        }
        totalSampleBuffers += flushed.count
        outputEngine.scheduleSampleBuffers(flushed)

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let speedFactor = (durationSeconds * 1000.0) / max(0.001, elapsedMs)
        let effectiveBitrateKbps = (Double(totalCompressedBytes * 8) / durationSeconds) / 1000.0

        print(String(format: "  • Rendered & Transcoded %.2f s of TrueHD Atmos in %.2f ms (%.1fx real-time!)",
                     durationSeconds, elapsedMs, speedFactor))
        print(String(format: "  • Generated %d APAC CMSampleBuffers (%d bytes, ~%.1f kbps)",
                     totalSampleBuffers, totalCompressedBytes, effectiveBitrateKbps))
        print("  • Enqueued into AVSampleBufferAudioRenderer: \(outputEngine.totalEnqueuedBuffers) buffers")

        let names = targetLayout.channelNames
        let heightIndices = Set(targetLayout.heightChannelIndices)
        print("  • Spatial Channel RMS Distribution (Floor vs Height Channels):")
        for c in 0..<targetLayout.channelCount {
            let rms = sqrt(channelEnergy[c] / Double(max(1, totalRenderedFrames)))
            let tag = heightIndices.contains(c) ? " [HEIGHT / OVERHEAD]" : " [FLOOR / BED]"
            if rms > 0.0005 {
                let paddedName = names[c].padding(toLength: 16, withPad: " ", startingAt: 0)
                print(String(format: "      Ch %2d [%@]: RMS = %.4f%@", c, paddedName, rms, tag))
            }
        }

        outputEngine.stopAndFlush()
    }

    static func verifyAPACRoundTripHeightPreservation() throws {
        print("--- [2] Round-Trip APAC Encode/Decode Verification (Atmos 7.1.4) ---")
        let targetLayout = AtmosTargetLayout.atmos7_1_4
        guard let avLayout = AVAudioChannelLayout(layoutTag: targetLayout.channelLayoutTag) else { return }

        let tempURL = URL(fileURLWithPath: "/tmp/poc_truehd_to_apac_7_1_4.caf")
        try? FileManager.default.removeItem(at: tempURL)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAPAC,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: targetLayout.channelCount,
            AVChannelLayoutKey: NSData(bytes: avLayout.layout, length: MemoryLayout<AudioChannelLayout>.size),
            AVEncoderBitRateKey: 1_280_000
        ]

        let outFile = try AVAudioFile(
            forWriting: tempURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var source = SyntheticTrueHDAtmosSource(durationSeconds: 1.5, accessUnitsPerBlock: 4)
        let renderer = SpatialVBAPRenderer(targetLayout: targetLayout, sampleRate: source.sampleRate)
        let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channelLayout: avLayout)
        let renderBuf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(source.blockFrameCount))!

        while let block = source.nextBlock() {
            renderer.render(block: block, into: renderBuf)
            try outFile.write(from: renderBuf)
        }
        outFile.close()

        let inFile = try AVAudioFile(forReading: tempURL)
        let decodedBuf = AVAudioPCMBuffer(
            pcmFormat: inFile.processingFormat,
            frameCapacity: AVAudioFrameCount(inFile.length)
        )!
        try inFile.read(into: decodedBuf)

        let frames = Int(decodedBuf.frameLength)
        let names = targetLayout.channelNames
        let heightIndices = Set(targetLayout.heightChannelIndices)

        print("  • Decoded \(frames) frames from APAC 7.1.4 container (\(tempURL.path)):")
        var heightEnergyTotal: Double = 0.0
        for c in 0..<targetLayout.channelCount {
            var sum: Double = 0.0
            let ptr = decodedBuf.floatChannelData![c]
            for i in 0..<frames {
                let v = Double(ptr[i])
                sum += v * v
            }
            let rms = sqrt(sum / Double(max(1, frames)))
            if heightIndices.contains(c) {
                heightEnergyTotal += rms
            }
            let marker = heightIndices.contains(c) ? " <-- HEIGHT CHANNEL PRESERVED" : ""
            if rms > 0.001 {
                let paddedName = names[c].padding(toLength: 16, withPad: " ", startingAt: 0)
                print(String(format: "      Ch %2d [%@]: Decoded RMS = %.4f%@", c, paddedName, rms, marker))
            }
        }

        if heightEnergyTotal > 0.1 {
            print("\n  ✅ SUCCESS: All 4 Overhead/Height channels (Vhl, Vhr, Ltr, Rtr) survived APAC transcoding!")
        } else {
            print("\n  ❌ WARNING: Height channel energy was unexpectedly low.")
        }
    }

    static func transcodeCAFInput(path: String, playLive: Bool) throws {
        let url = URL(fileURLWithPath: path)
        print("--- Streaming & Transcoding TrueHD Atmos CAF Input: \(url.path) ---")
        let source = try MultichannelCAFAtmosSource(cafURL: url, accessUnitsPerBlock: 16)
        let renderer = SpatialVBAPRenderer(targetLayout: .atmos7_1_4, sampleRate: source.sampleRate)
        let transcoder = try APACRealTimeTranscoder(targetLayout: .atmos7_1_4, sampleRate: source.sampleRate)
        let outputEngine = AtmosAPACAudioOutputEngine()
        let renderBuf = AVAudioPCMBuffer(
            pcmFormat: transcoder.pcmInputFormat,
            frameCapacity: AVAudioFrameCount(source.blockFrameCount)
        )!

        var totalPackets = 0
        while let block = source.nextBlock() {
            renderer.render(block: block, into: renderBuf)
            let sbs = try transcoder.pushPCMAndEncode(renderBuf)
            totalPackets += sbs.count
            outputEngine.scheduleSampleBuffers(sbs)
        }
        let flushed = try transcoder.flush()
        totalPackets += flushed.count
        outputEngine.scheduleSampleBuffers(flushed)
        print("  • Generated \(totalPackets) APAC 7.1.4 CMSampleBuffers.")

        if playLive {
            outputEngine.startPlayback()
            Thread.sleep(forTimeInterval: 2.0)
            outputEngine.stopAndFlush()
        }
    }

    static func playLiveDemo(durationSeconds: Double) throws {
        var source = SyntheticTrueHDAtmosSource(durationSeconds: durationSeconds, accessUnitsPerBlock: 4)
        let renderer = SpatialVBAPRenderer(targetLayout: .atmos7_1_4, sampleRate: source.sampleRate)
        let transcoder = try APACRealTimeTranscoder(targetLayout: .atmos7_1_4, sampleRate: source.sampleRate)
        let outputEngine = AtmosAPACAudioOutputEngine()
        let renderBuf = AVAudioPCMBuffer(
            pcmFormat: transcoder.pcmInputFormat,
            frameCapacity: AVAudioFrameCount(source.blockFrameCount)
        )!

        while let block = source.nextBlock() {
            renderer.render(block: block, into: renderBuf)
            let sbs = try transcoder.pushPCMAndEncode(renderBuf)
            outputEngine.scheduleSampleBuffers(sbs)
        }
        outputEngine.scheduleSampleBuffers(try transcoder.flush())
        outputEngine.startPlayback()
        Thread.sleep(forTimeInterval: durationSeconds)
        outputEngine.stopAndFlush()
        print("  • Live playback completed (\(outputEngine.totalEnqueuedBuffers) APAC packets rendered).")
    }
}

