# VAPlayerDemo

**What happens between an MP4 file and pixels on screen?**

A learning project that builds the video playback pipeline from scratch in Swift — no AVPlayer, no AVFoundation playback APIs.

> **Note:** This is not production-ready code. It is an educational project for anyone interested in understanding video encoding, decoding, and playback on Apple platforms.

## Screenshots

The app has two tabs: **Debug** for inspecting each pipeline stage, and **Player** for full playback.

### Debug Tab

Inspect each stage of the pipeline independently:

| MP4 Box Parsing | Demuxer (Sample Table) | Frame Decoding |
|:---:|:---:|:---:|
| ![Box Parser](screenshots/debug_parser.png) | ![Demuxer](screenshots/debug_demux.png) | ![Decoder](screenshots/debug_decode.png) |
| Visualizes the ISO BMFF box hierarchy | Shows extracted sample table with PTS, DTS, offsets | Decodes and displays individual frames |

| Metal Rendering | Buffer Manager |
|:---:|:---:|
| ![Metal](screenshots/debug_metal.png) | ![Buffer](screenshots/debug_buffer.png) |
| Tests YUV→RGB shader on decoded frames | Tests dual-threshold buffer fill and drain |

### Player Tab

Full end-to-end playback with all stages working together:

| Playback |
|:---:|
| ![Player](screenshots/player.png) |
| Complete pipeline: demux → decode → buffer → render |

> *Screenshots to be added — place images in the `screenshots/` folder.*

## Why

AVPlayer does a great job, but it handles everything for you. If you want to go deeper — understand how an MP4 file is structured, how frames are demuxed and decoded, how YUV pixel data becomes RGB on screen — this project walks through every step of that process with working code you can read, run, and modify.

## How It Works

The pipeline has 6 stages. An MP4 file flows through each one, from raw bytes to rendered pixels:

```
┌─────────────┐    ┌─────────────┐    ┌──────────────┐
│  MP4 File   │───>│  Box Parser │───>│   Demuxer    │
│  (bytes)    │    │  (ISO BMFF) │    │ (sample table)│
└─────────────┘    └─────────────┘    └──────┬───────┘
                                             │
                                             v
┌─────────────┐    ┌─────────────┐    ┌──────────────┐
│   Screen    │<───│   Metal     │<───│   Decoder    │
│  (pixels)   │    │  (YUV→RGB)  │    │ (VideoToolbox)│
└─────────────┘    └─────────────┘    └──────────────┘
```

### Stage 1: Byte-Level File Access

**`ByteRangeReader.swift`**

Reads raw bytes from the MP4 file at specific offsets and lengths. This is a protocol-based abstraction — the same interface could back an HTTP byte-range reader for streaming.

### Stage 2: MP4 Box Parsing

**`MP4BoxParser.swift`** · **`MP4Types.swift`**

An MP4 file is a tree of "boxes" (also called atoms) defined by the ISO 14496-12 standard. The parser reads the box hierarchy:

```
ftyp        — file type / brand
moov        — movie metadata (the important one)
├── mvhd    — movie header (timescale, duration)
└── trak    — track (one per video/audio stream)
    ├── tkhd — track header
    └── mdia — media info
        └── minf
            └── stbl — sample table (where frame data lives)
                ├── stsd — codec config (avcC / hvcC)
                ├── stts — decode timestamps
                ├── ctts — composition time offsets (B-frames)
                ├── stsc — sample-to-chunk mapping
                ├── stsz — sample sizes
                ├── stco — chunk offsets
                └── stss — keyframe indices
mdat        — raw compressed frame data
```

### Stage 3: Demuxing

**`MP4Demuxer.swift`** · **`MP4SampleTableBuilder.swift`**

The demuxer combines all the sample table boxes (stts, stsc, stsz, stco, ctts, stss) into a unified sample table. Each entry tells you: where a frame lives in the file, how big it is, when to decode it (DTS), when to display it (PTS), and whether it's a keyframe.

This is the translation layer between "MP4 container format" and "here are your compressed video frames in order."

### Stage 4: Hardware Decoding

**`VideoDecoder.swift`**

Feeds compressed H.264/HEVC samples into Apple's VideoToolbox hardware decoder. The decoder:

1. Parses the codec configuration record (avcC for H.264, hvcC for HEVC) to extract SPS/PPS/VPS parameter sets
2. Creates a `VTDecompressionSession` with the format description
3. Decodes each sample into a `CVPixelBuffer` (NV12 / YCbCr 4:2:0 format)
4. Handles B-frame reordering (decode order != display order)

VideoToolbox is the one Apple API we can't avoid — it provides access to the hardware video decoder.

### Stage 5: Frame Buffering

**`BufferManager.swift`** · **`FrameBuffer.swift`**

A dual-threshold buffer sits between decoding and rendering:

- **Target buffer**: 3 seconds of decoded frames ahead of playback
- **Low threshold**: when buffer drops below 1 second, trigger a background refill

The buffer is actor-based for thread safety. Frames are sorted by presentation timestamp and dequeued at playback time.

### Stage 6: Metal Rendering

**`MetalRenderer.swift`** · **`Shaders.metal`**

The decoded pixel buffers are in YCbCr (NV12) format — not RGB. A Metal fragment shader converts YCbCr to RGB using the BT.709 color matrix (the HD video standard), handling the video range [16–235] to full range [0–255] conversion.

### Playback Engine

**`VideoPlayerEngine.swift`** · **`VideoPlayerView.swift`**

Ties everything together. A `CADisplayLink` fires at the screen refresh rate (~60fps), advancing a clock. Each tick, the engine dequeues the frame whose PTS matches the current time and hands it to Metal for display.

## Design Decisions

**Why not AVAssetReader?** — `AVAssetReader` requires a local file URL. This project uses a `ByteRangeReader` protocol that reads bytes at arbitrary offsets, which maps directly to how HTTP byte-range requests work. The same demuxer code could be backed by a network reader for streaming, without changing any of the parsing logic.

**Zero-copy decoded frames** — VideoToolbox decodes directly into `CVPixelBuffer` backed by IOSurface memory. These buffers are passed through the buffer queue and into Metal without ever copying pixel data. The Metal texture cache (`CVMetalTextureCache`) wraps the same underlying memory as a Metal texture, so the GPU reads directly from the decoder's output. No CPU-side pixel copying at any stage.

## Getting Started

1. Clone the repo
2. Open `Mp4PlayerDemo/Mp4PlayerDemo.xcodeproj` in Xcode
3. Add an MP4 file to the project bundle (drag into Xcode, check "Copy items if needed")
4. Update the filename in `ContentView.swift`:
   ```swift
   private let videoFileName = "your_video"
   private let videoFileExtension = "mp4"
   ```
5. Build and run on a physical device or simulator

The app has two tabs:
- **Debug** — test each pipeline stage independently (parse boxes, demux, decode, Metal render, buffer)
- **Player** — full end-to-end playback

## Current Limitations and Future Work

**Video only** — There is no audio decoding or playback. Adding audio support along with an A/V synchronization mechanism (using audio clock as the timing master) is a future goal.

**Metal rendering efficiency** — The current approach renders each frame through a custom Metal pipeline with a YUV→RGB shader. A more efficient path would be to use `AVSampleBufferDisplayLayer` with `AVQueuedSampleBufferRendering` / `AVSampleBufferRenderSynchronizer`, which handles display timing, frame queuing, and YUV rendering natively at the system level.

**No seeking** — Keyframe-based seeking infrastructure exists in the buffer manager but is not wired up to the UI.

**Non-fragmented MP4 only** — The parser handles standard MP4 files (moov + mdat). Fragmented MP4 (moof/traf used in DASH/HLS) is not supported.

## License

MIT
