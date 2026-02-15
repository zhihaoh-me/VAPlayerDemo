import Foundation

/// Errors that can occur during byte range reading
enum ByteRangeReaderError: Error {
    case fileNotFound
    case seekFailed
    case readFailed
    case invalidRange
}

/// Protocol for reading bytes from a resource using byte range requests.
/// This abstraction allows for both local file reading and future HTTP byte range support.
protocol ByteRangeReader {
    /// Total size of the resource in bytes
    var length: UInt64 { get }

    /// Read bytes from a specific range
    /// - Parameters:
    ///   - offset: Starting byte offset
    ///   - length: Number of bytes to read
    /// - Returns: Data containing the requested bytes
    func read(offset: UInt64, length: Int) throws -> Data
}

/// File-based implementation of ByteRangeReader.
/// Simulates progressive download by reading specific byte ranges from a local file.
final class FileByteRangeReader: ByteRangeReader {
    private let fileHandle: FileHandle
    let length: UInt64

    /// Initialize with a file URL
    /// - Parameter url: URL to the local file
    init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ByteRangeReaderError.fileNotFound
        }

        self.fileHandle = try FileHandle(forReadingFrom: url)

        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        self.length = attributes[.size] as? UInt64 ?? 0
    }

    deinit {
        try? fileHandle.close()
    }

    /// Read bytes from a specific range
    /// Mimics HTTP Range request: bytes=offset-(offset+length-1)
    func read(offset: UInt64, length: Int) throws -> Data {
        guard offset < self.length else {
            throw ByteRangeReaderError.invalidRange
        }

        // Clamp length to not exceed file bounds
        let availableBytes = self.length - offset
        let bytesToRead = min(UInt64(length), availableBytes)

        // Seek to offset
        try fileHandle.seek(toOffset: offset)

        // Read the requested bytes
        guard let data = try fileHandle.read(upToCount: Int(bytesToRead)) else {
            throw ByteRangeReaderError.readFailed
        }

        return data
    }
}

/// Helper extension for reading primitive types from Data
extension Data {
    /// Read a big-endian UInt32 at the specified offset (handles unaligned access)
    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        // Read bytes individually to avoid alignment issues
        return UInt32(self[offset]) << 24 |
               UInt32(self[offset + 1]) << 16 |
               UInt32(self[offset + 2]) << 8 |
               UInt32(self[offset + 3])
    }

    /// Read a big-endian UInt64 at the specified offset (handles unaligned access)
    func readUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        // Read bytes individually to avoid alignment issues
        return UInt64(self[offset]) << 56 |
               UInt64(self[offset + 1]) << 48 |
               UInt64(self[offset + 2]) << 40 |
               UInt64(self[offset + 3]) << 32 |
               UInt64(self[offset + 4]) << 24 |
               UInt64(self[offset + 5]) << 16 |
               UInt64(self[offset + 6]) << 8 |
               UInt64(self[offset + 7])
    }

    /// Read a 4-character code (FourCC) at the specified offset
    func readFourCC(at offset: Int) -> String {
        guard offset + 4 <= count else { return "" }
        let bytes = self[offset..<offset+4]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
