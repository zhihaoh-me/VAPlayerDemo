import Foundation

/// Errors that can occur during MP4 parsing
enum MP4ParserError: Error {
    case invalidBoxHeader
    case unexpectedEndOfFile
    case boxSizeTooSmall
    case invalidBoxType
    case moovBoxNotFound
    case videoTrackNotFound
}

/// Parser for MP4 box structure
final class MP4BoxParser {
    private let reader: ByteRangeReader

    init(reader: ByteRangeReader) {
        self.reader = reader
    }

    /// Parse box header at the given offset
    /// - Parameter offset: Absolute file offset
    /// - Returns: Parsed MP4Box (without children)
    func parseBoxHeader(at offset: UInt64) throws -> MP4Box {
        // Read standard header (8 bytes)
        let headerData = try reader.read(offset: offset, length: MP4BoxHeader.standardSize)

        guard headerData.count >= MP4BoxHeader.standardSize else {
            throw MP4ParserError.unexpectedEndOfFile
        }

        var size = UInt64(headerData.readUInt32(at: 0))
        let type = headerData.readUInt32(at: 4)
        var headerSize = MP4BoxHeader.standardSize

        // Handle special size values
        if size == 1 {
            // Extended size: read 8 more bytes
            let extendedData = try reader.read(offset: offset + 8, length: 8)
            size = extendedData.readUInt64(at: 0)
            headerSize = MP4BoxHeader.extendedSize
        } else if size == 0 {
            // Box extends to end of file
            size = reader.length - offset
        }

        // Validate size
        guard size >= UInt64(headerSize) else {
            throw MP4ParserError.boxSizeTooSmall
        }

        return MP4Box(
            type: type,
            size: size,
            offset: offset,
            headerSize: headerSize
        )
    }

    /// Parse all top-level boxes in the file
    /// - Returns: Array of top-level MP4 boxes
    func parseTopLevelBoxes() throws -> [MP4Box] {
        var boxes: [MP4Box] = []
        var offset: UInt64 = 0

        while offset < reader.length {
            let box = try parseBoxHeader(at: offset)
            boxes.append(box)
            offset += box.size
        }

        return boxes
    }

    /// Parse a container box and its children recursively
    /// - Parameter box: The container box to parse
    /// - Returns: The box with its children populated
    func parseContainerBox(_ box: MP4Box) throws -> MP4Box {
        var result = box
        result.children = []

        var offset = box.payloadOffset
        let endOffset = box.offset + box.size

        while offset < endOffset {
            // Check if we have enough bytes for a header
            if offset + UInt64(MP4BoxHeader.standardSize) > endOffset {
                break
            }

            var childBox = try parseBoxHeader(at: offset)

            // Recursively parse if this is a container
            if MP4BoxType.isContainer(childBox.type) {
                childBox = try parseContainerBox(childBox)
            }

            result.children.append(childBox)
            offset += childBox.size
        }

        return result
    }

    /// Parse the entire MP4 structure including nested boxes
    /// - Returns: Array of top-level boxes with children populated
    func parseFullStructure() throws -> [MP4Box] {
        var boxes: [MP4Box] = []
        var offset: UInt64 = 0

        while offset < reader.length {
            var box = try parseBoxHeader(at: offset)

            // Parse children for container boxes
            if MP4BoxType.isContainer(box.type) {
                box = try parseContainerBox(box)
            }

            boxes.append(box)
            offset += box.size
        }

        return boxes
    }

    /// Find a specific box by type in the box hierarchy
    /// - Parameters:
    ///   - type: Box type to find
    ///   - boxes: Array of boxes to search
    /// - Returns: First matching box or nil
    func findBox(type: FourCC, in boxes: [MP4Box]) -> MP4Box? {
        for box in boxes {
            if box.type == type {
                return box
            }
            if let found = findBox(type: type, in: box.children) {
                return found
            }
        }
        return nil
    }

    /// Find all boxes of a specific type
    /// - Parameters:
    ///   - type: Box type to find
    ///   - boxes: Array of boxes to search
    /// - Returns: All matching boxes
    func findAllBoxes(type: FourCC, in boxes: [MP4Box]) -> [MP4Box] {
        var results: [MP4Box] = []
        for box in boxes {
            if box.type == type {
                results.append(box)
            }
            results.append(contentsOf: findAllBoxes(type: type, in: box.children))
        }
        return results
    }

    /// Read the raw payload data of a box
    /// - Parameter box: The box to read payload from
    /// - Returns: Raw payload data
    func readBoxPayload(_ box: MP4Box) throws -> Data {
        try reader.read(offset: box.payloadOffset, length: Int(box.payloadSize))
    }
}

// MARK: - Debug Helpers

extension MP4BoxParser {
    /// Generate a string representation of the box hierarchy
    func boxHierarchyString(_ boxes: [MP4Box], indent: Int = 0) -> String {
        var result = ""
        let prefix = String(repeating: "  ", count: indent)

        for box in boxes {
            result += "\(prefix)[\(box.typeString)] size=\(box.size) offset=\(box.offset)\n"
            if !box.children.isEmpty {
                result += boxHierarchyString(box.children, indent: indent + 1)
            }
        }

        return result
    }
}
