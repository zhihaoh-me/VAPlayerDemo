import Foundation

/// Errors that can occur during demuxing
enum DemuxerError: Error {
    case moovNotFound
    case videoTrackNotFound
    case invalidCodecConfig
    case sampleOutOfRange
    case parseError(String)
}

/// Main MP4 demuxer that coordinates parsing and sample extraction
final class MP4Demuxer {
    private let reader: ByteRangeReader
    private let parser: MP4BoxParser
    private let sampleTableBuilder: MP4SampleTableBuilder

    /// Parsed top-level boxes
    private(set) var boxes: [MP4Box] = []

    /// Video track information
    private(set) var videoTrackInfo: VideoTrackInfo?

    /// Sample table for video track
    private(set) var sampleTable: SampleTable?

    /// Media time offset from edit list
    private(set) var mediaTimeOffset: Int64 = 0

    /// File size
    var fileSize: UInt64 { reader.length }

    /// Number of samples
    var sampleCount: Int { sampleTable?.count ?? 0 }

    init(reader: ByteRangeReader) {
        self.reader = reader
        self.parser = MP4BoxParser(reader: reader)
        self.sampleTableBuilder = MP4SampleTableBuilder(reader: reader, parser: parser)
    }

    /// Parse the MP4 file structure and build sample tables
    func parse() throws {
        // Parse full box structure
        boxes = try parser.parseFullStructure()

        // Find moov box
        guard let moovBox = parser.findBox(type: MP4BoxType.moov, in: boxes) else {
            throw DemuxerError.moovNotFound
        }

        // Find video track
        let tracks = parser.findAllBoxes(type: MP4BoxType.trak, in: moovBox.children)

        var lastError: Error?
        for trak in tracks {
            do {
                if let trackInfo = try parseVideoTrack(trak) {
                    videoTrackInfo = trackInfo

                    // Parse edit list for media time offset
                    mediaTimeOffset = parseEditList(in: trak)

                    // Find stbl box for sample table
                    if let stblBox = findStblBox(in: trak) {
                        sampleTable = try sampleTableBuilder.buildSampleTable(
                            from: stblBox,
                            timescale: trackInfo.timescale,
                            mediaTimeOffset: mediaTimeOffset
                        )
                    }
                    break  // Use first video track
                }
            } catch {
                lastError = error
            }
        }

        guard videoTrackInfo != nil else {
            if let error = lastError {
                throw DemuxerError.parseError("Video track parsing failed: \(error)")
            }
            throw DemuxerError.videoTrackNotFound
        }
    }

    /// Read sample data at given index
    func readSample(at index: Int) throws -> Data {
        guard let sample = sampleTable?[index] else {
            throw DemuxerError.sampleOutOfRange
        }

        return try reader.read(offset: sample.offset, length: Int(sample.size))
    }

    /// Get sample info at given index
    func getSample(at index: Int) -> MP4Sample? {
        return sampleTable?[index]
    }

    // MARK: - Private Methods

    /// Find stbl box within a track
    private func findStblBox(in trak: MP4Box) -> MP4Box? {
        // Path: trak -> mdia -> minf -> stbl
        guard let mdia = parser.findBox(type: MP4BoxType.mdia, in: trak.children),
              let minf = parser.findBox(type: MP4BoxType.minf, in: mdia.children),
              let stbl = parser.findBox(type: MP4BoxType.stbl, in: minf.children) else {
            return nil
        }
        return stbl
    }

    /// Parse edit list to get media time offset
    /// Returns the media_time from first edit entry, which shifts presentation times
    private func parseEditList(in trak: MP4Box) -> Int64 {
        // Path: trak -> edts -> elst
        guard let edts = parser.findBox(type: MP4BoxType.edts, in: trak.children),
              let elst = parser.findBox(type: MP4BoxType.elst, in: edts.children) else {
            return 0
        }

        do {
            let data = try reader.read(offset: elst.payloadOffset, length: Int(elst.payloadSize))
            let version = data[0]

            // Skip version (1) + flags (3)
            var offset = 4

            let entryCount = data.readUInt32(at: offset)
            offset += 4

            guard entryCount > 0 else { return 0 }

            // Read first entry
            if version == 0 {
                // 32-bit: segment_duration (4) + media_time (4) + media_rate (4)
                let mediaTime = Int32(bitPattern: data.readUInt32(at: offset + 4))
                // media_time of -1 means empty edit (skip)
                return mediaTime == -1 ? 0 : Int64(mediaTime)
            } else {
                // 64-bit: segment_duration (8) + media_time (8) + media_rate (4)
                let mediaTime = Int64(bitPattern: data.readUInt64(at: offset + 8))
                return mediaTime == -1 ? 0 : mediaTime
            }
        } catch {
            return 0
        }
    }

    /// Parse video track information
    private func parseVideoTrack(_ trak: MP4Box) throws -> VideoTrackInfo? {
        // Check handler type
        guard let mdia = parser.findBox(type: MP4BoxType.mdia, in: trak.children),
              let hdlr = parser.findBox(type: MP4BoxType.hdlr, in: mdia.children) else {
            return nil
        }

        // Read handler type
        let hdlrData = try reader.read(offset: hdlr.payloadOffset, length: min(16, Int(hdlr.payloadSize)))
        // Handler type is at offset 8 (after version+flags+predefined)
        let handlerType = hdlrData.readFourCC(at: 8)

        // Check if this is a video track
        guard handlerType == "vide" else {
            return nil
        }

        // Get media header for timescale
        guard let mdhd = parser.findBox(type: MP4BoxType.mdhd, in: mdia.children) else {
            return nil
        }

        let mdhdData = try reader.read(offset: mdhd.payloadOffset, length: Int(mdhd.payloadSize))
        let version = mdhdData[0]

        let timescale: UInt32
        let duration: UInt64

        if version == 0 {
            // 32-bit values
            timescale = mdhdData.readUInt32(at: 12)  // After version+flags+creation+modification
            duration = UInt64(mdhdData.readUInt32(at: 16))
        } else {
            // 64-bit values
            timescale = mdhdData.readUInt32(at: 20)  // After version+flags+creation(8)+modification(8)
            duration = mdhdData.readUInt64(at: 24)
        }

        // Get sample description for codec info
        guard let minf = parser.findBox(type: MP4BoxType.minf, in: mdia.children),
              let stbl = parser.findBox(type: MP4BoxType.stbl, in: minf.children),
              let stsd = parser.findBox(type: MP4BoxType.stsd, in: stbl.children) else {
            return nil
        }

        // Parse stsd to get codec config
        let codecInfo = try parseStsd(stsd)

        // Get sample count from stsz
        let sampleCount: Int
        if let stsz = parser.findBox(type: MP4BoxType.stsz, in: stbl.children) {
            let stszData = try reader.read(offset: stsz.payloadOffset, length: 12)
            sampleCount = Int(stszData.readUInt32(at: 8))
        } else {
            sampleCount = 0
        }

        return VideoTrackInfo(
            width: codecInfo.width,
            height: codecInfo.height,
            codecType: codecInfo.codecType,
            codecConfig: codecInfo.codecConfig,
            timescale: timescale,
            duration: duration,
            sampleCount: sampleCount
        )
    }

    /// Codec configuration info
    private struct CodecInfo {
        let width: UInt32
        let height: UInt32
        let codecType: FourCC
        let codecConfig: Data
    }

    /// Parse stsd box to extract codec configuration
    private func parseStsd(_ stsd: MP4Box) throws -> CodecInfo {
        let data = try reader.read(offset: stsd.payloadOffset, length: Int(stsd.payloadSize))

        // Skip version (1) + flags (3) + entry count (4)
        var offset = 8

        // Read first sample entry
        let entrySize = data.readUInt32(at: offset)
        let entryType = data.readUInt32(at: offset + 4)

        // Check for video codec types
        let isH264 = entryType == MP4BoxType.avc1 || entryType == MP4BoxType.avc3
        let isHEVC = entryType == MP4BoxType.hvc1 || entryType == MP4BoxType.hev1

        guard isH264 || isHEVC else {
            throw DemuxerError.parseError("Unsupported codec: \(entryType.string)")
        }

        // Visual sample entry format (ISO 14496-12):
        // 8 bytes: size + type
        // 6 bytes: reserved
        // 2 bytes: data reference index
        // -- VisualSampleEntry extends SampleEntry --
        // 2 bytes: pre_defined
        // 2 bytes: reserved
        // 12 bytes: pre_defined (3 x uint32)
        // 2 bytes: width  (offset 32 from entry start)
        // 2 bytes: height (offset 34 from entry start)
        // 4 bytes: horizontal resolution (0x00480000 = 72 dpi)
        // 4 bytes: vertical resolution
        // 4 bytes: reserved
        // 2 bytes: frame count
        // 32 bytes: compressor name (pascal string)
        // 2 bytes: depth
        // 2 bytes: pre_defined (-1)
        // Then child boxes (avcC, hvcC, etc.)
        // Total header: 86 bytes

        let width = UInt32(data.readUInt16(at: offset + 32))
        let height = UInt32(data.readUInt16(at: offset + 34))

        // Find codec config box (avcC or hvcC)
        let configBoxType = isH264 ? MP4BoxType.avcC : MP4BoxType.hvcC
        let entryPayloadOffset = offset + 86  // After visual sample entry header

        // Search for codec config box within entry
        var codecConfig = Data()
        var searchOffset = entryPayloadOffset

        while searchOffset + 8 < offset + Int(entrySize) {
            let boxSize = data.readUInt32(at: searchOffset)
            let boxType = data.readUInt32(at: searchOffset + 4)

            if boxType == configBoxType {
                // Found codec config - extract payload
                let configStart = searchOffset + 8
                let configEnd = searchOffset + Int(boxSize)
                if configEnd <= data.count {
                    codecConfig = Data(data[configStart..<configEnd])
                }
                break
            }

            searchOffset += Int(boxSize)
            if boxSize == 0 { break }
        }

        guard !codecConfig.isEmpty else {
            throw DemuxerError.invalidCodecConfig
        }

        return CodecInfo(
            width: width,
            height: height,
            codecType: entryType,
            codecConfig: codecConfig
        )
    }
}

// MARK: - Data Extension for UInt16

extension Data {
    /// Read a big-endian UInt16 at the specified offset
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
}

// MARK: - Debug Helpers

extension MP4Demuxer {
    /// Generate a summary string of the parsed MP4
    func summaryString() -> String {
        var output = "=== MP4 Demuxer Summary ===\n"
        output += "File size: \(fileSize) bytes\n\n"

        if let trackInfo = videoTrackInfo {
            output += "Video Track:\n"
            output += "  Codec: \(trackInfo.codecType.string)\n"
            output += "  Dimensions: \(trackInfo.width)x\(trackInfo.height)\n"
            output += "  Timescale: \(trackInfo.timescale)\n"
            output += "  Duration: \(trackInfo.duration) (\(Double(trackInfo.duration) / Double(trackInfo.timescale)) seconds)\n"
            output += "  Sample count: \(trackInfo.sampleCount)\n"
            output += "  Codec config size: \(trackInfo.codecConfig.count) bytes\n"
            output += "  Edit list offset: \(mediaTimeOffset) (\(Double(mediaTimeOffset) / Double(trackInfo.timescale)) seconds)\n\n"
        }

        if let sampleTable = sampleTable {
            output += "Sample Table:\n"
            output += "  Total samples: \(sampleTable.count)\n"

            if let first = sampleTable[0] {
                output += "  First sample: offset=\(first.offset), size=\(first.size), keyframe=\(first.flags.isKeyFrame)\n"
            }
            if let last = sampleTable[sampleTable.count - 1] {
                output += "  Last sample: offset=\(last.offset), size=\(last.size), keyframe=\(last.flags.isKeyFrame)\n"
            }

            // Count keyframes
            let keyframeCount = sampleTable.samples.filter { $0.flags.isKeyFrame }.count
            output += "  Keyframe count: \(keyframeCount)\n"
        }

        return output
    }
}
