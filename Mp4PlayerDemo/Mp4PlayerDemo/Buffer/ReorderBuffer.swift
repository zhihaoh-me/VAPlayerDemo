import Foundation
import CoreMedia
import os

/// Synchronous decode-and-reorder buffer.
/// Sits between the decoder and the renderer: accepts requests for frames by PTS,
/// internally drives decoding in decode-order, and reorders output to presentation-order.
///
/// Designed for synchronous access from `requestMediaDataWhenReady` callbacks
/// where actor isolation (async) cannot be used.
final class ReorderBuffer: @unchecked Sendable {
    private let demuxer: MP4Demuxer
    private let decoder: VideoDecoder
    private let sampleCount: Int

    /// Decoded frames waiting for their PTS turn, sorted by PTS ascending.
    private var frames: [BufferedFrame] = []

    /// Next decode-order sample index to feed into the decoder.
    private var nextDecodeIndex: Int = 0

    /// True once all samples have been decoded.
    private(set) var isEndOfStream: Bool = false

    var count: Int { frames.count }
    var isEmpty: Bool { frames.isEmpty }

    init(demuxer: MP4Demuxer, decoder: VideoDecoder, sampleCount: Int) {
        self.demuxer = demuxer
        self.decoder = decoder
        self.sampleCount = sampleCount
    }

    /// Request the decoded frame at the given PTS.
    /// Decodes samples as needed until the requested frame is available or all samples are exhausted.
    /// Returns nil only if the frame cannot be produced (decode error or not present in stream).
    func nextFrame(pts: CMTime) -> BufferedFrame? {
        // Check if we already have it
        if let frame = removeFrame(pts: pts) {
            return frame
        }

        // Decode until we find it or run out of samples
        while !isEndOfStream {
            decodeNextSample()

            if let frame = removeFrame(pts: pts) {
                return frame
            }
        }

        // End of stream — frame wasn't found at exact PTS
        return nil
    }

    /// Remove all remaining frames sorted by PTS (for end-of-stream flush).
    func drainAll() -> [BufferedFrame] {
        let drained = frames
        frames.removeAll()
        return drained
    }

    /// Discard all buffered frames and reset decode position.
    func clear() {
        frames.removeAll()
        nextDecodeIndex = 0
        isEndOfStream = false
    }

    // MARK: - Private

    private func decodeNextSample() {
        guard nextDecodeIndex < sampleCount else {
            decoder.finishDecoding()
            isEndOfStream = true
            Log.synchronizer.info("All \(self.sampleCount) samples decoded, reorder buffer has \(self.frames.count)")
            return
        }

        let index = nextDecodeIndex
        nextDecodeIndex += 1

        guard let sample = demuxer.getSample(at: index) else {
            Log.synchronizer.error("Failed to get sample at \(index)")
            return
        }

        do {
            let sampleData = try demuxer.readSample(at: index)
            if let decoded = try decoder.decode(sampleData: sampleData, sample: sample) {
                insertFrame(decoded)
            }
        } catch {
            Log.synchronizer.error("Decode error at sample \(index): \(error)")
        }
    }

    private func insertFrame(_ decoded: DecodedFrame) {
        let frame = BufferedFrame(
            pixelBuffer: decoded.pixelBuffer,
            presentationTime: decoded.presentationTime,
            decodeTime: decoded.decodeTime,
            sampleIndex: 0
        )
        let insertIdx = frames.firstIndex { $0.presentationTime > frame.presentationTime }
            ?? frames.endIndex
        frames.insert(frame, at: insertIdx)
    }

    private func removeFrame(pts: CMTime) -> BufferedFrame? {
        guard let idx = frames.firstIndex(where: { $0.presentationTime == pts }) else {
            return nil
        }
        return frames.remove(at: idx)
    }
}
