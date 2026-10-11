import Foundation
import AVFoundation
import CoreMedia

/// Manages real-time playback of `kAudioFormatAPAC` (`'apac'`) `CMSampleBuffer` packets
/// through `AVSampleBufferAudioRenderer` and `AVSampleBufferRenderSynchronizer`.
///
/// On tvOS (Apple TV 4K), feeding an `'apac'` stream with `kAudioChannelLayoutTag_Atmos_7_1_4`
/// or `kAudioChannelLayoutTag_Atmos_9_1_6` into `AVSampleBufferAudioRenderer` engages the system
/// Spatial Audio pipeline and outputs **Dolby MAT 2.0 (Dolby Atmos)** over HDMI.
public final class AtmosAPACAudioOutputEngine: @unchecked Sendable {
    public let audioRenderer: AVSampleBufferAudioRenderer
    public let renderSynchronizer: AVSampleBufferRenderSynchronizer
    private let serializationQueue = DispatchQueue(label: "com.appletv.truehd-apac.renderer-queue", qos: .userInteractive)

    private var pendingBuffers: [CMSampleBuffer] = []
    private var isRequestingMediaData = false
    private(set) public var totalEnqueuedBuffers: Int = 0

    public init() {
        self.audioRenderer = AVSampleBufferAudioRenderer()
        self.renderSynchronizer = AVSampleBufferRenderSynchronizer()
        self.renderSynchronizer.addRenderer(self.audioRenderer)
    }

    /// Queues compressed APAC `CMSampleBuffer` packets for playback.
    public func scheduleSampleBuffers(_ buffers: [CMSampleBuffer]) {
        serializationQueue.sync {
            pendingBuffers.append(contentsOf: buffers)
            drainQueueIfReady()
        }
    }

    /// Starts synchronized playback of the APAC spatial stream.
    public func startPlayback(at time: CMTime = .zero, rate: Float = 1.0) {
        #if os(tvOS) || os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
        try? session.setActive(true)
        #endif

        serializationQueue.sync {
            if !isRequestingMediaData {
                isRequestingMediaData = true
                audioRenderer.requestMediaDataWhenReady(on: serializationQueue) { [weak self] in
                    self?.drainQueueIfReady()
                }
            }
        }
        renderSynchronizer.setRate(rate, time: time)
    }

    /// Pauses playback.
    public func pause() {
        renderSynchronizer.rate = 0.0
    }

    /// Stops and flushes the renderer pipeline.
    public func stopAndFlush() {
        renderSynchronizer.rate = 0.0
        serializationQueue.sync {
            if isRequestingMediaData {
                audioRenderer.stopRequestingMediaData()
                isRequestingMediaData = false
            }
            pendingBuffers.removeAll()
            audioRenderer.flush()
            totalEnqueuedBuffers = 0
        }
    }

    /// Current playback time on the render synchronizer timeline.
    public var currentTime: CMTime {
        renderSynchronizer.currentTime()
    }

    /// Number of compressed APAC buffers waiting to be enqueued into AVSampleBufferAudioRenderer.
    public var pendingBufferCount: Int {
        serializationQueue.sync { pendingBuffers.count }
    }

    private func drainQueueIfReady() {
        while audioRenderer.isReadyForMoreMediaData && !pendingBuffers.isEmpty {
            let nextBuffer = pendingBuffers.removeFirst()
            enqueueSampleBuffer(nextBuffer)
            totalEnqueuedBuffers += 1
        }
    }

    @available(macOS, deprecated: 27.0)
    @available(tvOS, deprecated: 27.0)
    @available(iOS, deprecated: 27.0)
    private func enqueueSampleBuffer(_ buffer: CMSampleBuffer) {
        audioRenderer.enqueue(buffer)
    }
}

