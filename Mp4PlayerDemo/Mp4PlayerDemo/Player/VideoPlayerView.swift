import SwiftUI
import MetalKit
import CoreVideo
import os

/// SwiftUI wrapper for Metal-based video rendering
struct VideoPlayerView: UIViewRepresentable {
    /// The pixel buffer to display
    let pixelBuffer: CVPixelBuffer?

    /// The Metal renderer
    let renderer: MetalRenderer

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.backgroundColor = .black
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true  // We'll manually trigger draws

        do {
            try renderer.configure(with: mtkView)
        } catch {
            Log.renderer.error("Failed to configure Metal renderer: \(error)")
        }

        return mtkView
    }

    func updateUIView(_ mtkView: MTKView, context: Context) {
        // Update the renderer's pixel buffer
        renderer.currentPixelBuffer = pixelBuffer

        // Trigger a redraw
        mtkView.setNeedsDisplay()
    }
}

/// A view that displays multiple frames using Metal rendering
struct MultiFrameMetalView: View {
    let pixelBuffers: [CVPixelBuffer]
    let renderer: MetalRenderer

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(pixelBuffers.enumerated()), id: \.offset) { index, buffer in
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
    }
}

/// A single frame rendered with Metal
struct SingleFrameMetalView: UIViewRepresentable {
    let pixelBuffer: CVPixelBuffer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.backgroundColor = .black
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true

        do {
            try context.coordinator.renderer.configure(with: mtkView)
        } catch {
            Log.renderer.error("Failed to configure Metal renderer: \(error)")
        }

        return mtkView
    }

    func updateUIView(_ mtkView: MTKView, context: Context) {
        context.coordinator.renderer.currentPixelBuffer = pixelBuffer
        mtkView.setNeedsDisplay()
    }

    class Coordinator {
        let renderer = MetalRenderer()
    }
}
