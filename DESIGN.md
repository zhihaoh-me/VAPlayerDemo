# Custom MP4 Video Player - Design Document

## Overview

This project implements a custom MP4 video player for iOS that plays video without using AVPlayer or any third-party libraries. The goal is to verify that VideoToolbox and Metal can correctly render video by implementing the full pipeline from MP4 parsing to frame display.

**Scope**:
- Video playback only (no audio)
- Play only (no pause/seek controls)
- Custom MP4 box parsing (no ffmpeg)
- Byte range reading pattern (simulating progressive download)

**Test File**: `demo.mp4` (included in project)

---

## Architecture

### High-Level Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                     SwiftUI VideoPlayerView                  │
│                      (Metal MTKView wrapper)                 │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ CVPixelBuffer
                              │
┌─────────────────────────────────────────────────────────────┐
│                      VideoPlayerEngine                       │
│         (Playback loop with CADisplayLink timing)            │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ Decoded frames
                              │
┌─────────────────────────────────────────────────────────────┐
│                       VideoDecoder                           │
│              (VideoToolbox VTDecompressionSession)           │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ Raw H.264/HEVC samples
                              │
┌─────────────────────────────────────────────────────────────┐
│                        MP4Demuxer                            │
│            (Custom box parser + sample table)                │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ Byte ranges
                              │
┌─────────────────────────────────────────────────────────────┐
│                      ByteRangeReader                         │
│           (Simulates progressive download from file)         │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │
                         demo.mp4
```

---

## Component Details

### 1. ByteRangeReader

**Responsibility**: Read bytes from MP4 file using byte range requests, mimicking progressive download behavior.

**Design Pattern**: Simulates HTTP Range requests by reading specific byte ranges from the local file.

```swift
protocol ByteRangeReader {
    /// Total size of the resource
    var length: UInt64 { get }

    /// Read bytes from a specific range
    func read(offset: UInt64, length: Int) throws -> Data
}

class FileByteRangeReader: ByteRangeReader {
    private let fileHandle: FileHandle
    let length: UInt64

    init(url: URL) throws { ... }

    func read(offset: UInt64, length: Int) throws -> Data {
        // Seek to offset and read length bytes
        // Mimics: HTTP Range: bytes=offset-(offset+length-1)
    }
}
```

**Why this pattern**:
- Mirrors real-world streaming where you don't have the full file upfront
- Forces proper handling of partial data
- Can later be extended to actual HTTP byte range requests

---

### 2. MP4Demuxer

**Responsibility**: Parse MP4 box structure and build sample tables for video track extraction.

**Two-Phase Approach** (per Mp4_media3_walkthrough.md):

1. **Initialization Phase**: Parse moov box to build sample tables
2. **Playback Phase**: Use sample tables to read samples from mdat on-demand

#### Box Parsing

```swift
struct MP4Box {
    let type: FourCharCode    // 'ftyp', 'moov', 'mdat', etc.
    let size: UInt64          // Total box size including header
    let offset: UInt64        // Absolute file offset
    let headerSize: Int       // 8 or 16 (extended size)
}

class MP4BoxParser {
    private let reader: ByteRangeReader

    /// Parse box header at given offset
    func parseBoxHeader(at offset: UInt64) throws -> MP4Box {
        // Read 8 bytes: [4-byte size][4-byte type]
        // If size == 1, read 8 more bytes for extended size
        // If size == 0, box extends to end of file
    }

    /// Recursively parse container boxes
    func parseContainerBox(_ box: MP4Box) throws -> [MP4Box] { ... }
}
```

#### Key Boxes to Parse

| Box | Purpose |
|-----|---------|
| `ftyp` | File type identification |
| `moov` | Movie metadata container |
| `mvhd` | Movie header (timescale, duration) |
| `trak` | Track container |
| `tkhd` | Track header |
| `mdia` | Media container |
| `mdhd` | Media header (track timescale) |
| `hdlr` | Handler type (vide/soun) |
| `minf` | Media info container |
| `stbl` | Sample table container |
| `stsd` | Sample description (codec config) |
| `stts` | Decode time-to-sample |
| `stsc` | Sample-to-chunk mapping |
| `stsz` | Sample sizes |
| `stco`/`co64` | Chunk offsets |
| `stss` | Sync samples (keyframes) |
| `ctts` | Composition time offsets |
| `mdat` | Media data (raw frames) |

#### Sample Table Construction

Following the algorithm from `Mp4_media3_walkthrough.md`:

```swift
struct SampleTable {
    let offsets: [UInt64]      // Absolute byte position of each sample
    let sizes: [UInt32]        // Size of each sample in bytes
    let timestamps: [Int64]    // Presentation timestamp (microseconds)
    let flags: [SampleFlags]   // KEY_FRAME for I-frames
    let timescale: UInt32      // For timestamp conversion
}

// Construction combines: stco + stsc + stsz + stts + ctts + stss
func buildSampleTable(...) -> SampleTable {
    // 1. Read chunk offsets from stco/co64
    // 2. Read sample-to-chunk mapping from stsc
    // 3. Read sample sizes from stsz
    // 4. Calculate absolute offset for each sample
    // 5. Calculate timestamps from stts + ctts
    // 6. Mark keyframes from stss
}
```

#### Codec Configuration

Extract from `avcC` (H.264) or `hvcC` (HEVC) box within stsd:

```swift
struct VideoTrackInfo {
    let width: UInt32
    let height: UInt32
    let codecType: CMVideoCodecType  // kCMVideoCodecType_H264, kCMVideoCodecType_HEVC
    let codecConfig: Data            // Raw avcC/hvcC data for VideoToolbox
    let timescale: UInt32
    let duration: UInt64
}
```

---

### 3. VideoDecoder

**Responsibility**: Decode compressed video samples using VideoToolbox.

```swift
class VideoDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    /// Initialize with codec configuration from demuxer
    func configure(with trackInfo: VideoTrackInfo) throws {
        // 1. Create CMVideoFormatDescription from avcC/hvcC
        // 2. Create VTDecompressionSession
    }

    /// Decode a single sample, returns CVPixelBuffer
    func decode(sampleData: Data,
                presentationTime: CMTime,
                isKeyFrame: Bool) throws -> CVPixelBuffer? {
        // 1. Create CMSampleBuffer from raw data
        // 2. Call VTDecompressionSessionDecodeFrame
        // 3. Handle async callback with decoded frame
    }
}
```

**Key VideoToolbox APIs**:
- `CMVideoFormatDescriptionCreateFromH264ParameterSets` / `...HEVC...`
- `VTDecompressionSessionCreate`
- `VTDecompressionSessionDecodeFrame`

---

### 4. VideoPlayerEngine

**Responsibility**: Coordinate demuxing, decoding, and rendering with proper frame timing.

```swift
class VideoPlayerEngine: ObservableObject {
    private let demuxer: MP4Demuxer
    private let decoder: VideoDecoder
    private var displayLink: CADisplayLink?
    private var currentSampleIndex: Int = 0

    @Published var currentFrame: CVPixelBuffer?

    /// Start playback
    func play() {
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // 1. Check if it's time for next frame based on timestamps
        // 2. Read sample from demuxer
        // 3. Decode sample
        // 4. Update currentFrame for rendering
    }
}
```

**Frame Timing**:
- Use `CADisplayLink` for vsync-aligned frame updates
- Compare sample presentation timestamps with playback clock
- Handle frame drops if decoding is too slow

---

### 5. MetalRenderer

**Responsibility**: Render CVPixelBuffer to screen using Metal.

```swift
class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?

    /// Render a pixel buffer to the MTKView
    func render(pixelBuffer: CVPixelBuffer, to view: MTKView) {
        // 1. Create Metal texture from CVPixelBuffer via texture cache
        // 2. Create render pass to draw texture to view
        // 3. Handle YUV to RGB conversion in shader if needed
    }
}
```

**Why Metal**:
- Zero-copy path from VideoToolbox (CVPixelBuffer → MTLTexture)
- GPU-accelerated YUV→RGB conversion
- Proper color space handling

---

### 6. SwiftUI VideoPlayerView

**Responsibility**: SwiftUI wrapper for Metal view.

```swift
struct VideoPlayerView: UIViewRepresentable {
    @ObservedObject var engine: VideoPlayerEngine

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        // Trigger redraw when currentFrame changes
    }
}
```

---

## Buffer Management

### Overview

The player uses a **dual-threshold buffer strategy** to decode frames ahead of the current playback position. This ensures smooth playback by having decoded frames ready before they need to be displayed.

**Reference**: Media3/ExoPlayer uses a similar approach with `DefaultLoadControl.java`, which manages buffer thresholds for both time duration and byte size. Our simplified version uses two time-based thresholds.

### Threshold Values (Hardcoded)

| Constant | Value | Description |
|----------|-------|-------------|
| `BUFFER_TARGET_SECONDS` | 3.0 sec | Target buffer ahead of playback position (X) |
| `BUFFER_LOW_THRESHOLD_SECONDS` | 1.0 sec | Trigger refill when buffer falls below this (Y) |

```swift
enum BufferConfig {
    static let targetSeconds: Double = 3.0      // X: Fetch up to 3 seconds ahead
    static let lowThresholdSeconds: Double = 1.0 // Y: Refill when below 1 second
}
```

### Buffer State Machine

```
                    ┌─────────────────────────────────────────┐
                    │                                         │
                    ▼                                         │
┌──────────────────────────────────┐                         │
│           BUFFERING              │                         │
│  (Fetching + Decoding samples)   │                         │
└──────────────────────────────────┘                         │
          │                                                   │
          │ bufferedDuration >= BUFFER_TARGET (X)            │
          ▼                                                   │
┌──────────────────────────────────┐                         │
│            READY                 │                         │
│  (Sufficient buffer, playing)    │                         │
└──────────────────────────────────┘                         │
          │                                                   │
          │ bufferedDuration < BUFFER_LOW_THRESHOLD (Y)      │
          └───────────────────────────────────────────────────┘
```

### Buffer Logic

```swift
class FrameBuffer {
    private var decodedFrames: [(timestamp: CMTime, pixelBuffer: CVPixelBuffer)] = []
    private let queue = DispatchQueue(label: "frame-buffer")

    /// Duration of buffered content ahead of current time
    func bufferedDuration(from currentTime: CMTime) -> Double {
        guard let lastFrame = decodedFrames.last else { return 0 }
        return (lastFrame.timestamp - currentTime).seconds
    }

    /// Check if we should fetch more samples
    func shouldFetch(currentTime: CMTime) -> Bool {
        return bufferedDuration(from: currentTime) < BufferConfig.lowThresholdSeconds
    }

    /// Check if we have enough buffer to continue
    func hasEnoughBuffer(currentTime: CMTime) -> Bool {
        return bufferedDuration(from: currentTime) >= BufferConfig.lowThresholdSeconds
    }

    /// Add decoded frame to buffer
    func enqueue(frame: CVPixelBuffer, timestamp: CMTime) { ... }

    /// Get next frame for display (removes from buffer)
    func dequeue(for timestamp: CMTime) -> CVPixelBuffer? { ... }
}
```

### Fetch and Decode Pipeline

The buffer management coordinates three operations:

1. **Fetch**: Read sample data from MP4 via ByteRangeReader
2. **Decode**: Decompress sample using VideoToolbox
3. **Buffer**: Store decoded CVPixelBuffer with timestamp

```swift
class BufferManager {
    private let demuxer: MP4Demuxer
    private let decoder: VideoDecoder
    private let frameBuffer: FrameBuffer
    private var nextSampleIndex: Int = 0

    /// Fill buffer up to target duration
    func fillBuffer(currentTime: CMTime) async {
        while frameBuffer.bufferedDuration(from: currentTime) < BufferConfig.targetSeconds {
            guard nextSampleIndex < demuxer.sampleCount else { break }

            // 1. Fetch sample data
            let sample = try await demuxer.readSample(at: nextSampleIndex)

            // 2. Decode sample
            if let pixelBuffer = try await decoder.decode(sample) {
                // 3. Add to buffer
                frameBuffer.enqueue(frame: pixelBuffer, timestamp: sample.presentationTime)
            }

            nextSampleIndex += 1
        }
    }

    /// Called periodically from playback loop
    func checkAndRefill(currentTime: CMTime) {
        if frameBuffer.shouldFetch(currentTime: currentTime) {
            Task {
                await fillBuffer(currentTime: currentTime)
            }
        }
    }
}
```

### Integration with Playback Loop

```swift
class VideoPlayerEngine {
    private let bufferManager: BufferManager
    private let frameBuffer: FrameBuffer

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let currentTime = playbackClock.currentTime

        // 1. Check if buffer needs refilling
        bufferManager.checkAndRefill(currentTime: currentTime)

        // 2. Get frame for current time
        if let frame = frameBuffer.dequeue(for: currentTime) {
            currentFrame = frame  // Triggers Metal render
        }

        // 3. Advance playback clock
        playbackClock.advance(by: link.targetTimestamp - link.timestamp)
    }
}
```

### Threading Model

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│     Main Thread     │     │   Decode Thread     │     │   Fetch Thread      │
│   (DisplayLink)     │     │  (VideoToolbox)     │     │  (ByteRangeReader)  │
├─────────────────────┤     ├─────────────────────┤     ├─────────────────────┤
│ - Render frames     │     │ - Decode samples    │     │ - Read byte ranges  │
│ - Dequeue buffer    │     │ - Enqueue to buffer │     │ - Parse samples     │
│ - Trigger refill    │     │                     │     │                     │
└─────────────────────┘     └─────────────────────┘     └─────────────────────┘
         │                           ▲                           ▲
         │                           │                           │
         └───── checkAndRefill ──────┴─────── async/await ───────┘
```

### Concurrency Approach

**Preferred**: Use Swift Concurrency (`async/await`, `AsyncStream`) over Combine.

| Use Case | Approach |
|----------|----------|
| Background fetch/decode | `Task { }` with async functions |
| Frame stream from decoder | `AsyncStream<CVPixelBuffer>` |
| Cancellation | `Task.cancel()` / `Task.isCancelled` |
| Actor isolation | `actor FrameBuffer` for thread-safe buffer |

**Why not Combine**:
- Swift Concurrency is more modern and integrated with the language
- Simpler mental model for async operations
- Better cancellation support
- No need for `AnyCancellable` management

#### AsyncStream for Decoded Frames

```swift
class VideoDecoder {
    /// Stream of decoded frames
    func decodeStream(samples: AsyncStream<Sample>) -> AsyncStream<DecodedFrame> {
        AsyncStream { continuation in
            Task {
                for await sample in samples {
                    if let pixelBuffer = try? await decode(sample) {
                        continuation.yield(DecodedFrame(
                            pixelBuffer: pixelBuffer,
                            timestamp: sample.presentationTime
                        ))
                    }
                }
                continuation.finish()
            }
        }
    }
}
```

#### Actor for Thread-Safe Buffer

```swift
actor FrameBuffer {
    private var frames: [DecodedFrame] = []

    func enqueue(_ frame: DecodedFrame) {
        frames.append(frame)
        frames.sort { $0.timestamp < $1.timestamp }
    }

    func dequeue(for time: CMTime) -> CVPixelBuffer? {
        guard let index = frames.firstIndex(where: { $0.timestamp >= time }) else {
            return nil
        }
        let frame = frames.remove(at: index)
        // Remove any frames older than current
        frames.removeAll { $0.timestamp < time }
        return frame.pixelBuffer
    }

    func bufferedDuration(from time: CMTime) -> Double {
        guard let last = frames.last else { return 0 }
        return (last.timestamp - time).seconds
    }
}
```

#### TaskGroup for Parallel Operations (if needed)

```swift
// Example: Prefetch multiple samples in parallel
func prefetchSamples(indices: [Int]) async -> [Sample] {
    await withTaskGroup(of: Sample?.self) { group in
        for index in indices {
            group.addTask {
                try? await self.demuxer.readSample(at: index)
            }
        }
        var samples: [Sample] = []
        for await sample in group {
            if let sample = sample {
                samples.append(sample)
            }
        }
        return samples.sorted { $0.index < $1.index }
    }
}
```

### Memory Considerations

- Each decoded frame (CVPixelBuffer) uses ~width × height × 4 bytes (BGRA) or ~width × height × 1.5 bytes (YUV420)
- For 1080p video: ~8 MB per frame (BGRA) or ~3 MB per frame (YUV420)
- 3 seconds at 30fps = 90 frames = ~270 MB (YUV420) to ~720 MB (BGRA)
- For demo purposes, this is acceptable; production would need frame recycling

### Comparison with Media3

| Aspect | Media3 | Our Player |
|--------|--------|------------|
| Time thresholds | 3 (min, max, playback) | 2 (target, low) |
| Byte thresholds | Yes (32MB video) | No |
| Adaptive | Yes (playback speed) | No |
| Back buffer | Configurable | No |
| Streaming vs Local | Different defaults | Local only |

---

## File Structure

```
Mp4PlayerDemo/
├── Mp4PlayerDemoApp.swift
├── ContentView.swift
├── ByteRange/
│   └── ByteRangeReader.swift        # File byte range reading
├── Demuxer/
│   ├── MP4Demuxer.swift             # Main demuxer orchestration
│   ├── MP4BoxParser.swift           # Box parsing logic
│   ├── MP4SampleTableBuilder.swift  # Sample table construction
│   └── MP4Types.swift               # Data structures
├── Decoder/
│   └── VideoDecoder.swift           # VideoToolbox wrapper
├── Buffer/
│   ├── FrameBuffer.swift            # Decoded frame storage
│   └── BufferManager.swift          # Buffer threshold logic
├── Renderer/
│   ├── MetalRenderer.swift          # Metal rendering
│   └── Shaders.metal                # YUV→RGB conversion shader
├── Player/
│   ├── VideoPlayerEngine.swift      # Playback coordination
│   └── VideoPlayerView.swift        # SwiftUI view
└── demo.mp4                         # Test video
```

---

## Implementation Phases

### Phase 1: Byte Range Reader + Box Parser
- Implement `FileByteRangeReader` for reading byte ranges from file
- Implement `MP4BoxParser` to read box headers
- Parse top-level boxes (ftyp, moov, mdat) from demo.mp4
- Verify correct box sizes and offsets

### Phase 2: Sample Table Construction
- Parse stbl container and child boxes
- Implement sample table construction algorithm
- Extract video track info (codec config, dimensions)
- Verify sample count, offsets, and sizes

### Phase 3: Video Decoding
- Create `CMVideoFormatDescription` from codec config
- Set up `VTDecompressionSession`
- Decode first keyframe to verify setup
- Decode sequence of frames

### Phase 4: Metal Rendering
- Set up Metal device and texture cache
- Implement CVPixelBuffer → MTLTexture conversion
- Create render pipeline with YUV→RGB shader
- Display single decoded frame

### Phase 5: Buffer Management
- Implement `FrameBuffer` for decoded frame storage
- Implement `BufferManager` with dual-threshold logic
- Coordinate fetch/decode on background thread
- Test buffer fill and drain behavior

### Phase 6: Playback Loop
- Implement `CADisplayLink` timing loop
- Integrate buffer management with playback
- Handle frame timing based on presentation timestamps
- Play video from start to end

---

## Testing Strategy

### Build Verification

**IMPORTANT**: Run a build after each implementation phase to verify the project compiles successfully before moving on.

```bash
# From project root
xcodebuild -project Mp4PlayerDemo/Mp4PlayerDemo.xcodeproj -scheme Mp4PlayerDemo -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Or in Xcode: `Cmd+B` to build.

**Build must pass before**:
- Committing code
- Moving to next implementation phase
- Considering a phase complete

### Test File
- **File**: `demo.mp4`
- **Location**: `Mp4PlayerDemo/Mp4PlayerDemo/demo.mp4`

### Verification Steps

1. **Box Parsing**
   - Print box hierarchy of demo.mp4
   - Verify ftyp, moov, mdat boxes found
   - Verify nested box structure matches expected MP4 format

2. **Sample Table**
   - Print sample count, first/last sample offset/size
   - Verify keyframe indices from stss

3. **Decoding**
   - Decode and display first keyframe as still image
   - Verify dimensions match track info

4. **Playback**
   - Play demo.mp4 from start to end
   - Visually verify smooth playback
   - Check frame timing matches expected duration

---

## Reference Documentation

- `Mp4_media3_walkthrough.md` - Detailed MP4 demuxing algorithm reference
- `media/` folder - Media3/ExoPlayer source code for box parsing patterns

### Key Reference Files in media/
- `Mp4Box.java` - Box type constants and header sizes
- `BoxParser.java` - Sample table construction algorithm
- `ParsableByteArray.java` - Byte reading utilities pattern

---

## Technical Notes

### MP4 Box Header Format
```
Standard:  [4 bytes: size][4 bytes: type][payload...]
Extended:  [4 bytes: 1][4 bytes: type][8 bytes: size][payload...]
To-EOF:    [4 bytes: 0][4 bytes: type][payload to end of file]
```

### Full Box Format (version + flags)
```
[4 bytes: size][4 bytes: type][1 byte: version][3 bytes: flags][payload...]
```

### Sample Table Combination
```
offsets[i] = chunk_offset[chunk] + sum(sizes[0..i within chunk])
timestamps[i] = sum(stts durations) + ctts offset
flags[i] = KEY_FRAME if i in stss, else 0
```

---

## Revision History

| Date | Version | Changes |
|------|---------|---------|
| 2026-01-21 | 0.1 | Initial draft |
| 2026-01-21 | 0.2 | Simplified to play-only, added byte range pattern, custom parsing |
| 2026-01-21 | 0.3 | Added buffer management section with dual-threshold strategy |
| 2026-01-21 | 0.4 | Added Swift Concurrency preference (async/await, AsyncStream over Combine), build verification requirement |

