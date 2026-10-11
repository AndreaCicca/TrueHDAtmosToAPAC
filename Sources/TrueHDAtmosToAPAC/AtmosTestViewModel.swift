import Foundation
import AVFAudio
import CoreMedia
import Combine

/// Result of an APAC encode/decode round-trip check for a single speaker channel.
public struct RoundTripChannelResult: Identifiable, Sendable {
    public let id: Int
    public let channelName: String
    public let isHeight: Bool
    public let isLFE: Bool
    public let decodedRMS: Float
}

/// Main view model driving the real-time TrueHD Atmos -> 3D VBAP -> APAC -> Dolby MAT 2.0 test pipeline.
@MainActor
public final class AtmosTestViewModel: ObservableObject {
    // MARK: - User-selectable configuration
    @Published public var selectedPreset: AtmosTestTrackPreset = .channelSweep {
        didSet {
            testSource.preset = selectedPreset
            testSource.resetTimeline()
            if !isPlaying {
                updateStaticPreview()
            }
        }
    }

    @Published public var targetLayout: AtmosTargetLayout = .atmos7_1_4 {
        didSet {
            if selectedSingleChannel >= targetLayout.channelCount {
                selectedSingleChannel = max(0, targetLayout.channelCount - 1)
            }
            let wasPlaying = isPlaying
            stopPlayback()
            resetMetersForLayout()
            updateStaticPreview()
            if wasPlaying {
                startPlayback()
            }
        }
    }

    @Published public var bitRate: Int = 1_280_000 {
        didSet {
            if isPlaying {
                restartPipelinePreservingPreset()
            }
        }
    }

    @Published public var disableDRC: Bool = true {
        didSet {
            if isPlaying {
                restartPipelinePreservingPreset()
            }
        }
    }

    @Published public var selectedSingleChannel: Int = 8 {
        didSet {
            testSource.selectedSingleChannel = selectedSingleChannel
            if !isPlaying {
                updateStaticPreview()
            }
        }
    }

    @Published public var manualX: Float = 0.0 {
        didSet {
            testSource.manualX = manualX
            if !isPlaying { updateStaticPreview() }
        }
    }

    @Published public var manualY: Float = 0.8 {
        didSet {
            testSource.manualY = manualY
            if !isPlaying { updateStaticPreview() }
        }
    }

    @Published public var manualZ: Float = 1.0 {
        didSet {
            testSource.manualZ = manualZ
            if !isPlaying { updateStaticPreview() }
        }
    }

    @Published public var manualSpread: Float = 0.05 {
        didSet {
            testSource.manualSpread = manualSpread
            if !isPlaying { updateStaticPreview() }
        }
    }

    // MARK: - Live Telemetry & State
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var statusBannerText: String = "Pronto — Seleziona una traccia e premi Riproduci"
    @Published public private(set) var channelRMS: [Float] = Array(repeating: 0.0, count: 12)
    @Published public private(set) var channelPeaks: [Float] = Array(repeating: 0.0, count: 12)
    @Published public private(set) var activeObjects: [OAMDObjectMetadata] = []
    @Published public private(set) var highlightedChannelIndex: Int? = nil

    @Published public private(set) var encodedPackets: Int64 = 0
    @Published public private(set) var encodedBytes: Int64 = 0
    @Published public private(set) var effectiveBitrateKbps: Double = 0.0
    @Published public private(set) var elapsedSeconds: Double = 0.0
    @Published public private(set) var renderSpeedFactor: Double = 0.0
    @Published public private(set) var pendingBuffersCount: Int = 0
    @Published public private(set) var lastErrorMessage: String? = nil

    // MARK: - Round-trip verification results
    @Published public private(set) var roundTripResults: [RoundTripChannelResult] = []
    @Published public private(set) var roundTripPassed: Bool? = nil

    // MARK: - Pipeline components
    private let testSource = ConfigurableAtmosTestSource(preset: .channelSweep, targetLayout: .atmos7_1_4, accessUnitsPerBlock: 4)
    private var externalCAFSource: MultichannelCAFAtmosSource? = nil
    @Published public private(set) var activeExternalFileName: String? = nil

    private var renderer: SpatialVBAPRenderer?
    private var transcoder: APACRealTimeTranscoder?
    private let outputEngine = AtmosAPACAudioOutputEngine()
    private var renderPCMBuffer: AVAudioPCMBuffer?

    private var feedTimer: Timer?
    private var playbackStartWallTime: CFAbsoluteTime = 0
    private var cumulativeCpuTimeMs: Double = 0
    private var cumulativeAudioDurationMs: Double = 0

    public init() {
        resetMetersForLayout()
        updateStaticPreview()
    }

    // MARK: - Playback Controls
    public func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    public func selectAndSoloSpeaker(_ channelIndex: Int) {
        selectedSingleChannel = channelIndex
        selectedPreset = .singleChannel
        if !isPlaying {
            startPlayback()
        }
    }

    public func playPreset(_ preset: AtmosTestTrackPreset) {
        activeExternalFileName = nil
        externalCAFSource = nil
        selectedPreset = preset
        if !isPlaying {
            startPlayback()
        }
    }

    public func loadAndPlayExternalCAF(url: URL) {
        stopPlayback()
        do {
            let src = try MultichannelCAFAtmosSource(cafURL: url, accessUnitsPerBlock: 8)
            self.externalCAFSource = src
            self.activeExternalFileName = url.lastPathComponent
            startPlayback()
        } catch {
            self.lastErrorMessage = "Errore caricamento file CAF: \(error.localizedDescription)"
        }
    }

    public func startPlayback() {
        stopPlayback()
        lastErrorMessage = nil

        do {
            let sr = externalCAFSource?.sampleRate ?? testSource.sampleRate
            let blockFrames = externalCAFSource?.blockFrameCount ?? testSource.blockFrameCount

            testSource.targetLayout = targetLayout
            testSource.preset = selectedPreset
            testSource.selectedSingleChannel = selectedSingleChannel
            testSource.manualX = manualX
            testSource.manualY = manualY
            testSource.manualZ = manualZ
            testSource.manualSpread = manualSpread
            testSource.resetTimeline()

            let vbap = SpatialVBAPRenderer(targetLayout: targetLayout, sampleRate: sr)
            let apac = try APACRealTimeTranscoder(
                targetLayout: targetLayout,
                sampleRate: sr,
                bitRate: bitRate,
                disableDRC: disableDRC
            )

            guard let pcmBuf = AVAudioPCMBuffer(
                pcmFormat: apac.pcmInputFormat,
                frameCapacity: AVAudioFrameCount(blockFrames)
            ) else {
                lastErrorMessage = "Impossibile allocare AVAudioPCMBuffer per \(targetLayout.displayName)"
                return
            }

            self.renderer = vbap
            self.transcoder = apac
            self.renderPCMBuffer = pcmBuf

            self.encodedPackets = 0
            self.encodedBytes = 0
            self.effectiveBitrateKbps = 0
            self.elapsedSeconds = 0
            self.cumulativeCpuTimeMs = 0
            self.cumulativeAudioDurationMs = 0
            self.playbackStartWallTime = CFAbsoluteTimeGetCurrent()
            resetMetersForLayout()

            // Pre-buffer ~120ms before starting synchronizer clock
            feedNextPipelineChunks(targetLookaheadSeconds: 0.14)
            outputEngine.startPlayback(at: .zero, rate: 1.0)
            isPlaying = true

            feedTimer = Timer.scheduledTimer(withTimeInterval: 0.030, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onTimerTick()
                }
            }
        } catch {
            lastErrorMessage = "Errore avvio pipeline APAC: \(error)"
            isPlaying = false
        }
    }

    public func stopPlayback() {
        feedTimer?.invalidate()
        feedTimer = nil
        outputEngine.stopAndFlush()
        isPlaying = false
        pendingBuffersCount = 0
        for i in 0..<channelRMS.count {
            channelRMS[i] = 0.0
        }
        statusBannerText = "In pausa — \(selectedPreset.title)"
    }

    private func restartPipelinePreservingPreset() {
        let wasPlaying = isPlaying
        stopPlayback()
        if wasPlaying {
            startPlayback()
        }
    }

    // MARK: - Real-time Timer Loop
    private func onTimerTick() {
        guard isPlaying else { return }
        feedNextPipelineChunks(targetLookaheadSeconds: 0.16)
    }

    private func feedNextPipelineChunks(targetLookaheadSeconds: Double) {
        guard let renderer = renderer,
              let transcoder = transcoder,
              let pcmBuf = renderPCMBuffer else { return }

        let sr = transcoder.sampleRate
        let wallElapsed = max(0.0, CFAbsoluteTimeGetCurrent() - playbackStartWallTime)
        let syncTime = CMTimeGetSeconds(outputEngine.currentTime)
        let effectiveNow = (syncTime.isFinite && syncTime > 0.01) ? max(syncTime, wallElapsed * 0.9) : wallElapsed
        let targetEncodedTime = effectiveNow + targetLookaheadSeconds

        var blocksProcessed = 0
        let maxBlocksPerTick = 20

        while Double(transcoder.encodedSampleFrames) / sr < targetEncodedTime && blocksProcessed < maxBlocksPerTick {
            let t0 = CFAbsoluteTimeGetCurrent()

            let nextBlock: TrueHDAtmosBlock?
            if let ext = externalCAFSource {
                nextBlock = ext.nextBlock()
            } else {
                nextBlock = testSource.nextBlock()
            }

            guard let block = nextBlock else {
                // End of external file stream
                if let flushed = try? transcoder.flush(), !flushed.isEmpty {
                    outputEngine.scheduleSampleBuffers(flushed)
                }
                stopPlayback()
                statusBannerText = "Riproduzione file completata"
                return
            }

            // 1. Render 3D VBAP into 7.1.4 / 9.1.6 Float32 PCM
            renderer.render(block: block, into: pcmBuf)

            // 2. Measure instantaneous per-channel RMS & Peak for UI meters
            updateLiveMeters(from: pcmBuf, block: block)

            // 3. Encode on-the-fly into kAudioFormatAPAC CMSampleBuffers
            do {
                let sampleBuffers = try transcoder.pushPCMAndEncode(pcmBuf)
                if !sampleBuffers.isEmpty {
                    for sb in sampleBuffers {
                        encodedBytes += Int64(CMSampleBufferGetTotalSampleSize(sb))
                    }
                    encodedPackets = transcoder.encodedPacketCount
                    outputEngine.scheduleSampleBuffers(sampleBuffers)
                }
            } catch {
                lastErrorMessage = "Errore codifica APAC: \(error)"
                stopPlayback()
                return
            }

            let t1 = CFAbsoluteTimeGetCurrent()
            cumulativeCpuTimeMs += (t1 - t0) * 1000.0
            cumulativeAudioDurationMs += (Double(block.frameCount) / sr) * 1000.0
            blocksProcessed += 1
        }

        elapsedSeconds = effectiveNow
        pendingBuffersCount = outputEngine.pendingBufferCount
        if elapsedSeconds > 0.05 {
            effectiveBitrateKbps = (Double(encodedBytes * 8) / (Double(transcoder.encodedSampleFrames) / max(1.0, sr))) / 1000.0
        }
        if cumulativeCpuTimeMs > 0.001 {
            renderSpeedFactor = cumulativeAudioDurationMs / cumulativeCpuTimeMs
        }

        if let extName = activeExternalFileName {
            statusBannerText = "Streaming CAF Esterno: \(extName)"
        } else {
            statusBannerText = testSource.activeStatusDescription
            highlightedChannelIndex = testSource.activeHighlightedChannel
        }
    }

    private func updateLiveMeters(from pcmBuffer: AVAudioPCMBuffer, block: TrueHDAtmosBlock) {
        let numCh = targetLayout.channelCount
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0, let chData = pcmBuffer.floatChannelData else { return }

        if channelRMS.count != numCh {
            resetMetersForLayout()
        }

        let smoothing: Float = 0.35
        let peakDecay: Float = 0.96

        for c in 0..<numCh {
            let ptr = chData[c]
            var sumSq: Float = 0.0
            var maxAbs: Float = 0.0
            for i in 0..<frames {
                let v = abs(ptr[i])
                sumSq += v * v
                if v > maxAbs { maxAbs = v }
            }
            let instRMS = sqrt(sumSq / Float(frames))
            channelRMS[c] = channelRMS[c] * (1.0 - smoothing) + instRMS * smoothing
            channelPeaks[c] = max(maxAbs, channelPeaks[c] * peakDecay)
        }

        activeObjects = block.metadata
    }

    private func resetMetersForLayout() {
        let count = targetLayout.channelCount
        channelRMS = Array(repeating: 0.0, count: count)
        channelPeaks = Array(repeating: 0.0, count: count)
    }

    private func updateStaticPreview() {
        testSource.targetLayout = targetLayout
        testSource.preset = selectedPreset
        testSource.selectedSingleChannel = selectedSingleChannel
        testSource.manualX = manualX
        testSource.manualY = manualY
        testSource.manualZ = manualZ
        testSource.manualSpread = manualSpread
        testSource.resetTimeline()

        let previewRenderer = SpatialVBAPRenderer(targetLayout: targetLayout, sampleRate: 48000.0)
        if let block = testSource.nextBlock() {
            activeObjects = block.metadata
            highlightedChannelIndex = testSource.activeHighlightedChannel
            statusBannerText = testSource.activeStatusDescription

            // Compute static preview gains so user sees which speakers will activate even before pressing Play
            let count = targetLayout.channelCount
            var previewLevels = [Float](repeating: 0.0, count: count)
            for meta in block.metadata {
                let gains = previewRenderer.computeSpeakerGains(for: meta)
                for c in 0..<min(count, gains.count) {
                    previewLevels[c] = min(1.0, previewLevels[c] + gains[c] * 0.45)
                }
            }
            channelRMS = previewLevels
        }
    }

    // MARK: - APAC Round-Trip Verification (Encode -> CAF -> Decode -> Measure Height Energy)
    public func runAPACRoundTripDiagnostic() {
        do {
            let layout = targetLayout
            guard let avLayout = AVAudioChannelLayout(layoutTag: layout.channelLayoutTag) else { return }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("apac_ui_roundtrip_\(layout.rawValue).caf")
            try? FileManager.default.removeItem(at: tempURL)

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatAPAC,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: layout.channelCount,
                AVChannelLayoutKey: NSData(bytes: avLayout.layout, length: MemoryLayout<AudioChannelLayout>.size),
                AVEncoderBitRateKey: bitRate
            ]

            let outFile = try AVAudioFile(
                forWriting: tempURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            // Use the current preset or a full 3D sweep to test encoding and decoding
            var synth = SyntheticTrueHDAtmosSource(durationSeconds: 1.5, accessUnitsPerBlock: 4)
            let vbap = SpatialVBAPRenderer(targetLayout: layout, sampleRate: synth.sampleRate)
            let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channelLayout: avLayout)
            guard let renderBuf = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: AVAudioFrameCount(synth.blockFrameCount)
            ) else { return }

            while let block = synth.nextBlock() {
                vbap.render(block: block, into: renderBuf)
                try outFile.write(from: renderBuf)
            }
            outFile.close()

            let inFile = try AVAudioFile(forReading: tempURL)
            guard let decodedBuf = AVAudioPCMBuffer(
                pcmFormat: inFile.processingFormat,
                frameCapacity: AVAudioFrameCount(inFile.length)
            ) else { return }
            try inFile.read(into: decodedBuf)

            let frames = Int(decodedBuf.frameLength)
            let names = layout.channelNames
            let heightSet = Set(layout.heightChannelIndices)

            var results = [RoundTripChannelResult]()
            var totalHeightRMS: Float = 0.0

            if let floatData = decodedBuf.floatChannelData {
                for c in 0..<layout.channelCount {
                    var sumSq: Double = 0.0
                    let ptr = floatData[c]
                    for i in 0..<frames {
                        let v = Double(ptr[i])
                        sumSq += v * v
                    }
                    let rms = Float(sqrt(sumSq / Double(max(1, frames))))
                    let isH = heightSet.contains(c)
                    if isH { totalHeightRMS += rms }
                    results.append(
                        RoundTripChannelResult(
                            id: c,
                            channelName: names[c],
                            isHeight: isH,
                            isLFE: c == 3,
                            decodedRMS: rms
                        )
                    )
                }
            }

            self.roundTripResults = results
            self.roundTripPassed = totalHeightRMS > 0.08
        } catch {
            self.lastErrorMessage = "Verifica Round-Trip fallita: \(error.localizedDescription)"
            self.roundTripPassed = false
        }
    }
}

