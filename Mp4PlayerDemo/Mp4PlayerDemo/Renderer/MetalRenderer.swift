import Foundation
import Metal
import MetalKit
import CoreVideo
import os

/// Errors that can occur during Metal rendering
enum MetalRendererError: Error {
    case deviceNotFound
    case commandQueueCreationFailed
    case textureCacheCreationFailed
    case libraryNotFound
    case pipelineCreationFailed(Error)
    case textureCreationFailed
}

/// Metal renderer for displaying CVPixelBuffer frames
final class MetalRenderer: NSObject {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?

    /// Vertex data for a full-screen quad
    private var vertexBuffer: MTLBuffer?

    /// Current pixel buffer to render
    var currentPixelBuffer: CVPixelBuffer?

    override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        self.commandQueue = commandQueue

        super.init()
    }

    /// Configure the renderer with an MTKView
    func configure(with view: MTKView) throws {
        view.device = device
        view.delegate = self
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm

        // Create texture cache
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let textureCache = cache else {
            throw MetalRendererError.textureCacheCreationFailed
        }
        self.textureCache = textureCache

        // Create render pipeline
        try createPipeline()

        // Create sampler state
        createSamplerState()

        // Create vertex buffer for full-screen quad
        createVertexBuffer()
    }

    private func createPipeline() throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.libraryNotFound
        }

        let vertexFunction = library.makeFunction(name: "vertexShader")
        let fragmentFunction = library.makeFunction(name: "fragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(error)
        }
    }

    private func createSamplerState() {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: samplerDescriptor)
    }

    private func createVertexBuffer() {
        // Full-screen quad vertices (position x, y, texCoord u, v)
        // Using triangle strip: 4 vertices for a quad
        let vertices: [Float] = [
            // Position      // TexCoord
            -1.0, -1.0,      0.0, 1.0,   // Bottom-left
             1.0, -1.0,      1.0, 1.0,   // Bottom-right
            -1.0,  1.0,      0.0, 0.0,   // Top-left
             1.0,  1.0,      1.0, 0.0,   // Top-right
        ]

        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    /// Create Metal textures from a CVPixelBuffer
    /// Returns (Y texture, CbCr texture) for YUV format
    private func createTextures(from pixelBuffer: CVPixelBuffer) -> (MTLTexture, MTLTexture)? {
        guard let textureCache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Create Y texture (luminance plane)
        var yTexture: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,  // Y plane is single channel
            width,
            height,
            0,  // Plane index 0 = Y
            &yTexture
        )

        guard yStatus == kCVReturnSuccess, let yTex = yTexture else {
            Log.renderer.error("Failed to create Y texture: \(yStatus)")
            return nil
        }

        // Create CbCr texture (chrominance plane)
        var cbcrTexture: CVMetalTexture?
        let cbcrStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,  // CbCr plane is two channels interleaved
            width / 2,   // Chroma is half resolution
            height / 2,
            1,  // Plane index 1 = CbCr
            &cbcrTexture
        )

        guard cbcrStatus == kCVReturnSuccess, let cbcrTex = cbcrTexture else {
            Log.renderer.error("Failed to create CbCr texture: \(cbcrStatus)")
            return nil
        }

        guard let yMTLTexture = CVMetalTextureGetTexture(yTex),
              let cbcrMTLTexture = CVMetalTextureGetTexture(cbcrTex) else {
            return nil
        }

        return (yMTLTexture, cbcrMTLTexture)
    }
}

// MARK: - MTKViewDelegate

extension MetalRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle resize if needed
    }

    func draw(in view: MTKView) {
        guard let pixelBuffer = currentPixelBuffer,
              let pipelineState = pipelineState,
              let vertexBuffer = vertexBuffer,
              let samplerState = samplerState,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        // Create textures from pixel buffer
        guard let (yTexture, cbcrTexture) = createTextures(from: pixelBuffer) else {
            return
        }

        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(yTexture, index: 0)
        renderEncoder.setFragmentTexture(cbcrTexture, index: 1)
        renderEncoder.setFragmentSamplerState(samplerState, index: 0)

        // Draw the quad
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
