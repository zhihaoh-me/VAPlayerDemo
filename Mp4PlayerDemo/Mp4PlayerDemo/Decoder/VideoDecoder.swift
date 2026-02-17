import Foundation
import VideoToolbox
import CoreMedia
import os

/// Errors that can occur during video decoding
enum VideoDecoderError: Error {
    case invalidCodecConfig
    case formatDescriptionCreationFailed(OSStatus)
    case decompressionSessionCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
    case unsupportedCodec
    case noFrameOutput
}

/// Decoded frame with pixel buffer and timing info
struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let decodeTime: CMTime
}

/// Video decoder using VideoToolbox
final class VideoDecoder {
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private let trackInfo: VideoTrackInfo

    /// NAL unit length size (typically 4 bytes)
    private var nalLengthSize: Int = 4

    /// Queue for output frames (handles B-frame reordering)
    private var outputFrames: [DecodedFrame] = []
    private let outputLock = NSLock()

    /// Indicates if decoder is ready
    var isConfigured: Bool {
        decompressionSession != nil
    }

    init(trackInfo: VideoTrackInfo) {
        self.trackInfo = trackInfo
    }

    deinit {
        invalidate()
    }

    /// Configure the decoder with codec configuration
    func configure() throws {
        let codecType = trackInfo.codecType
        let codecString = codecType.string

        // Check codec type by string comparison for robustness
        let isH264 = codecString == "avc1" || codecString == "avc3"
        let isHEVC = codecString == "hvc1" || codecString == "hev1"

        let configSize = trackInfo.codecConfig.count
        Log.decoder.info("codec=\(codecString), isH264=\(isH264), isHEVC=\(isHEVC), configSize=\(configSize)")

        if isH264 {
            try configureH264()
        } else if isHEVC {
            try configureHEVC()
        } else {
            throw VideoDecoderError.unsupportedCodec
        }

        try createDecompressionSession()
    }

    /// Decode a single sample
    /// - Parameters:
    ///   - sampleData: Raw sample data from demuxer (NAL units with length prefixes)
    ///   - sample: Sample metadata for timing information
    /// - Returns: Decoded frame with pixel buffer, or nil if frame was dropped
    func decode(sampleData: Data, sample: MP4Sample) throws -> DecodedFrame? {
        guard let session = decompressionSession,
              let formatDesc = formatDescription else {
            throw VideoDecoderError.decompressionSessionCreationFailed(kVTInvalidSessionErr)
        }

        // Create CMBlockBuffer from sample data
        var blockBuffer: CMBlockBuffer?

        let status = sampleData.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) -> OSStatus in
            guard let baseAddress = rawBufferPointer.baseAddress else {
                return -12780 // kCMBlockBufferBadPointerErr
            }

            // Create a copy of the data for the block buffer
            let dataLength = sampleData.count
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataLength,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataLength,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr, let buffer = blockBuffer else {
                return status
            }

            // Copy data into block buffer
            status = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )

            return status
        }

        guard status == noErr, let buffer = blockBuffer else {
            throw VideoDecoderError.decodeFailed(status)
        }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: Int64(sample.duration), timescale: Int32(trackInfo.timescale)),
            presentationTimeStamp: CMTime(value: sample.presentationTime, timescale: Int32(trackInfo.timescale)),
            decodeTimeStamp: CMTime(value: sample.decodeTime, timescale: Int32(trackInfo.timescale))
        )

        var sampleSize = sampleData.count
        let sampleBufferStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleBufferStatus == noErr, let cmSampleBuffer = sampleBuffer else {
            throw VideoDecoderError.decodeFailed(sampleBufferStatus)
        }

        // Decode the frame - output comes through callback and is queued
        var infoFlags: VTDecodeInfoFlags = []
        let inputPTS = timingInfo.presentationTimeStamp

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: cmSampleBuffer,
            flags: [], // Synchronous decoding
            infoFlagsOut: &infoFlags
        ) { [weak self] status, infoFlags, imageBuffer, pts, dts in
            guard let self = self else { return }
            if status == noErr, let buffer = imageBuffer {
                let frame = DecodedFrame(
                    pixelBuffer: buffer,
                    presentationTime: pts,
                    decodeTime: dts
                )
                self.outputLock.lock()
                self.outputFrames.append(frame)
                self.outputLock.unlock()
                Log.decoder.debug("output frame pts=\(pts.seconds) from input pts=\(inputPTS.seconds), input dts=\(timingInfo.decodeTimeStamp.seconds)")
            } else {
                Log.decoder.warning("callback status=\(status), infoFlags=\(infoFlags.rawValue), hasBuffer=\(imageBuffer != nil)")
            }
        }

        guard decodeStatus == noErr else {
            throw VideoDecoderError.decodeFailed(decodeStatus)
        }

        // Return the first available frame from the queue
        return dequeueFrame()
    }

    /// Dequeue a frame from the output queue
    private func dequeueFrame() -> DecodedFrame? {
        outputLock.lock()
        defer { outputLock.unlock() }

        guard !outputFrames.isEmpty else { return nil }
        return outputFrames.removeFirst()
    }

    /// Get all remaining frames in the queue (call after finishDelayedFrames)
    func drainFrames() -> [DecodedFrame] {
        outputLock.lock()
        defer { outputLock.unlock() }

        let frames = outputFrames
        outputFrames.removeAll()
        return frames
    }

    /// Flush the decoder (call when seeking or stopping)
    func flush() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    /// Finish decoding and signal end of stream (call at end of stream)
    /// VideoToolbox may hold B-frames for reordering - this forces them out
    func finishDelayedFrames() {
        guard let session = decompressionSession else { return }

        outputLock.lock()
        let countBefore = outputFrames.count
        outputLock.unlock()

        Log.decoder.info("finishDelayedFrames called, queue has \(countBefore) frames")

        // Tell VideoToolbox no more frames are coming
        let status = VTDecompressionSessionFinishDelayedFrames(session)
        Log.decoder.info("FinishDelayedFrames returned \(status)")

        // Wait for any remaining async frames
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        outputLock.lock()
        let countAfter = outputFrames.count
        outputLock.unlock()

        Log.decoder.info("after finish, queue has \(countAfter) frames (added \(countAfter - countBefore))")
    }

    /// Invalidate and release resources
    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
    }

    // MARK: - H.264 Configuration

    private func configureH264() throws {
        let config = trackInfo.codecConfig
        guard config.count >= 7 else {
            throw VideoDecoderError.invalidCodecConfig
        }

        // Parse avcC box
        // Byte 0: configurationVersion
        // Byte 1: AVCProfileIndication
        // Byte 2: profile_compatibility
        // Byte 3: AVCLevelIndication
        // Byte 4: lengthSizeMinusOne (lower 2 bits)
        // Byte 5: numOfSequenceParameterSets (lower 5 bits)
        // Then: SPS data
        // Then: numOfPictureParameterSets (1 byte)
        // Then: PPS data

        nalLengthSize = Int(config[4] & 0x03) + 1

        var offset = 5
        let numSPS = Int(config[offset] & 0x1F)
        offset += 1

        var parameterSets: [Data] = []

        // Read SPS
        for _ in 0..<numSPS {
            guard offset + 2 <= config.count else {
                throw VideoDecoderError.invalidCodecConfig
            }
            let spsLength = Int(config[offset]) << 8 | Int(config[offset + 1])
            offset += 2

            guard offset + spsLength <= config.count else {
                throw VideoDecoderError.invalidCodecConfig
            }
            parameterSets.append(config[offset..<offset + spsLength])
            offset += spsLength
        }

        // Read PPS count
        guard offset < config.count else {
            throw VideoDecoderError.invalidCodecConfig
        }
        let numPPS = Int(config[offset])
        offset += 1

        // Read PPS
        for _ in 0..<numPPS {
            guard offset + 2 <= config.count else {
                throw VideoDecoderError.invalidCodecConfig
            }
            let ppsLength = Int(config[offset]) << 8 | Int(config[offset + 1])
            offset += 2

            guard offset + ppsLength <= config.count else {
                throw VideoDecoderError.invalidCodecConfig
            }
            parameterSets.append(config[offset..<offset + ppsLength])
            offset += ppsLength
        }

        // Create format description from parameter sets
        try createH264FormatDescription(parameterSets: parameterSets)
    }

    private func createH264FormatDescription(parameterSets: [Data]) throws {
        // Need to keep the data alive during the call
        var formatDesc: CMFormatDescription?
        let status = parameterSets.withUnsafeBufferPointers { bufferPointers in
            let pointers = bufferPointers.map { $0.baseAddress! }
            let sizes = bufferPointers.map { $0.count }

            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalLengthSize),
                formatDescriptionOut: &formatDesc
            )
        }

        guard status == noErr, let desc = formatDesc else {
            throw VideoDecoderError.formatDescriptionCreationFailed(status)
        }

        formatDescription = desc
    }

    // MARK: - HEVC Configuration

    private func configureHEVC() throws {
        let config = trackInfo.codecConfig
        Log.decoder.info("HEVC config size: \(config.count) bytes")
        Log.decoder.debug("HEVC config hex: \(config.prefix(30).map { String(format: "%02x", $0) }.joined(separator: " "))")

        guard config.count >= 23 else {
            Log.decoder.error("HEVC config too small: \(config.count) < 23")
            throw VideoDecoderError.invalidCodecConfig
        }

        // Parse hvcC box (HEVCDecoderConfigurationRecord)
        // Byte 0: configurationVersion
        // Byte 1: general_profile_space (2 bits) + general_tier_flag (1 bit) + general_profile_idc (5 bits)
        // Bytes 2-5: general_profile_compatibility_flags (32 bits)
        // Bytes 6-11: general_constraint_indicator_flags (48 bits)
        // Byte 12: general_level_idc
        // Bytes 13-14: reserved (4 bits) + min_spatial_segmentation_idc (12 bits)
        // Byte 15: reserved (6 bits) + parallelismType (2 bits)
        // Byte 16: reserved (6 bits) + chromaFormat (2 bits)
        // Byte 17: reserved (5 bits) + bitDepthLumaMinus8 (3 bits)
        // Byte 18: reserved (5 bits) + bitDepthChromaMinus8 (3 bits)
        // Bytes 19-20: avgFrameRate (16 bits)
        // Byte 21: constantFrameRate (2 bits) + numTemporalLayers (3 bits) + temporalIdNested (1 bit) + lengthSizeMinusOne (2 bits)
        // Byte 22: numOfArrays
        // Then: arrays of NAL units (VPS, SPS, PPS, etc.)

        // Access bytes safely using Array conversion
        let configBytes = [UInt8](config)
        let byte21 = configBytes[21]
        let byte22 = configBytes[22]
        nalLengthSize = Int(byte21 & 0x03) + 1
        let numArrays = Int(byte22)

        let nalLen = nalLengthSize
        Log.decoder.debug("HEVC: byte21=0x\(String(format: "%02x", byte21)), nalLengthSize=\(nalLen), numArrays=\(numArrays)")

        var offset = 23
        var parameterSets: [Data] = []

        for _ in 0..<numArrays {
            guard offset + 3 <= configBytes.count else {
                throw VideoDecoderError.invalidCodecConfig
            }

            // Skip array_completeness and NAL unit type
            offset += 1

            let numNalus = Int(configBytes[offset]) << 8 | Int(configBytes[offset + 1])
            offset += 2

            for _ in 0..<numNalus {
                guard offset + 2 <= configBytes.count else {
                    throw VideoDecoderError.invalidCodecConfig
                }

                let naluLength = Int(configBytes[offset]) << 8 | Int(configBytes[offset + 1])
                offset += 2

                guard offset + naluLength <= configBytes.count else {
                    throw VideoDecoderError.invalidCodecConfig
                }

                parameterSets.append(Data(configBytes[offset..<offset + naluLength]))
                offset += naluLength
            }
        }

        // Create format description from parameter sets
        Log.decoder.info("HEVC: parsed \(parameterSets.count) parameter sets, sizes: \(parameterSets.map { $0.count })")
        try createHEVCFormatDescription(parameterSets: parameterSets)
        Log.decoder.info("HEVC: format description created successfully")
    }

    private func createHEVCFormatDescription(parameterSets: [Data]) throws {
        var formatDesc: CMFormatDescription?
        let status = parameterSets.withUnsafeBufferPointers { bufferPointers in
            let pointers = bufferPointers.map { $0.baseAddress! }
            let sizes = bufferPointers.map { $0.count }

            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalLengthSize),
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
        }

        guard status == noErr, let desc = formatDesc else {
            throw VideoDecoderError.formatDescriptionCreationFailed(status)
        }

        formatDescription = desc
    }

    // MARK: - Decompression Session

    private func createDecompressionSession() throws {
        guard let formatDesc = formatDescription else {
            throw VideoDecoderError.formatDescriptionCreationFailed(kVTPropertyNotSupportedErr)
        }

        // Configure output pixel buffer attributes with larger pool
        // We buffer up to 90 frames, so we need a pool large enough
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: trackInfo.width,
            kCVPixelBufferHeightKey as String: trackInfo.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferPoolMinimumBufferCountKey as String: 90 // Ensure enough buffers for all frames
        ]

        // Create callback record (we'll use synchronous decode with completion handler)
        var outputCallback = VTDecompressionOutputCallbackRecord()

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )

        guard status == noErr, let decompSession = session else {
            throw VideoDecoderError.decompressionSessionCreationFailed(status)
        }

        decompressionSession = decompSession
    }
}

// MARK: - Helper Extension

extension Array where Element == Data {
    /// Execute a closure with unsafe buffer pointers to all data elements
    func withUnsafeBufferPointers<R>(_ body: ([UnsafeBufferPointer<UInt8>]) -> R) -> R {
        func process(index: Int, accumulated: [UnsafeBufferPointer<UInt8>]) -> R {
            if index >= count {
                return body(accumulated)
            }
            return self[index].withUnsafeBytes { rawBuffer in
                let bufferPointer = rawBuffer.bindMemory(to: UInt8.self)
                var newAccumulated = accumulated
                newAccumulated.append(bufferPointer)
                return process(index: index + 1, accumulated: newAccumulated)
            }
        }

        return process(index: 0, accumulated: [])
    }
}
