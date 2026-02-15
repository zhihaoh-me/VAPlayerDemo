import Foundation

/// Four-character code type used for MP4 box types
typealias FourCC = UInt32

/// Extension to convert FourCC to/from string representation
extension FourCC {
    /// Create a FourCC from a 4-character string
    init(_ string: String) {
        precondition(string.count == 4, "FourCC must be exactly 4 characters")
        let bytes = Array(string.utf8)
        self = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    /// Convert FourCC to string representation
    var string: String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

/// MP4 box type constants
enum MP4BoxType {
    // Top-level boxes
    static let ftyp = FourCC("ftyp")  // File type
    static let moov = FourCC("moov")  // Movie metadata
    static let mdat = FourCC("mdat")  // Media data
    static let free = FourCC("free")  // Free space
    static let skip = FourCC("skip")  // Skip

    // Movie boxes
    static let mvhd = FourCC("mvhd")  // Movie header
    static let trak = FourCC("trak")  // Track
    static let udta = FourCC("udta")  // User data

    // Track boxes
    static let tkhd = FourCC("tkhd")  // Track header
    static let edts = FourCC("edts")  // Edit list container
    static let elst = FourCC("elst")  // Edit list
    static let mdia = FourCC("mdia")  // Media

    // Media boxes
    static let mdhd = FourCC("mdhd")  // Media header
    static let hdlr = FourCC("hdlr")  // Handler reference
    static let minf = FourCC("minf")  // Media info

    // Media info boxes
    static let vmhd = FourCC("vmhd")  // Video media header
    static let smhd = FourCC("smhd")  // Sound media header
    static let dinf = FourCC("dinf")  // Data info
    static let stbl = FourCC("stbl")  // Sample table

    // Sample table boxes
    static let stsd = FourCC("stsd")  // Sample description
    static let stts = FourCC("stts")  // Decoding time-to-sample
    static let stsc = FourCC("stsc")  // Sample-to-chunk
    static let stsz = FourCC("stsz")  // Sample sizes
    static let stco = FourCC("stco")  // Chunk offsets (32-bit)
    static let co64 = FourCC("co64")  // Chunk offsets (64-bit)
    static let stss = FourCC("stss")  // Sync samples (keyframes)
    static let ctts = FourCC("ctts")  // Composition time offsets

    // Codec boxes
    static let avc1 = FourCC("avc1")  // H.264 video
    static let avc3 = FourCC("avc3")  // H.264 video (variant)
    static let hvc1 = FourCC("hvc1")  // H.265/HEVC video
    static let hev1 = FourCC("hev1")  // H.265/HEVC video (variant)
    static let avcC = FourCC("avcC")  // H.264 decoder config
    static let hvcC = FourCC("hvcC")  // H.265 decoder config

    // Audio codec boxes
    static let mp4a = FourCC("mp4a")  // AAC audio
    static let esds = FourCC("esds")  // ES descriptor

    /// Set of container boxes that can have child boxes
    static let containerTypes: Set<FourCC> = [
        moov, trak, mdia, minf, stbl, dinf, edts, udta
    ]

    /// Check if a box type is a container
    static func isContainer(_ type: FourCC) -> Bool {
        containerTypes.contains(type)
    }
}

/// MP4 box header sizes
enum MP4BoxHeader {
    static let standardSize = 8       // 4 bytes size + 4 bytes type
    static let extendedSize = 16      // Standard + 8 bytes extended size
    static let fullBoxExtra = 4       // Version (1 byte) + flags (3 bytes)
}

/// Represents a parsed MP4 box
struct MP4Box {
    /// Box type as FourCC
    let type: FourCC

    /// Total box size including header
    let size: UInt64

    /// Absolute file offset where this box starts
    let offset: UInt64

    /// Header size (8 for standard, 16 for extended)
    let headerSize: Int

    /// Offset where payload (content after header) begins
    var payloadOffset: UInt64 {
        offset + UInt64(headerSize)
    }

    /// Size of payload (excluding header)
    var payloadSize: UInt64 {
        size - UInt64(headerSize)
    }

    /// Box type as readable string
    var typeString: String {
        type.string
    }

    /// Child boxes (populated for container boxes)
    var children: [MP4Box] = []
}

/// Sample flags indicating frame type
struct SampleFlags: OptionSet {
    let rawValue: UInt32

    static let keyFrame = SampleFlags(rawValue: 1 << 0)

    var isKeyFrame: Bool {
        contains(.keyFrame)
    }
}

/// Represents a single sample/frame in the video
struct MP4Sample {
    /// Sample index (0-based)
    let index: Int

    /// Absolute byte offset in file
    let offset: UInt64

    /// Sample size in bytes
    let size: UInt32

    /// Decode timestamp in timescale units
    let decodeTime: Int64

    /// Presentation timestamp in timescale units
    let presentationTime: Int64

    /// Duration in timescale units
    let duration: UInt32

    /// Sample flags (keyframe, etc.)
    let flags: SampleFlags
}

/// Video track information extracted from MP4
struct VideoTrackInfo {
    /// Video width in pixels
    let width: UInt32

    /// Video height in pixels
    let height: UInt32

    /// Codec type (e.g., avc1 for H.264)
    let codecType: FourCC

    /// Codec configuration data (avcC or hvcC box content)
    let codecConfig: Data

    /// Timescale (units per second)
    let timescale: UInt32

    /// Duration in timescale units
    let duration: UInt64

    /// Total number of samples
    let sampleCount: Int
}
