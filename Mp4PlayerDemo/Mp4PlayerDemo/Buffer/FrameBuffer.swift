import Foundation
import CoreMedia
import CoreVideo

/// Configuration for buffer thresholds
nonisolated enum BufferConfig {
    /// Target buffer duration ahead of playback position (fill up to this)
    static let targetSeconds: Double = 3.0

    /// Low threshold - trigger refill when buffer falls below this
    static let lowThresholdSeconds: Double = 1.0
}

/// A decoded frame ready for display
struct BufferedFrame {
    /// The decoded pixel buffer
    let pixelBuffer: CVPixelBuffer

    /// Presentation timestamp
    let presentationTime: CMTime

    /// Decode timestamp
    let decodeTime: CMTime

    /// Sample index in the video
    let sampleIndex: Int
}

/// Thread-safe buffer for decoded frames using Swift actor
actor FrameBuffer {
    /// Stored decoded frames, sorted by presentation time
    private var frames: [BufferedFrame] = []

    /// Maximum number of frames to buffer (memory safety)
    private let maxFrames: Int = 200  // Enough for full video test

    /// Number of frames currently buffered
    var count: Int {
        frames.count
    }

    /// Check if buffer is empty
    var isEmpty: Bool {
        frames.isEmpty
    }

    /// Add a decoded frame to the buffer
    func enqueue(_ frame: BufferedFrame) {
        // Don't exceed max frames
        if frames.count >= maxFrames {
            // Remove oldest frame
            frames.removeFirst()
        }

        frames.append(frame)

        // Keep sorted by presentation time
        frames.sort { $0.presentationTime < $1.presentationTime }
    }

    /// Get the next frame for display
    /// Returns the earliest frame if its PTS <= current time, nil otherwise
    func dequeue(for time: CMTime) -> BufferedFrame? {
        guard let firstFrame = frames.first else { return nil }

        // Only return if it's time to display (PTS <= current time)
        // This ensures frames are always shown in presentation order
        if firstFrame.presentationTime <= time {
            return frames.removeFirst()
        }

        // Not yet time to display this frame
        return nil
    }

    /// Peek at the next frame without removing it
    func peek() -> BufferedFrame? {
        frames.first
    }

    /// Get the duration of buffered content ahead of the given time
    func bufferedDuration(from currentTime: CMTime) -> Double {
        guard let lastFrame = frames.last else { return 0 }
        let duration = lastFrame.presentationTime - currentTime
        return max(0, duration.seconds)
    }

    /// Check if we should fetch more samples (buffer below low threshold)
    func shouldFetch(currentTime: CMTime) -> Bool {
        return bufferedDuration(from: currentTime) < BufferConfig.lowThresholdSeconds
    }

    /// Check if we have enough buffer to continue playback
    func hasEnoughBuffer(currentTime: CMTime) -> Bool {
        return bufferedDuration(from: currentTime) >= BufferConfig.lowThresholdSeconds
    }

    /// Check if buffer is at target level
    func isBufferFull(currentTime: CMTime) -> Bool {
        return bufferedDuration(from: currentTime) >= BufferConfig.targetSeconds
    }

    /// Clear all buffered frames
    func clear() {
        frames.removeAll()
    }

    /// Get buffer status for debugging
    func status(currentTime: CMTime) -> String {
        let duration = bufferedDuration(from: currentTime)
        let firstPTS = frames.first?.presentationTime.seconds ?? 0
        let lastPTS = frames.last?.presentationTime.seconds ?? 0
        return "frames=\(frames.count), duration=\(String(format: "%.2f", duration))s, range=[\(String(format: "%.2f", firstPTS))-\(String(format: "%.2f", lastPTS))]"
    }
}
