import Foundation

/// Errors that can occur during sample table parsing
enum SampleTableError: Error {
    case missingRequiredBox(String)
    case invalidBoxFormat(String)
    case noSamples
    case invalidSampleIndex
}

/// Represents the complete sample table for a track
struct SampleTable {
    /// All samples in presentation order
    let samples: [MP4Sample]

    /// Timescale for timestamp conversion
    let timescale: UInt32

    /// Total duration in timescale units
    let duration: UInt64

    /// Debug: raw composition offsets parsed from ctts
    var debugCttsEntries: [(count: UInt32, offset: Int32)] = []

    /// Number of samples
    var count: Int { samples.count }

    /// Get sample at index
    subscript(index: Int) -> MP4Sample? {
        guard index >= 0 && index < samples.count else { return nil }
        return samples[index]
    }

    /// Find keyframe at or before given sample index
    func keyframeBefore(sampleIndex: Int) -> Int? {
        for i in stride(from: min(sampleIndex, samples.count - 1), through: 0, by: -1) {
            if samples[i].flags.isKeyFrame {
                return i
            }
        }
        return nil
    }
}

/// Builds sample table from MP4 box structure
final class MP4SampleTableBuilder {
    private let reader: ByteRangeReader
    private let parser: MP4BoxParser

    init(reader: ByteRangeReader, parser: MP4BoxParser) {
        self.reader = reader
        self.parser = parser
    }

    /// Build sample table from stbl box
    /// - Parameters:
    ///   - stblBox: The stbl container box
    ///   - timescale: Media timescale
    ///   - mediaTimeOffset: Offset from edit list (elst media_time) to subtract from PTS
    func buildSampleTable(from stblBox: MP4Box, timescale: UInt32, mediaTimeOffset: Int64 = 0) throws -> SampleTable {
        // Find required boxes
        guard let stszBox = parser.findBox(type: MP4BoxType.stsz, in: stblBox.children) else {
            throw SampleTableError.missingRequiredBox("stsz")
        }
        guard let stscBox = parser.findBox(type: MP4BoxType.stsc, in: stblBox.children) else {
            throw SampleTableError.missingRequiredBox("stsc")
        }
        guard let sttsBox = parser.findBox(type: MP4BoxType.stts, in: stblBox.children) else {
            throw SampleTableError.missingRequiredBox("stts")
        }

        // Chunk offsets can be in stco (32-bit) or co64 (64-bit)
        let chunkOffsets: [UInt64]
        if let stcoBox = parser.findBox(type: MP4BoxType.stco, in: stblBox.children) {
            chunkOffsets = try parseChunkOffsets32(stcoBox)
        } else if let co64Box = parser.findBox(type: MP4BoxType.co64, in: stblBox.children) {
            chunkOffsets = try parseChunkOffsets64(co64Box)
        } else {
            throw SampleTableError.missingRequiredBox("stco/co64")
        }

        // Optional boxes
        let stssBox = parser.findBox(type: MP4BoxType.stss, in: stblBox.children)
        let cttsBox = parser.findBox(type: MP4BoxType.ctts, in: stblBox.children)

        // Parse each table
        let sampleSizes = try parseSampleSizes(stszBox)
        let sampleToChunk = try parseSampleToChunk(stscBox)
        let timeToSample = try parseTimeToSample(sttsBox)
        let syncSamples = try stssBox.map { try parseSyncSamples($0) } ?? Set<Int>()
        let compositionOffsets = try cttsBox.map { try parseCompositionOffsets($0) } ?? []

        guard !sampleSizes.isEmpty else {
            throw SampleTableError.noSamples
        }

        // Build samples array
        let samples = buildSamples(
            sampleSizes: sampleSizes,
            chunkOffsets: chunkOffsets,
            sampleToChunk: sampleToChunk,
            timeToSample: timeToSample,
            compositionOffsets: compositionOffsets,
            syncSamples: syncSamples,
            mediaTimeOffset: mediaTimeOffset
        )

        // Calculate total duration
        let totalDuration = samples.last.map { UInt64($0.decodeTime) + UInt64($0.duration) } ?? 0

        var table = SampleTable(
            samples: samples,
            timescale: timescale,
            duration: totalDuration
        )
        // Store debug ctts entries
        table.debugCttsEntries = compositionOffsets.map { ($0.sampleCount, $0.offset) }
        return table
    }

    // MARK: - Box Parsing

    /// Parse stsz (sample sizes) box
    private func parseSampleSizes(_ box: MP4Box) throws -> [UInt32] {
        let data = try reader.read(offset: box.payloadOffset, length: Int(box.payloadSize))

        // Skip version (1) + flags (3)
        var offset = 4

        // Default sample size (0 means each sample has its own size)
        let defaultSize = data.readUInt32(at: offset)
        offset += 4

        // Sample count
        let sampleCount = data.readUInt32(at: offset)
        offset += 4

        var sizes: [UInt32] = []
        sizes.reserveCapacity(Int(sampleCount))

        if defaultSize != 0 {
            // All samples have the same size
            sizes = Array(repeating: defaultSize, count: Int(sampleCount))
        } else {
            // Read individual sizes
            for _ in 0..<sampleCount {
                sizes.append(data.readUInt32(at: offset))
                offset += 4
            }
        }

        return sizes
    }

    /// Parse stco (32-bit chunk offsets) box
    private func parseChunkOffsets32(_ box: MP4Box) throws -> [UInt64] {
        let data = try reader.read(offset: box.payloadOffset, length: Int(box.payloadSize))

        // Skip version (1) + flags (3)
        var offset = 4

        let entryCount = data.readUInt32(at: offset)
        offset += 4

        var offsets: [UInt64] = []
        offsets.reserveCapacity(Int(entryCount))

        for _ in 0..<entryCount {
            offsets.append(UInt64(data.readUInt32(at: offset)))
            offset += 4
        }

        return offsets
    }

    /// Parse co64 (64-bit chunk offsets) box
    private func parseChunkOffsets64(_ box: MP4Box) throws -> [UInt64] {
        let data = try reader.read(offset: box.payloadOffset, length: Int(box.payloadSize))

        // Skip version (1) + flags (3)
        var offset = 4

        let entryCount = data.readUInt32(at: offset)
        offset += 4

        var offsets: [UInt64] = []
        offsets.reserveCapacity(Int(entryCount))

        for _ in 0..<entryCount {
            offsets.append(data.readUInt64(at: offset))
            offset += 8
        }

        return offsets
    }

    /// Sample-to-chunk entry
    struct SampleToChunkEntry {
        let firstChunk: UInt32      // 1-based
        let samplesPerChunk: UInt32
        let sampleDescriptionIndex: UInt32
    }

    /// Parse stsc (sample-to-chunk) box
    private func parseSampleToChunk(_ box: MP4Box) throws -> [SampleToChunkEntry] {
        let data = try reader.read(offset: box.payloadOffset, length: Int(box.payloadSize))

        // Skip version (1) + flags (3)
        var offset = 4

        let entryCount = data.readUInt32(at: offset)
        offset += 4

        var entries: [SampleToChunkEntry] = []
        entries.reserveCapacity(Int(entryCount))

        for _ in 0..<entryCount {
            let firstChunk = data.readUInt32(at: offset)
            let samplesPerChunk = data.readUInt32(at: offset + 4)
            let sampleDescIndex = data.readUInt32(at: offset + 8)

            entries.append(SampleToChunkEntry(
                firstChunk: firstChunk,
                samplesPerChunk: samplesPerChunk,
                sampleDescriptionIndex: sampleDescIndex
            ))
            offset += 12
        }

        return entries
    }

    /// Time-to-sample entry
    struct TimeToSampleEntry {
        let sampleCount: UInt32
        let sampleDelta: UInt32
    }

    /// Parse stts (time-to-sample) box
    private func parseTimeToSample(_ box: MP4Box) throws -> [TimeToSampleEntry] {
        let data = try reader.read(offset: box.payloadOffset, length: Int(box.payloadSize))

        // Skip version (1) + flags (3)
        var offset = 4

        let entryCount = data.readUInt32(at: offset)
        offset += 4

        var entries: [TimeToSampleEntry] = []
        entries.reserveCapacity(Int(entryCount))

        for _ in 0..<entryCount {
            let sampleCount = data.readUInt32(at: offset)
            let sampleDelta = data.readUInt32(at: offset + 4)

            entries.append(TimeToSampleEntry(
                sampleCount: sampleCount,
                sampleDelta: sampleDelta
            ))
            offset += 8
        }

        return entries
    }

    /// Parse stss (sync samples / keyframes) box
    private func parseSyncSamples(_ box: MP4Box) throws -> Set<Int> {
        let data = try reader.read(offset: box.payloadOffset, length: Int(box.payloadSize))

        // Skip version (1) + flags (3)
        var offset = 4

        let entryCount = data.readUInt32(at: offset)
        offset += 4

        var syncSamples = Set<Int>()

        for _ in 0..<entryCount {
            // Sample numbers are 1-based in MP4, convert to 0-based
            let sampleNumber = Int(data.readUInt32(at: offset)) - 1
            syncSamples.insert(sampleNumber)
            offset += 4
        }

        return syncSamples
    }

    /// Composition offset entry
    struct CompositionOffsetEntry {
        let sampleCount: UInt32
        let offset: Int32
    }

    /// Parse ctts (composition time offsets) box
    private func parseCompositionOffsets(_ box: MP4Box) throws -> [CompositionOffsetEntry] {
        let data = try reader.read(offset: box.payloadOffset, length: Int(box.payloadSize))

        // Version determines if offsets are signed
        let version = data[0]
        var offset = 4  // Skip version (1) + flags (3)

        let entryCount = data.readUInt32(at: offset)
        offset += 4

        var entries: [CompositionOffsetEntry] = []
        entries.reserveCapacity(Int(entryCount))

        for _ in 0..<entryCount {
            let sampleCount = data.readUInt32(at: offset)
            let compositionOffset: Int32

            if version == 0 {
                // Unsigned offset
                compositionOffset = Int32(bitPattern: data.readUInt32(at: offset + 4))
            } else {
                // Signed offset (version 1)
                compositionOffset = Int32(bitPattern: data.readUInt32(at: offset + 4))
            }

            entries.append(CompositionOffsetEntry(
                sampleCount: sampleCount,
                offset: compositionOffset
            ))
            offset += 8
        }

        return entries
    }

    // MARK: - Sample Building

    /// Build complete samples array from parsed tables
    /// Following media3's BoxParser.parseStbl approach exactly
    private func buildSamples(
        sampleSizes: [UInt32],
        chunkOffsets: [UInt64],
        sampleToChunk: [SampleToChunkEntry],
        timeToSample: [TimeToSampleEntry],
        compositionOffsets: [CompositionOffsetEntry],
        syncSamples: Set<Int>,
        mediaTimeOffset: Int64
    ) -> [MP4Sample] {
        let sampleCount = sampleSizes.count
        var samples: [MP4Sample] = []
        samples.reserveCapacity(sampleCount)

        // Following media3's approach: iterate through samples while tracking state
        // for chunks, timestamps, and composition offsets

        // Chunk iterator state
        var chunkIndex = 0
        var remainingSamplesInChunk = 0
        var currentOffset: UInt64 = 0

        // Prepare stsc iterator
        var stscIndex = 0
        var nextSamplesPerChunkChangeChunk = sampleToChunk.isEmpty ? Int.max : Int(sampleToChunk[0].firstChunk)
        var currentSamplesPerChunk = 0

        // Timestamp state (stts)
        var sttsIndex = 0
        var remainingSamplesAtTimestampDelta = timeToSample.isEmpty ? 0 : Int(timeToSample[0].sampleCount)
        var timestampDeltaInTimeUnits = timeToSample.isEmpty ? 0 : Int(timeToSample[0].sampleDelta)
        var timestampTimeUnits: Int64 = 0

        // Composition offset state (ctts) - following media3 exactly
        var cttsIndex = 0
        var remainingSamplesAtTimestampOffset = 0
        var remainingTimestampOffsetChanges = compositionOffsets.count
        var timestampOffset: Int32 = 0

        for i in 0..<sampleCount {
            // Advance to next chunk if necessary (media3 lines 584-589)
            while remainingSamplesInChunk == 0 && chunkIndex < chunkOffsets.count {
                currentOffset = chunkOffsets[chunkIndex]

                // Check if samples per chunk changes at this chunk
                if chunkIndex + 1 == nextSamplesPerChunkChangeChunk {
                    currentSamplesPerChunk = Int(sampleToChunk[stscIndex].samplesPerChunk)
                    stscIndex += 1
                    if stscIndex < sampleToChunk.count {
                        nextSamplesPerChunkChangeChunk = Int(sampleToChunk[stscIndex].firstChunk)
                    } else {
                        nextSamplesPerChunkChangeChunk = Int.max
                    }
                }

                remainingSamplesInChunk = currentSamplesPerChunk
                chunkIndex += 1
            }

            // Add on the timestamp offset if ctts is present (media3 lines 602-615)
            while remainingSamplesAtTimestampOffset == 0 && remainingTimestampOffsetChanges > 0 {
                let entry = compositionOffsets[cttsIndex]
                remainingSamplesAtTimestampOffset = Int(entry.sampleCount)
                timestampOffset = entry.offset
                cttsIndex += 1
                remainingTimestampOffsetChanges -= 1
            }
            remainingSamplesAtTimestampOffset -= 1

            // Get current sample size
            let currentSampleSize = sampleSizes[i]

            // Build sample (media3 lines 623-633)
            // timestamps[i] = timestampTimeUnits + timestampOffset (media3 line 626)
            let rawTimestamp = timestampTimeUnits + Int64(timestampOffset)
            // Apply edit list offset: timestamp - editStartTime (media3 lines 816-818)
            let presentationTime = rawTimestamp - mediaTimeOffset

            let flags: SampleFlags = syncSamples.isEmpty || syncSamples.contains(i)
                ? .keyFrame
                : []

            samples.append(MP4Sample(
                index: i,
                offset: currentOffset,
                size: currentSampleSize,
                decodeTime: timestampTimeUnits,
                presentationTime: presentationTime,
                duration: UInt32(timestampDeltaInTimeUnits),
                flags: flags
            ))

            // Add on the duration of this sample (media3 lines 642-655)
            timestampTimeUnits += Int64(timestampDeltaInTimeUnits)
            remainingSamplesAtTimestampDelta -= 1
            if remainingSamplesAtTimestampDelta == 0 && sttsIndex + 1 < timeToSample.count {
                sttsIndex += 1
                remainingSamplesAtTimestampDelta = Int(timeToSample[sttsIndex].sampleCount)
                timestampDeltaInTimeUnits = Int(timeToSample[sttsIndex].sampleDelta)
            }

            // Move offset past current sample (media3 line 657)
            currentOffset += UInt64(currentSampleSize)
            remainingSamplesInChunk -= 1
        }

        return samples
    }

}
