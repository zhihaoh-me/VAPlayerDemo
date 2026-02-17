//
//  ContentView.swift
//  Mp4PlayerDemo
//
//  Created by zhihao on 1/21/26.
//

import SwiftUI
import CoreMedia
import CoreVideo
import AVFoundation

// MARK: - Video File Configuration
/// Change these values to swap the video file used throughout the app.
private let videoFileName = "pin_demo"
private let videoFileExtension = "mp4"

struct ContentView: View {
    var body: some View {
        TabView {
            DebugView()
                .tabItem {
                    Label("Debug", systemImage: "wrench.and.screwdriver")
                }

            PlayerDemoView()
                .tabItem {
                    Label("Player", systemImage: "play.circle")
                }

            SampleBufferPlayerDemoView()
                .tabItem {
                    Label("SB Player", systemImage: "play.rectangle")
                }
        }
    }
}

// MARK: - Player Demo View (Phase 6)

struct PlayerDemoView: View {
    @StateObject private var engine = VideoPlayerEngine()
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Video display area
            ZStack {
                Color.black

                if let pixelBuffer = engine.currentFrame {
                    SingleFrameMetalView(pixelBuffer: pixelBuffer)
                } else if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                } else if engine.state == .idle {
                    VStack(spacing: 12) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 60))
                            .foregroundColor(.white.opacity(0.6))
                        Text("Tap Play to start")
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                // State overlay
                if engine.state == .ended {
                    VStack {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.green)
                        Text("Playback Complete")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                }
            }
            .aspectRatio(videoAspectRatio, contentMode: .fit)
            .cornerRadius(8)
            .padding()

            // Progress bar
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 4)

                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * progress, height: 4)
                    }
                    .cornerRadius(2)
                }
                .frame(height: 4)

                HStack {
                    Text(formatTime(engine.currentTime.seconds))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(engine.duration.seconds))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)

            // Controls
            HStack(spacing: 20) {
                Button(action: {
                    loadAndPlay()
                }) {
                    HStack {
                        Image(systemName: engine.state == .playing ? "stop.fill" : "play.fill")
                        Text(engine.state == .playing ? "Stop" : "Play")
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)

                if engine.state == .ended {
                    Button(action: {
                        replay()
                    }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Replay")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()

            // Status
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
    }

    private var progress: CGFloat {
        guard engine.duration.seconds > 0 else { return 0 }
        return CGFloat(engine.currentTime.seconds / engine.duration.seconds)
    }

    private var videoAspectRatio: CGFloat {
        guard engine.videoSize.height > 0 else { return 16/9 }
        return engine.videoSize.width / engine.videoSize.height
    }

    private var statusText: String {
        switch engine.state {
        case .idle:
            return "Ready"
        case .buffering:
            return "Buffering..."
        case .playing:
            return "Playing"
        case .ended:
            return "Finished"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func loadAndPlay() {
        if engine.state == .playing {
            engine.stop()
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                guard let url = Bundle.main.url(forResource: videoFileName, withExtension: videoFileExtension) else {
                    throw VideoPlayerError.noVideoTrack
                }
                try await engine.load(url: url)
                engine.play()
                isLoading = false
            } catch {
                errorMessage = "Error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    private func replay() {
        engine.stop()
        loadAndPlay()
    }
}

// MARK: - SampleBuffer Player Demo View

struct SampleBufferPlayerDemoView: View {
    @StateObject private var engine = SampleBufferPlayerEngine()
    @State private var errorMessage: String?
    @State private var isWarmedUp = false

    var body: some View {
        VStack(spacing: 0) {
            // Video display area
            ZStack {
                Color.black

                SampleBufferPlayerView(displayLayer: engine.displayLayer)

                if engine.state == .idle && !isWarmedUp {
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 60))
                            .foregroundColor(.white.opacity(0.6))
                        Text("Tap Warmup to prepare")
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                if engine.state == .ended {
                    VStack {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.green)
                        Text("Playback Complete")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                }
            }
            .aspectRatio(videoAspectRatio, contentMode: .fit)
            .cornerRadius(8)
            .padding()

            // Progress bar
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 4)

                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * progress, height: 4)
                    }
                    .cornerRadius(2)
                }
                .frame(height: 4)

                HStack {
                    Text(formatTime(engine.currentTime.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(engine.duration.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)

            // Controls
            HStack(spacing: 12) {
                // Warmup button
                Button(action: { warmup() }) {
                    HStack {
                        Image(systemName: "bolt")
                        Text("Warmup")
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.bordered)
                .disabled(isWarmedUp)

                // Play / Pause button
                Button(action: { togglePlayPause() }) {
                    HStack {
                        Image(systemName: playButtonIcon)
                        Text(playButtonLabel)
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isWarmedUp)

                if engine.state == .ended {
                    Button(action: { replay() }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Replay")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()

            // Status
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom)

            if let error = errorMessage ?? engine.error.map({ "Renderer error: \($0.localizedDescription)" }) {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
    }

    private var progress: CGFloat {
        guard engine.duration.seconds > 0 else { return 0 }
        return CGFloat(engine.currentTime.seconds / engine.duration.seconds)
    }

    private var videoAspectRatio: CGFloat {
        guard engine.videoSize.height > 0 else { return 16/9 }
        return engine.videoSize.width / engine.videoSize.height
    }

    private var playButtonIcon: String {
        switch engine.state {
        case .playing: return "pause.fill"
        default: return "play.fill"
        }
    }

    private var playButtonLabel: String {
        switch engine.state {
        case .playing: return "Pause"
        case .buffering: return "Resume"
        default: return "Play"
        }
    }

    private var statusText: String {
        if engine.error != nil { return "Error" }
        switch engine.state {
        case .idle: return isWarmedUp ? "Warmed up — ready to play" : "Ready"
        case .buffering: return "Paused"
        case .playing: return "Playing"
        case .ended: return "Finished"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00.000" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%d:%02d.%03d", mins, secs, ms)
    }

    private func warmup() {
        errorMessage = nil
        do {
            guard let url = Bundle.main.url(forResource: videoFileName, withExtension: videoFileExtension) else {
                throw VideoPlayerError.noVideoTrack
            }
            try engine.warmup(url: url)
            isWarmedUp = true
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func togglePlayPause() {
        errorMessage = nil

        switch engine.state {
        case .idle, .ended:
            if !isWarmedUp { warmup() }
            engine.play()
        case .playing:
            engine.pause()
        case .buffering:
            engine.play()
        }
    }

    private func replay() {
        engine.stop()
        isWarmedUp = false
        warmup()
        engine.play()
    }
}

// MARK: - Debug View (Phases 1-5)

struct DebugView: View {
    @State private var parsingResult: String = "Tap a button to analyze \(videoFileName).\(videoFileExtension)"
    @State private var isParsing: Bool = false
    @State private var selectedTab: Int = 0
    @State private var decodedImages: [CGImage] = []
    @State private var decodedPixelBuffers: [CVPixelBuffer] = []

    var body: some View {
        VStack(spacing: 16) {
            Text("MP4 Parser Demo")
                .font(.title)
                .fontWeight(.bold)

            Picker("Mode", selection: $selectedTab) {
                Text("Parser").tag(0)
                Text("Demux").tag(1)
                Text("Decode").tag(2)
                Text("Metal").tag(3)
                Text("Buffer").tag(4)
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedTab) { _, _ in
                decodedImages = []
                decodedPixelBuffers = []
                switch selectedTab {
                case 0:
                    parsingResult = "Tap 'Parse Boxes' to analyze box structure"
                case 1:
                    parsingResult = "Tap 'Parse Demuxer' to extract video track info"
                case 2:
                    parsingResult = "Tap 'Decode Frame' to decode frames (CIImage)"
                case 3:
                    parsingResult = "Tap 'Render Metal' to decode and render with Metal"
                case 4:
                    parsingResult = "Tap 'Test Buffer' to test buffer fill/drain"
                default:
                    break
                }
            }

            Button(action: {
                switch selectedTab {
                case 0:
                    parseBoxes()
                case 1:
                    parseDemuxer()
                case 2:
                    decodeFirstFrame()
                case 3:
                    decodeWithMetal()
                case 4:
                    testBufferManager()
                default:
                    break
                }
            }) {
                HStack {
                    if isParsing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    }
                    Text(isParsing ? "Processing..." : buttonTitle)
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isParsing)

            // Show decoded frames if available
            if !decodedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(decodedImages.enumerated()), id: \.offset) { index, image in
                            VStack(spacing: 4) {
                                Image(decorative: image, scale: 1.0)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 120)
                                    .cornerRadius(4)
                                Text("Frame \(index)")
                                    .font(.caption2)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 150)
            }

            // Show Metal-rendered frames if available
            if !decodedPixelBuffers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(decodedPixelBuffers.enumerated()), id: \.offset) { index, buffer in
                            VStack(spacing: 4) {
                                SingleFrameMetalView(pixelBuffer: buffer)
                                    .frame(width: 160, height: 90)
                                    .cornerRadius(4)
                                Text("Frame \(index)")
                                    .font(.caption2)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 130)
            }

            ScrollView {
                Text(parsingResult)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(uiColor: .systemGray6))
            .cornerRadius(8)
        }
        .padding()
    }

    private var buttonTitle: String {
        switch selectedTab {
        case 0: return "Parse Boxes"
        case 1: return "Parse Demuxer"
        case 2: return "Decode Frame"
        case 3: return "Render Metal"
        case 4: return "Test Buffer"
        default: return "Run"
        }
    }

    // MARK: - Box Parser (Phase 1)

    private func parseBoxes() {
        isParsing = true
        parsingResult = "Parsing boxes..."

        Task {
            do {
                let result = try await performBoxParsing()
                await MainActor.run {
                    parsingResult = result
                    isParsing = false
                }
            } catch {
                await MainActor.run {
                    parsingResult = "Error: \(error)"
                    isParsing = false
                }
            }
        }
    }

    private func performBoxParsing() async throws -> String {
        guard let url = Bundle.main.url(forResource: videoFileName, withExtension: videoFileExtension) else {
            return "Error: demo.mp4 not found in bundle"
        }

        let reader = try FileByteRangeReader(url: url)
        let parser = MP4BoxParser(reader: reader)
        let boxes = try parser.parseFullStructure()

        var output = "File: \(videoFileName).\(videoFileExtension)\n"
        output += "Size: \(reader.length) bytes\n"
        output += "\n--- Box Hierarchy ---\n\n"
        output += parser.boxHierarchyString(boxes)

        output += "\n--- Summary ---\n"
        let ftypBox = parser.findBox(type: MP4BoxType.ftyp, in: boxes)
        let moovBox = parser.findBox(type: MP4BoxType.moov, in: boxes)
        let mdatBox = parser.findBox(type: MP4BoxType.mdat, in: boxes)

        output += "ftyp: \(ftypBox != nil ? "offset \(ftypBox!.offset)" : "Not found")\n"
        output += "moov: \(moovBox != nil ? "offset \(moovBox!.offset), size \(moovBox!.size)" : "Not found")\n"
        output += "mdat: \(mdatBox != nil ? "offset \(mdatBox!.offset), size \(mdatBox!.size)" : "Not found")\n"

        let tracks = parser.findAllBoxes(type: MP4BoxType.trak, in: boxes)
        output += "Tracks: \(tracks.count)\n"

        return output
    }

    // MARK: - Decoder (Phase 3)

    private func decodeFirstFrame() {
        isParsing = true
        parsingResult = "Decoding frames..."
        decodedImages = []

        Task {
            do {
                let result = try await performDecoding()
                await MainActor.run {
                    parsingResult = result.0
                    decodedImages = result.1
                    isParsing = false
                }
            } catch {
                await MainActor.run {
                    parsingResult = "Error: \(error)"
                    isParsing = false
                }
            }
        }
    }

    private func performDecoding() async throws -> (String, [CGImage]) {
        guard let url = Bundle.main.url(forResource: videoFileName, withExtension: videoFileExtension) else {
            return ("Error: demo.mp4 not found in bundle", [])
        }

        let reader = try FileByteRangeReader(url: url)
        let demuxer = MP4Demuxer(reader: reader)

        try demuxer.parse()

        guard let trackInfo = demuxer.videoTrackInfo else {
            return ("Error: No video track found", [])
        }

        var output = "=== Video Decoder Test ===\n"
        output += "Codec: \(trackInfo.codecType.string)\n"
        output += "Dimensions: \(trackInfo.width)x\(trackInfo.height)\n"
        output += "Samples: \(trackInfo.sampleCount)\n\n"

        // Create decoder
        let decoder = VideoDecoder(trackInfo: trackInfo)
        try decoder.configure()
        output += "Decoder configured successfully\n\n"

        // Find first keyframe
        guard let sampleTable = demuxer.sampleTable,
              let firstKeyframeIndex = sampleTable.samples.firstIndex(where: { $0.flags.isKeyFrame }) else {
            return (output + "Error: No keyframe found", [])
        }

        output += "First keyframe at index \(firstKeyframeIndex)\n"
        output += "Decoding 5 frames in decode order...\n\n"

        // Decode up to 5 frames starting from first keyframe
        let maxFrames = 5
        let endIndex = min(firstKeyframeIndex + maxFrames, sampleTable.count)
        var decodedFrames: [(index: Int, frame: DecodedFrame)] = []

        for i in firstKeyframeIndex..<endIndex {
            let sample = sampleTable.samples[i]
            let sampleData = try demuxer.readSample(at: i)

            let isKey = sample.flags.isKeyFrame ? "K" : "-"
            output += "[\(i)] \(isKey) dts=\(sample.decodeTime) pts=\(sample.presentationTime)"

            if let decodedFrame = try decoder.decode(sampleData: sampleData, sample: sample) {
                decodedFrames.append((index: i, frame: decodedFrame))
                output += " -> decoded\n"
            } else {
                output += " -> pending\n"
            }
        }

        // Flush decoder to get any remaining frames
        decoder.flush()

        output += "\nDecoded \(decodedFrames.count) frames total\n"

        // Sort by decode time
        let sortedFrames = decodedFrames.sorted { $0.frame.decodeTime < $1.frame.decodeTime }

        // Convert all frames to CGImages
        var images: [CGImage] = []
        for (idx, item) in sortedFrames.enumerated() {
            let dts = item.frame.decodeTime.seconds
            let pts = item.frame.presentationTime.seconds
            output += "Frame \(idx): dts=\(String(format: "%.3f", dts))s pts=\(String(format: "%.3f", pts))s"

            if let cgImage = createCGImage(from: item.frame.pixelBuffer) {
                images.append(cgImage)
                output += " -> converted\n"
            } else {
                output += " -> failed\n"
            }
        }

        return (output, images)
    }

    /// Convert CVPixelBuffer to CGImage for display
    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        return context.createCGImage(ciImage, from: rect)
    }

    // MARK: - Metal Renderer (Phase 4)

    private func decodeWithMetal() {
        isParsing = true
        parsingResult = "Decoding frames for Metal rendering..."
        decodedPixelBuffers = []

        Task {
            do {
                let result = try await performMetalDecoding()
                await MainActor.run {
                    parsingResult = result.0
                    decodedPixelBuffers = result.1
                    isParsing = false
                }
            } catch {
                await MainActor.run {
                    parsingResult = "Error: \(error)"
                    isParsing = false
                }
            }
        }
    }

    private func performMetalDecoding() async throws -> (String, [CVPixelBuffer]) {
        guard let url = Bundle.main.url(forResource: videoFileName, withExtension: videoFileExtension) else {
            return ("Error: demo.mp4 not found in bundle", [])
        }

        let reader = try FileByteRangeReader(url: url)
        let demuxer = MP4Demuxer(reader: reader)

        try demuxer.parse()

        guard let trackInfo = demuxer.videoTrackInfo else {
            return ("Error: No video track found", [])
        }

        var output = "=== Metal Renderer Test ===\n"
        output += "Codec: \(trackInfo.codecType.string)\n"
        output += "Dimensions: \(trackInfo.width)x\(trackInfo.height)\n"
        output += "Samples: \(trackInfo.sampleCount)\n\n"

        // Create decoder
        let decoder = VideoDecoder(trackInfo: trackInfo)
        try decoder.configure()
        output += "Decoder configured\n"

        // Find first keyframe
        guard let sampleTable = demuxer.sampleTable,
              let firstKeyframeIndex = sampleTable.samples.firstIndex(where: { $0.flags.isKeyFrame }) else {
            return (output + "Error: No keyframe found", [])
        }

        output += "Decoding 5 frames for Metal rendering...\n\n"

        // Decode up to 5 frames
        let maxFrames = 5
        let endIndex = min(firstKeyframeIndex + maxFrames, sampleTable.count)
        var pixelBuffers: [CVPixelBuffer] = []

        for i in firstKeyframeIndex..<endIndex {
            let sample = sampleTable.samples[i]
            let sampleData = try demuxer.readSample(at: i)

            let isKey = sample.flags.isKeyFrame ? "K" : "-"
            output += "[\(i)] \(isKey) dts=\(sample.decodeTime) pts=\(sample.presentationTime)"

            if let decodedFrame = try decoder.decode(sampleData: sampleData, sample: sample) {
                pixelBuffers.append(decodedFrame.pixelBuffer)
                output += " -> decoded\n"
            } else {
                output += " -> pending\n"
            }
        }

        decoder.flush()

        output += "\nDecoded \(pixelBuffers.count) frames\n"
        output += "Rendering with Metal (YUV->RGB shader)\n"
        output += "Pixel format: 420YpCbCr8BiPlanarVideoRange\n"

        return (output, pixelBuffers)
    }

    // MARK: - Buffer Manager (Phase 5)

    private func testBufferManager() {
        isParsing = true
        parsingResult = "Testing buffer manager..."
        decodedPixelBuffers = []

        Task {
            do {
                let result = try await performBufferTest()
                await MainActor.run {
                    parsingResult = result.0
                    decodedPixelBuffers = result.1
                    isParsing = false
                }
            } catch {
                await MainActor.run {
                    parsingResult = "Error: \(error)"
                    isParsing = false
                }
            }
        }
    }

    private func performBufferTest() async throws -> (String, [CVPixelBuffer]) {
        guard let url = Bundle.main.url(forResource: videoFileName, withExtension: videoFileExtension) else {
            return ("Error: demo.mp4 not found in bundle", [])
        }

        let reader = try FileByteRangeReader(url: url)
        let demuxer = MP4Demuxer(reader: reader)

        try demuxer.parse()

        guard let trackInfo = demuxer.videoTrackInfo else {
            return ("Error: No video track found", [])
        }

        var output = "=== Buffer Manager Test ===\n"
        output += "Video: \(trackInfo.width)x\(trackInfo.height)\n"
        output += "Samples: \(trackInfo.sampleCount)\n"
        output += "Duration: \(String(format: "%.2f", Double(trackInfo.duration) / Double(trackInfo.timescale)))s\n"
        output += "Timescale: \(trackInfo.timescale)\n\n"

        output += "Buffer Config:\n"
        output += "  Target: \(BufferConfig.targetSeconds)s\n"
        output += "  Low threshold: \(BufferConfig.lowThresholdSeconds)s\n\n"

        // Create decoder and buffer manager
        let decoder = VideoDecoder(trackInfo: trackInfo)
        try decoder.configure()

        let bufferManager = BufferManager(demuxer: demuxer, decoder: decoder)

        output += "Starting buffer fill from t=0...\n"

        // Fill buffer from start
        await bufferManager.start()

        // Get buffer status
        let status = await bufferManager.getBufferStatus(currentTime: .zero)
        output += "After fill: \(status)\n"
        output += "State: \(bufferManager.state)\n\n"

        // Simulate draining some frames
        output += "Simulating playback (dequeue 10 frames)...\n"
        var dequeuedFrames: [CVPixelBuffer] = []
        var currentTime = CMTime.zero

        for i in 0..<10 {
            if let frame = await bufferManager.dequeueFrame(for: currentTime) {
                dequeuedFrames.append(frame.pixelBuffer)
                output += "  [\(i)] Dequeued frame \(frame.sampleIndex), pts=\(String(format: "%.3f", frame.presentationTime.seconds))s\n"
                currentTime = frame.presentationTime + CMTime(value: 1, timescale: 30)
            } else {
                output += "  [\(i)] No frame available\n"
            }
        }

        // Check buffer status after drain
        let statusAfter = await bufferManager.getBufferStatus(currentTime: currentTime)
        output += "\nAfter drain: \(statusAfter)\n"

        // Test refill
        output += "\nChecking if refill needed...\n"
        let shouldFetch = await bufferManager.frameBuffer.shouldFetch(currentTime: currentTime)
        output += "Should fetch: \(shouldFetch)\n"

        if shouldFetch {
            output += "Triggering refill...\n"
            await bufferManager.fillBuffer(currentTime: currentTime)
            let statusRefill = await bufferManager.getBufferStatus(currentTime: currentTime)
            output += "After refill: \(statusRefill)\n"
        }

        output += "\nBuffer test complete!\n"
        output += "Dequeued \(dequeuedFrames.count) frames for display\n"

        // Return first 5 frames for Metal display
        let displayBuffers = Array(dequeuedFrames.prefix(5))
        return (output, displayBuffers)
    }

    // MARK: - Demuxer (Phase 2)

    private func parseDemuxer() {
        isParsing = true
        parsingResult = "Running demuxer..."

        Task {
            do {
                let result = try await performDemuxing()
                await MainActor.run {
                    parsingResult = result
                    isParsing = false
                }
            } catch {
                await MainActor.run {
                    parsingResult = "Error: \(error)"
                    isParsing = false
                }
            }
        }
    }

    private func performDemuxing() async throws -> String {
        guard let url = Bundle.main.url(forResource: videoFileName, withExtension: videoFileExtension) else {
            return "Error: demo.mp4 not found in bundle"
        }

        let reader = try FileByteRangeReader(url: url)
        let demuxer = MP4Demuxer(reader: reader)

        try demuxer.parse()

        var output = demuxer.summaryString()

        // Show sample table info
        if let sampleTable = demuxer.sampleTable, sampleTable.count > 0 {
            output += "\n--- Sample Table Info ---\n"
            output += "timescale=\(sampleTable.timescale)\n"
            output += "mediaTimeOffset=\(demuxer.mediaTimeOffset)\n"
            output += "total_samples=\(sampleTable.count)\n"

            // Show up to 100 frames with detailed info (compact format)
            output += "\n--- Frames (up to 100) ---\n"
            output += "# pts dts time K off size\n"

            for i in 0..<min(100, sampleTable.count) {
                if let sample = sampleTable[i] {
                    let ptsTime = Double(sample.presentationTime) / Double(sampleTable.timescale)
                    let k = sample.flags.isKeyFrame ? "K" : "-"

                    output += "\(i) \(sample.presentationTime) \(sample.decodeTime) \(String(format: "%.2f", ptsTime)) \(k) \(sample.offset) \(sample.size)\n"
                }
            }

            // Show keyframe summary
            output += "\n--- Keyframe Summary ---\n"
            let keyframes = sampleTable.samples.enumerated().filter { $0.element.flags.isKeyFrame }
            output += "Total keyframes: \(keyframes.count)\n"
            if keyframes.count > 0 {
                output += "Keyframe indices: \(keyframes.prefix(20).map { String($0.offset) }.joined(separator: ", "))"
                if keyframes.count > 20 {
                    output += "..."
                }
                output += "\n"
            }
        }

        return output
    }
}

#Preview {
    ContentView()
}
