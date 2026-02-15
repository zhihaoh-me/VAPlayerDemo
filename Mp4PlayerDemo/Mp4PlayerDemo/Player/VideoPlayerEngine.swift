import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import Combine
import os

/// Playback state for the video player
enum PlaybackState {
    case idle           // Not started
    case buffering      // Filling initial buffer
    case playing        // Actively playing
    case ended          // Reached end of video
}

/// Coordinates video playback with CADisplayLink timing
@MainActor
class VideoPlayerEngine: ObservableObject {
    // MARK: - Published State

    /// Current frame for display
    @Published private(set) var currentFrame: CVPixelBuffer?

    /// Current playback state
    @Published private(set) var state: PlaybackState = .idle

    /// Current playback time
    @Published private(set) var currentTime: CMTime = .zero

    /// Video duration
    @Published private(set) var duration: CMTime = .zero

    /// Video dimensions (width x height)
    @Published private(set) var videoSize: CGSize = .zero

    // MARK: - Components

    private var demuxer: MP4Demuxer?
    private var decoder: VideoDecoder?
    private var bufferManager: BufferManager?

    // MARK: - Display Link

    private var displayLink: CADisplayLink?
    private var playbackStartTime: CFTimeInterval = 0
    private var playbackStartPTS: CMTime = .zero

    // MARK: - Video Info

    private var timescale: UInt32 = 30000

    // MARK: - Initialization

    init() {}

    /// Load a video file for playback
    func load(url: URL) async throws {
        // Reset state
        stop()
        state = .idle

        // Create demuxer
        let reader = try FileByteRangeReader(url: url)
        let demuxer = MP4Demuxer(reader: reader)
        try demuxer.parse()

        guard let trackInfo = demuxer.videoTrackInfo else {
            throw VideoPlayerError.noVideoTrack
        }

        self.demuxer = demuxer
        self.timescale = trackInfo.timescale
        self.duration = CMTime(value: Int64(trackInfo.duration), timescale: Int32(trackInfo.timescale))
        self.videoSize = CGSize(width: CGFloat(trackInfo.width), height: CGFloat(trackInfo.height))

        // Create decoder
        let decoder = VideoDecoder(trackInfo: trackInfo)
        try decoder.configure()
        self.decoder = decoder

        // Create buffer manager
        let bufferManager = BufferManager(demuxer: demuxer, decoder: decoder)
        self.bufferManager = bufferManager

        let durationSecs = duration.seconds
        let sampleCount = demuxer.sampleCount
        let dims = "\(trackInfo.width)x\(trackInfo.height)"
        Log.player.info("Loaded video")
        Log.player.info("  Duration: \(durationSecs)s")
        Log.player.info("  Samples: \(sampleCount)")
        Log.player.info("  Dimensions: \(dims)")
    }

    /// Start playback
    func play() {
        guard state != .playing else { return }
        guard bufferManager != nil else {
            Log.player.warning("Cannot play - no video loaded")
            return
        }

        state = .buffering

        // Start filling buffer
        Task {
            await startBuffering()
        }
    }

    /// Stop playback
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        bufferManager?.stop()
        state = .idle
        currentFrame = nil
        currentTime = .zero
    }

    // MARK: - Private Methods

    private func startBuffering() async {
        guard let bufferManager = bufferManager else { return }

        Log.player.info("Starting initial buffer fill...")

        // Fill initial buffer
        await bufferManager.start()

        // Check if we have enough to start playback
        if await bufferManager.frameBuffer.hasEnoughBuffer(currentTime: .zero) {
            Log.player.info("Buffer ready, starting playback")
            startDisplayLink()
        } else if bufferManager.isEndOfStream {
            // Very short video - start anyway
            Log.player.info("Short video, starting playback")
            startDisplayLink()
        } else {
            Log.player.info("Waiting for buffer...")
            // Keep buffering state, displayLinkFired will check
            startDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        state = .playing
        playbackStartTime = CACurrentMediaTime()
        playbackStartPTS = currentTime

        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.add(to: .main, forMode: .common)

        Log.player.info("DisplayLink started")
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let bufferManager = bufferManager else { return }

        // Calculate current playback time
        let elapsed = link.timestamp - playbackStartTime
        let newTime = CMTime(seconds: playbackStartPTS.seconds + elapsed, preferredTimescale: Int32(timescale))
        currentTime = newTime

        // Check if buffer needs refilling (non-blocking)
        bufferManager.checkAndRefill(currentTime: newTime)

        // Try to get next frame
        Task { @MainActor in
            await dequeueAndDisplayFrame(for: newTime)
        }
    }

    private func dequeueAndDisplayFrame(for time: CMTime) async {
        guard let bufferManager = bufferManager else { return }

        // Get frame for current time
        if let frame = await bufferManager.dequeueFrame(for: time) {
            currentFrame = frame.pixelBuffer
        }

        // Check for end of stream
        if bufferManager.isEndOfStream {
            let isEmpty = await bufferManager.frameBuffer.isEmpty
            if isEmpty {
                Log.player.info("Playback complete")
                displayLink?.invalidate()
                displayLink = nil
                state = .ended
            }
        }

        // Update state based on buffer
        if state == .playing {
            let hasEnough = await bufferManager.frameBuffer.hasEnoughBuffer(currentTime: time)
            if !hasEnough && !bufferManager.isEndOfStream {
                // Could pause for buffering here, but for simplicity we continue
                // print("VideoPlayerEngine: Buffer low at \(time.seconds)s")
            }
        }
    }
}

// MARK: - Errors

enum VideoPlayerError: Error {
    case noVideoTrack
    case decoderNotConfigured
    case bufferEmpty
}
