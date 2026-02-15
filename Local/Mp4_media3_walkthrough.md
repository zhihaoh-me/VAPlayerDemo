# Media3 MP4 Demuxing: Complete Explanation

## Overview

Media3 (ExoPlayer) uses a two-phase approach to MP4 demuxing:
1. **Initialization Phase**: Parse MP4 metadata boxes to build sample tables
2. **Playback Phase**: Use sample tables to extract frames on-demand from mdat

## Part 1: Initialization - Building the Sample Tables

### MP4 Container Structure
```
[ftyp] → File type identification
[moov] → Movie metadata (contains ALL the mapping information)
  └─[trak] → Track (video/audio)
      └─[mdia]
          └─[minf]
              └─[stbl] → Sample Table (THE KEY BOX)
                  ├─[stco/co64] → Chunk offsets
                  ├─[stsc] → Sample-to-chunk mapping
                  ├─[stsz] → Sample sizes
                  ├─[stts] → Decode timestamps
                  ├─[stss] → Sync samples (I-frames)
                  └─[ctts] → Composition offsets
[mdat] → Raw media data (frames are stored here)
```

### Key Files
- **Mp4Extractor.java**: Main demuxer state machine (lines 199-1268)
- **BoxParser.java**: Parses stbl box and builds sample tables (lines 429-863)
- **TrackSampleTable.java**: Data structure holding per-frame metadata

### Sample Table Construction Algorithm

**Location**: `BoxParser.parseStbl()` (BoxParser.java:552-627)

The algorithm combines multiple metadata boxes to build a complete frame index:

```java
// Result: Arrays indexed by sample number
long[] offsets;      // Absolute byte position of each frame in mdat
int[] sizes;         // Size of each frame in bytes
long[] timestampsUs; // Presentation timestamp of each frame
int[] flags;         // KEY_FRAME flag for I-frames
```

**Step-by-step process:**

1. **Read chunk offsets** (stco/co64):
   - Provides file positions where chunks begin
   - Each chunk contains multiple samples/frames
   - Example: `chunkOffsets = [1000, 5000, 12000, ...]`

2. **Read sample-to-chunk mapping** (stsc):
   - Specifies how many samples are in each chunk
   - Example: `chunk 1-10: 5 samples/chunk, chunk 11-20: 3 samples/chunk`

3. **Create ChunkIterator** (BoxParser.java:2619-2666):
   - Combines stco and stsc data
   - Iterates: `{chunkOffset: 1000, numSamples: 5} → {chunkOffset: 5000, numSamples: 5} → ...`

4. **Read sample sizes** (stsz):
   - Size in bytes of each individual frame
   - Example: `sizes = [25000, 5000, 4000, 6000, 4500, ...]` (I-frame is larger)

5. **Calculate absolute offsets**:
   ```java
   for (int i = 0; i < sampleCount; i++) {
       // Get current chunk position
       if (remainingSamplesInChunk == 0) {
           offset = chunkIterator.offset;  // From stco
           remainingSamplesInChunk = chunkIterator.numSamples; // From stsc
       }

       offsets[i] = offset;  // This frame starts at this byte position
       sizes[i] = sampleSizeBox.readNextSampleSize(); // From stsz

       offset += sizes[i];  // Next frame starts after this one
       remainingSamplesInChunk--;
   }
   ```

6. **Calculate timestamps** (stts + ctts):
   - stts provides decode durations
   - ctts provides composition offsets (for B-frames)
   - Accumulated to produce presentation timestamps

7. **Mark keyframes** (stss):
   ```java
   // Read sync sample table
   if (stss != null) {
       stss.setPosition(FULL_HEADER_SIZE);
       int syncSampleCount = stss.readUnsignedIntToInt();
       nextKeyframeIndex = stss.readUnsignedIntToInt() - 1; // Sample indices (1-based)
   }

   // Mark each sample
   for (int i = 0; i < sampleCount; i++) {
       if (stss == null) {
           flags[i] = KEY_FRAME;  // All frames are keyframes if no stss
       } else if (i == nextKeyframeIndex) {
           flags[i] = KEY_FRAME;  // This is an I-frame
           nextKeyframeIndex = stss.readUnsignedIntToInt() - 1;
       } else {
           flags[i] = 0;  // This is a P-frame or B-frame
       }
   }
   ```

### Example Sample Table Result

After parsing, we have a complete index:

```
Sample#  |  Offset   |  Size   | Timestamp | Flags
---------|-----------|---------|-----------|----------
   0     |   1000    |  25000  |   0 ms    | KEY_FRAME  ← I-frame
   1     |  26000    |   5000  |  33 ms    | 0          ← P-frame
   2     |  31000    |   4000  |  66 ms    | 0          ← P-frame
   3     |  35000    |   6000  | 100 ms    | 0          ← P-frame
   4     |  41000    |  24000  | 133 ms    | KEY_FRAME  ← I-frame
   5     |  65000    |   5500  | 166 ms    | 0          ← P-frame
   ...
```

**Critical insight**: The mdat box is NEVER parsed during initialization. We only record where it is in the file.

---

## Part 2: Playback - Extracting Frames from mdat

### During Playback Overview

**Location**: `Mp4Extractor.readSample()` (Mp4Extractor.java:873-1010)

When the decoder needs the next frame, ExoPlayer:
1. Determines which track to read from
2. Looks up the frame's offset and size in the sample table
3. Seeks to that position in the file (inside mdat)
4. Reads the exact number of bytes
5. Outputs the frame data with metadata (timestamp, flags)

### Detailed Playback Flow

#### Step 1: Track Selection (lines 876-882)

```java
private int readSample(ExtractorInput input) throws IOException {
    // Find track with earliest next sample
    long nextDataPosition = Long.MAX_VALUE;
    @Nullable Mp4Track track = null;

    for (int i = 0; i < tracks.length; i++) {
        Mp4Track currentTrack = tracks[i];
        int sampleIndex = currentTrack.sampleIndex;

        if (sampleIndex == currentTrack.sampleTable.sampleCount) {
            continue; // Track finished
        }

        long sampleOffset = currentTrack.sampleTable.offsets[sampleIndex];
        if (sampleOffset < nextDataPosition) {
            nextDataPosition = sampleOffset;
            track = currentTrack;
        }
    }
}
```

**Purpose**: In MP4 files with multiple tracks (video + audio), samples are interleaved in the mdat box. This selects the track whose next sample appears first in the file to minimize seeking.

#### Step 2: Get Frame Location (lines 884-885)

```java
int sampleIndex = track.sampleIndex;
long position = track.sampleTable.offsets[sampleIndex] + sampleOffsetForAuxiliaryTracks;
int sampleSize = track.sampleTable.sizes[sampleIndex];
```

**Example**:
- If decoder needs sample #2 from video track:
  - `position = offsets[2] = 31000` (absolute byte position in file)
  - `sampleSize = sizes[2] = 4000` (frame is 4000 bytes)

#### Step 3: Seek to Frame Position (lines 887-897)

```java
long skipAmount = position - input.getPosition();
if (skipAmount < 0 || skipAmount >= MAXIMUM_READ_AHEAD_BYTES_STREAM) {
    // Large seek needed
    return Extractor.RESULT_SEEK;
} else {
    // Small skip forward
    if (track.track.sampleTransformation == Track.TRANSFORMATION_CEA608_CDAT) {
        skipAmount -= Atom.HEADER_SIZE;
    }
    input.skipFully((int) skipAmount);
}
```

**Purpose**: Position the file pointer at the exact start of the frame data within mdat.

- If current position is close (< MAXIMUM_READ_AHEAD_BYTES_STREAM), skip forward
- If far away, return RESULT_SEEK to trigger efficient seeking

#### Step 4: Read Frame Data (lines 899-985)

```java
// Handle encryption if present
if (track.sampleTable.cryptoData != null) {
    // Read encryption signal byte
    input.readFully(scratch.getData(), 0, 1);
    sampleBytesWritten++;

    byte signalByte = scratch.getData()[0];
    boolean subsampleEncryption = (signalByte & 0x80) != 0;
    sampleSize--;
}

// Configure encryption if needed
if (track.sampleTable.cryptoData != null) {
    TrackEncryptionBox encryptionBox = track.sampleTable.cryptoData.get(sampleIndex);
    trackOutput.sampleData(encryptionInputBuffer, encryptionBox.initializationVector.length);
}

// Read actual frame data
sampleSize = track.outputSampleEncryptionBox(sampleIndex, sampleSize, scratch);
sampleBytesWritten += trackOutput.sampleData(input, sampleSize, false);

// Handle auxiliary data if present (SEI, CDAT, etc.)
while (sampleBytesWritten < track.sampleTable.sizes[sampleIndex]) {
    int bytesToWrite = trackOutput.sampleData(
        input,
        track.sampleTable.sizes[sampleIndex] - sampleBytesWritten,
        false
    );
    sampleBytesWritten += bytesToWrite;
}
```

**Purpose**: Read the raw frame bytes from mdat and pass to the track output (decoder).

**Key operations**:
- Handle encrypted samples (read encryption metadata)
- Read exactly `sampleSize` bytes from current file position
- Handle auxiliary data (SEI messages, closed captions)
- Write to `TrackOutput` which buffers data for the decoder

#### Step 5: Output Sample Metadata (lines 987-1001)

```java
long timeUs = track.sampleTable.timestampsUs[sampleIndex];
@C.BufferFlags int sampleFlags = track.sampleTable.flags[sampleIndex];
int sampleSize = track.sampleTable.sizes[sampleIndex];

// Output metadata with the sample
trackOutput.sampleMetadata(
    timeUs,           // When to present this frame
    sampleFlags,      // KEY_FRAME if I-frame, 0 if P/B-frame
    sampleSize,       // Total bytes written
    0,                // Offset
    null              // Encryption data
);

// Move to next sample
track.sampleIndex++;
sampleBytesWritten = 0;
sampleCurrentNalBytesRemaining = 0;
```

**Purpose**: Provide decoder with frame metadata:
- **timeUs**: Presentation timestamp (when to display)
- **sampleFlags**: Contains `C.BUFFER_FLAG_KEY_FRAME` if this is an I-frame
  - Decoder uses this to know if frame can be decoded independently
  - Seeking logic uses this to find nearest keyframe
- **sampleSize**: Total frame size for validation

### I-frame vs P-frame Handling

**During Playback**: The treatment is identical - both are just read as byte arrays from mdat. The KEY_FRAME flag is the only difference.

**Why the distinction matters**:

1. **Seeking** (TrackSampleTable.java:83-93):
   ```java
   public int getIndexOfEarlierOrEqualSynchronizationSample(long timeUs) {
       // Binary search to target time
       int startIndex = Util.binarySearchFloor(timestampsUs, timeUs, true, false);

       // Scan backwards to find nearest I-frame
       for (int i = startIndex; i >= 0; i--) {
           if ((flags[i] & C.BUFFER_FLAG_KEY_FRAME) != 0) {
               return i;  // Start decoding from this I-frame
           }
       }
       return C.INDEX_UNSET;
   }
   ```

   When user seeks to 5:30, ExoPlayer:
   - Finds sample at 5:30 (might be P-frame)
   - Scans backwards to find nearest I-frame (maybe at 5:28)
   - Starts reading from that I-frame
   - Decodes and discards frames until reaching 5:30

2. **Adaptive Streaming**: When switching quality levels, decoder needs to start at an I-frame

3. **Error Recovery**: If decoder encounters error, it seeks to next I-frame

### Complete Playback Example

**Scenario**: Decoder requests frames 0-3

```
Initial state:
- File pointer at start of mdat (offset 1000)
- Video track: sampleIndex = 0

Frame 0 (I-frame):
1. readSample() called
2. Track selection: video track
3. Get location: offsets[0] = 1000, sizes[0] = 25000
4. Seek: already at 1000, no seek needed
5. Read: input.read(25000 bytes) → decoder
6. Output metadata: {time: 0ms, flags: KEY_FRAME, size: 25000}
7. sampleIndex++ → 1

Frame 1 (P-frame):
1. readSample() called
2. Track selection: video track (assuming audio not due yet)
3. Get location: offsets[1] = 26000, sizes[1] = 5000
4. Seek: file pointer at 26000, skip 0 bytes
5. Read: input.read(5000 bytes) → decoder
6. Output metadata: {time: 33ms, flags: 0, size: 5000}
7. sampleIndex++ → 2

Frame 2 (P-frame):
1. readSample() called
2. Track selection: video track
3. Get location: offsets[2] = 31000, sizes[2] = 4000
4. Seek: file pointer at 31000, skip 0 bytes
5. Read: input.read(4000 bytes) → decoder
6. Output metadata: {time: 66ms, flags: 0, size: 4000}
7. sampleIndex++ → 3

Frame 3 (P-frame):
1. readSample() called
2. Track selection: video track
3. Get location: offsets[3] = 35000, sizes[3] = 6000
4. Seek: file pointer at 35000, skip 0 bytes
5. Read: input.read(6000 bytes) → decoder
6. Output metadata: {time: 100ms, flags: 0, size: 6000}
7. sampleIndex++ → 4
```

**Key insight**: The mdat box is just a container of concatenated frame data. The actual structure (where each frame starts/ends, which are keyframes) is entirely determined by the sample tables built from moov metadata.

---

## Architecture Summary

### Why This Design?

1. **Memory Efficiency**: Sample tables are small (~24 bytes per sample). For a 2-hour video at 30fps (216,000 frames), that's only ~5MB of metadata vs. GB of video data.

2. **Fast Seeking**: Binary search on sample table (O(log n)) + single file seek vs. scanning through mdat

3. **Progressive Loading**: Can build sample tables from just the moov box at start, begin playback immediately

4. **Interleaved Tracks**: Video and audio samples interleaved in mdat for better disk I/O, sample tables allow correct de-interleaving

### Data Flow Summary

```
Initialization:
MP4 File → Mp4Extractor → BoxParser.parseStbl()
    → TrackSampleTable {offsets[], sizes[], timestamps[], flags[]}

Playback Loop:
Decoder needs frame N
    ↓
Mp4Extractor.readSample()
    ↓
Lookup: offset = offsets[N], size = sizes[N]
    ↓
File seek to offset (within mdat)
    ↓
Read size bytes → TrackOutput → Decoder
    ↓
Output metadata: timestamps[N], flags[N]
```

---

## Critical File References

1. **Mp4Extractor.java:873-1010** - Main playback loop, frame extraction
2. **BoxParser.java:552-627** - Sample table construction algorithm
3. **BoxParser.java:2619-2666** - ChunkIterator combining stco and stsc
4. **TrackSampleTable.java:33-46** - Sample table data structure
5. **TrackSampleTable.java:83-93** - Keyframe seeking logic
6. **Mp4Box.java** - Box type constants (TYPE_stco, TYPE_stss, etc.)

---

## Key Takeaways

1. **mdat is opaque**: Media3 never parses its structure, just seeks to calculated positions
2. **Sample tables are everything**: offsets[], sizes[], timestamps[], flags[] provide complete frame index
3. **I-frames vs P-frames**: Distinguished ONLY by KEY_FRAME flag in flags[] array (from stss box)
4. **Frame location**: Calculated during init by combining stco + stsc + stsz boxes
5. **Playback is simple**: Lookup → Seek → Read → Output metadata
6. **Seeking requires I-frames**: Always scan backwards to nearest keyframe before starting decode
