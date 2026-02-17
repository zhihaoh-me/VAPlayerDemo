import Foundation
import CoreMedia
import CoreVideo
import os

/// Buffer state for playback control
enum BufferState {
    case buffering   // Filling buffer, not enough to play
    case ready       // Sufficient buffer, can play
    case endOfStream // All samples decoded
}

/// Manages the decode buffer with dual-threshold strategy
final class BufferManager {
    /// The demuxer for reading samples
    private let demuxer: MP4Demuxer

    /// The decoder for decompressing samples
    private let decoder: VideoDecoder

    /// The frame buffer for storing decoded frames
    let frameBuffer: FrameBuffer

    /// Next sample index to decode
    private var nextSampleIndex: Int = 0

    /// Total number of samples
    private let totalSamples: Int

    /// Timescale for timestamp conversion
    private let timescale: UInt32

    /// Current buffer state
    private(set) var state: BufferState = .buffering

    /// Task for background filling
    private var fillTask: Task<Void, Never>?

    /// Flag to track if we've reached end of stream
    private(set) var isEndOfStream: Bool = false

    /// Flag to prevent concurrent fills
    private var isFilling: Bool = false

    init(demuxer: MP4Demuxer, decoder: VideoDecoder) {
        self.demuxer = demuxer
        self.decoder = decoder
        self.frameBuffer = FrameBuffer()
        self.totalSamples = demuxer.sampleCount
        self.timescale = demuxer.videoTrackInfo?.timescale ?? 30000
    }

    /// Start filling the buffer from the beginning
    func start() async {
        nextSampleIndex = 0
        isEndOfStream = false
        isFilling = true
        state = .buffering
        await frameBuffer.clear()
        await fillBuffer(currentTime: .zero)
        isFilling = false
    }

    /// Fill buffer up to target duration
    func fillBuffer(currentTime: CMTime) async {
        // Check if already at end
        guard !isEndOfStream else { return }

        // Fill until we reach target or run out of samples
        while await !frameBuffer.isBufferFull(currentTime: currentTime) {
            guard nextSampleIndex < totalSamples else {
                // Signal end of stream to decoder
                decoder.flush()
                decoder.finishDecoding()

                isEndOfStream = true
                state = .endOfStream
                Log.buffer.info("End of stream reached")
                break
            }

            do {
                // Get sample metadata
                guard let sample = demuxer.getSample(at: nextSampleIndex) else {
                    nextSampleIndex += 1
                    continue
                }

                // Read sample data
                let sampleData = try demuxer.readSample(at: nextSampleIndex)

                // Decode sample
                if let decodedFrame = try decoder.decode(sampleData: sampleData, sample: sample) {
                    // Create buffered frame
                    let bufferedFrame = BufferedFrame(
                        pixelBuffer: decodedFrame.pixelBuffer,
                        presentationTime: decodedFrame.presentationTime,
                        decodeTime: decodedFrame.decodeTime,
                        sampleIndex: nextSampleIndex
                    )

                    // Add to buffer
                    await frameBuffer.enqueue(bufferedFrame)
                }

                nextSampleIndex += 1

            } catch {
                let sampleIdx = nextSampleIndex
                Log.buffer.error("Error decoding sample \(sampleIdx): \(error)")
                nextSampleIndex += 1
            }
        }

        // Update state based on buffer level
        await updateState(currentTime: currentTime)
    }

    /// Check and refill buffer if needed (called from playback loop)
    func checkAndRefill(currentTime: CMTime) {
        // Skip if already filling or at end
        guard !isFilling && !isEndOfStream else { return }

        // Start new fill task if needed
        fillTask = Task {
            let shouldFetch = await frameBuffer.shouldFetch(currentTime: currentTime)
            guard shouldFetch && !self.isEndOfStream && !self.isFilling else { return }

            self.isFilling = true
            self.state = .buffering
            await self.fillBuffer(currentTime: currentTime)
            self.isFilling = false
        }
    }

    /// Get next frame for display
    func dequeueFrame(for time: CMTime) async -> BufferedFrame? {
        return await frameBuffer.dequeue(for: time)
    }

    /// Peek at next frame without removing
    func peekNextFrame() async -> BufferedFrame? {
        return await frameBuffer.peek()
    }

    /// Get current buffer status
    func getBufferStatus(currentTime: CMTime) async -> String {
        let bufferStatus = await frameBuffer.status(currentTime: currentTime)
        return "state=\(state), nextSample=\(nextSampleIndex)/\(totalSamples), \(bufferStatus)"
    }

    /// Seek to a specific time (clears buffer and repositions)
    func seek(to time: CMTime) async {
        // Cancel any ongoing fill
        fillTask?.cancel()

        // Clear buffer
        await frameBuffer.clear()

        // Find the keyframe at or before the target time
        guard let sampleTable = demuxer.sampleTable else { return }

        // Convert time to sample index
        let targetPTS = time.value

        // Find sample with closest PTS
        var targetIndex = 0
        for (index, sample) in sampleTable.samples.enumerated() {
            if sample.presentationTime <= targetPTS {
                targetIndex = index
            } else {
                break
            }
        }

        // Find keyframe at or before target
        if let keyframeIndex = sampleTable.keyframeBefore(sampleIndex: targetIndex) {
            nextSampleIndex = keyframeIndex
        } else {
            nextSampleIndex = 0
        }

        isEndOfStream = false
        state = .buffering

        // Start filling from new position
        await fillBuffer(currentTime: time)
    }

    /// Stop buffer manager
    func stop() {
        fillTask?.cancel()
        fillTask = nil
    }

    // MARK: - Private

    private func updateState(currentTime: CMTime) async {
        if isEndOfStream {
            state = .endOfStream
        } else if await frameBuffer.hasEnoughBuffer(currentTime: currentTime) {
            state = .ready
        } else {
            state = .buffering
        }
    }
}
