import Foundation
import AVFoundation
import CoreMedia
import Combine
import os

/// Video player engine using AVSampleBufferRenderSynchronizer + AVSampleBufferDisplayLayer.
/// Milestone 1: scaffold — load and configure only, no playback yet.
@MainActor
class SampleBufferPlayerEngine: ObservableObject {
    // MARK: - Published State

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

    // MARK: - Load

    /// Parse the file and configure decoder + display layer. No playback yet.
    func load(url: URL) async throws {
        // Reset
        state = .idle
        currentTime = .zero

        // Demux
        let reader = try FileByteRangeReader(url: url)
        let demuxer = MP4Demuxer(reader: reader)
        try demuxer.parse()

        guard let trackInfo = demuxer.videoTrackInfo else {
            throw VideoPlayerError.noVideoTrack
        }

        self.demuxer = demuxer
        self.duration = CMTime(value: Int64(trackInfo.duration), timescale: Int32(trackInfo.timescale))
        self.videoSize = CGSize(width: CGFloat(trackInfo.width), height: CGFloat(trackInfo.height))

        // Decode
        let decoder = VideoDecoder(trackInfo: trackInfo)
        try decoder.configure()
        self.decoder = decoder

        // Wire display layer renderer into synchronizer
        if #available(iOS 17.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            synchronizer.addRenderer(renderer)
        } else {
            synchronizer.addRenderer(displayLayer)
        }

        let dims = "\(trackInfo.width)x\(trackInfo.height)"
        let dur = duration.seconds
        let samples = demuxer.sampleCount
        Log.synchronizer.info("Loaded video: \(dims), duration=\(dur)s, samples=\(samples)")
    }
}
