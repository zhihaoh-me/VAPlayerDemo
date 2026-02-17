import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Combine
import os

/// Video player engine using AVSampleBufferRenderSynchronizer + AVSampleBufferDisplayLayer.
/// Requires iOS 17+.
///
/// `load`, `play`, `stop` are called from the main thread by SwiftUI.
/// The feeding loop runs on `feedingQueue`.
class SampleBufferPlayerEngine: ObservableObject {
    // MARK: - Published State (set only on main thread)

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentTime: CMTime = .zero
    @Published private(set) var duration: CMTime = .zero
    @Published private(set) var videoSize: CGSize = .zero

    /// The display layer for the view to host.
    let displayLayer = AVSampleBufferDisplayLayer()

    // MARK: - Components

    private var demuxer: MP4Demuxer?
    private var decoder: VideoDecoder?
    private let synchronizer = AVSampleBufferRenderSynchronizer()

    private var renderer: AVSampleBufferVideoRenderer {
        displayLayer.sampleBufferRenderer
    }

    // MARK: - Feeding State

    private let feedingQueue = DispatchQueue(label: "com.mp4player.sampleBufferFeeding")
    private var timescale: Int32 = 0
    private var rendererAdded = false

    // MARK: - Load

    func load(url: URL) throws {
        stop()
        state = .idle
        currentTime = .zero

        let reader = try FileByteRangeReader(url: url)
        let demuxer = MP4Demuxer(reader: reader)
        try demuxer.parse()

        guard let trackInfo = demuxer.videoTrackInfo else {
            throw VideoPlayerError.noVideoTrack
        }

        self.demuxer = demuxer
        self.timescale = Int32(trackInfo.timescale)
        self.duration = CMTime(value: Int64(trackInfo.duration), timescale: self.timescale)
        self.videoSize = CGSize(width: CGFloat(trackInfo.width), height: CGFloat(trackInfo.height))

        let decoder = VideoDecoder(trackInfo: trackInfo)
        try decoder.configure()
        self.decoder = decoder

        if !rendererAdded {
            synchronizer.addRenderer(renderer)
            rendererAdded = true
        }

        let dims = "\(trackInfo.width)x\(trackInfo.height)"
        let dur = duration.seconds
        let samples = demuxer.sampleCount
        Log.synchronizer.info("Loaded video: \(dims), duration=\(dur)s, samples=\(samples)")
    }

    // MARK: - Playback

    func play() {
        guard state != .playing,
              let demuxer, let decoder else {
            Log.synchronizer.warning("play() called but not ready")
            return
        }

        state = .playing

        let feedState = FeedState(
            demuxer: demuxer,
            decoder: decoder,
            sampleCount: demuxer.sampleCount,
            timescale: timescale
        )

        let r = renderer
        r.requestMediaDataWhenReady(on: feedingQueue) { [weak self] in
            guard let self else { return }
            self.feedLoop(renderer: r, state: feedState)
        }

        synchronizer.setRate(1.0, time: .zero)
        Log.synchronizer.info("Playback started")
    }

    func stop() {
        renderer.stopRequestingMediaData()
        synchronizer.setRate(0.0, time: .zero)
        renderer.flush()

        state = .idle
        currentTime = .zero
    }

    // MARK: - Feed State (only accessed on feedingQueue)

    private final class FeedState: @unchecked Sendable {
        let demuxer: MP4Demuxer
        let decoder: VideoDecoder
        let sampleCount: Int
        let timescale: Int32
        var nextIndex: Int = 0

        init(demuxer: MP4Demuxer, decoder: VideoDecoder, sampleCount: Int, timescale: Int32) {
            self.demuxer = demuxer
            self.decoder = decoder
            self.sampleCount = sampleCount
            self.timescale = timescale
        }
    }

    // MARK: - Feeding Loop (runs on feedingQueue)

    private func feedLoop(renderer: AVSampleBufferVideoRenderer, state: FeedState) {
        while renderer.isReadyForMoreMediaData {
            let index = state.nextIndex
            state.nextIndex += 1

            guard index < state.sampleCount else {
                finishFeeding(renderer: renderer, state: state)
                return
            }

            if let cmSample = decodeAndWrap(index: index, state: state) {
                renderer.enqueue(cmSample)
                if index < 3 {
                    let pts = CMSampleBufferGetPresentationTimeStamp(cmSample).seconds
                    Log.synchronizer.info("Enqueued sample \(index), pts=\(pts)s, rendererStatus=\(renderer.status.rawValue)")
                }
            }
        }
        Log.synchronizer.info("feedLoop paused, fed \(state.nextIndex) samples so far")
    }

    private func decodeAndWrap(index: Int, state: FeedState) -> CMSampleBuffer? {
        guard let sample = state.demuxer.getSample(at: index) else {
            Log.synchronizer.error("Failed to get sample at \(index)")
            return nil
        }

        do {
            let sampleData = try state.demuxer.readSample(at: index)
            if let decoded = try state.decoder.decode(sampleData: sampleData, sample: sample) {
                return wrapPixelBuffer(decoded.pixelBuffer,
                                       pts: decoded.presentationTime,
                                       duration: CMTime(value: Int64(sample.duration), timescale: state.timescale))
            }
        } catch {
            Log.synchronizer.error("Decode error at sample \(index): \(error)")
        }
        return nil
    }

    private func finishFeeding(renderer: AVSampleBufferVideoRenderer, state: FeedState) {
        state.decoder.finishDelayedFrames()
        let remaining = state.decoder.drainFrames()

        for frame in remaining {
            if let cmSample = wrapPixelBuffer(frame.pixelBuffer,
                                               pts: frame.presentationTime,
                                               duration: CMTime(value: 1, timescale: state.timescale)) {
                renderer.enqueue(cmSample)
            }
        }

        renderer.stopRequestingMediaData()
        Log.synchronizer.info("Feeding complete, drained \(remaining.count) delayed frames")

        DispatchQueue.main.async { [weak self] in
            self?.state = .ended
        }
    }

    // MARK: - Helpers

    private func wrapPixelBuffer(_ pixelBuffer: CVPixelBuffer,
                                  pts: CMTime,
                                  duration: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else {
            Log.synchronizer.error("CMVideoFormatDescription creation failed: \(status)")
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard sbStatus == noErr else {
            Log.synchronizer.error("CMSampleBuffer creation failed: \(sbStatus)")
            return nil
        }

        return sampleBuffer
    }
}
