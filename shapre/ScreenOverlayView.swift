import SwiftUI
import MetalKit
import ScreenCaptureKit
import Combine
import CoreVideo

struct ShaderParams {
    var time: Float
    var screenSize: simd_float2
    var distortion_fac: simd_float2
    var scale_fac: simd_float2
    var feather_fac: Float
    var noise_fac: Float
    var bloom_fac: Float
    var crt_intensity: Float
    var glitch_intensity: Float
    var scanlines: Float
}

final class CaptureCoordinator: NSObject, ObservableObject, SCStreamOutput {
    @Published var latestFrame: CVPixelBuffer?
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "capture.queue")

    func start() async throws {
        let displays = try await SCShareableContent.current.displays
        guard let mainDisplay = displays.first else { 
            throw NSError(domain: "CaptureError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No displays found"])
        }

        let config = SCStreamConfiguration()
        config.width = mainDisplay.width * 2        config.height = mainDisplay.height * 2
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)        config.queueDepth = 5        
               let allWindows = try await SCShareableContent.current.windows
        let excludedWindows = allWindows.filter {
            OverlayWindowController.overlayWindowID != nil &&
            $0.windowID == OverlayWindowController.overlayWindowID
        }
        
               stream = SCStream(filter: SCContentFilter(display: mainDisplay, excludingWindows: excludedWindows),
                          configuration: config,
                          delegate: self)

        guard let stream = stream else {
            throw NSError(domain: "CaptureError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create stream"])
        }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
    }
    
    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
    }
}

extension CaptureCoordinator: SCStreamDelegate {
    @objc func stream(_ stream: SCStream,
                      didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                      of type: SCStreamOutputType) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        DispatchQueue.main.async { self.latestFrame = pixelBuffer }
    }
}

final class OptimizedMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let commandQueue: MTLCommandQueue
    private let sampler: MTLSamplerState
    private var cancellable: AnyCancellable?
    
       private var textureCache: CVMetalTextureCache?
    private var metalTexture: MTLTexture?
    
    init(view: MTKView, frames: Published<CVPixelBuffer?>.Publisher) {
        self.device = view.device!
        self.commandQueue = device.makeCommandQueue()!
        
               var cacheRef: CVMetalTextureCache?
        let cacheResult = CVMetalTextureCacheCreate(nil, nil, device, nil, &cacheRef)
        if cacheResult == kCVReturnSuccess {
            self.textureCache = cacheRef
        }
        
               let library = device.makeDefaultLibrary()!
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "passthroughVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "shader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        
               self.pipeline = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
               let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.mipFilter = .nearest
        self.sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
        
        super.init()
        
               cancellable = frames
            .compactMap { $0 }
            .sink { [weak self] pixelBuffer in
                self?.updateTexture(from: pixelBuffer)
            }
    }
    
    private func updateTexture(from pixelBuffer: CVPixelBuffer) {
        guard let textureCache = textureCache else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
               var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTextureOut
        )
        
        if status == kCVReturnSuccess, let cvTexture = cvTextureOut {
                       if let texture = CVMetalTextureGetTexture(cvTexture) {
                self.metalTexture = texture
            }
        }
    }
    
       func draw(in view: MTKView) {
        guard let texture = metalTexture,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
               var shaderParams = ShaderParams(
            time: Float(CACurrentMediaTime()),
            screenSize: simd_float2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            distortion_fac: simd_float2(1.0, 1.0),            scale_fac: simd_float2(1.0, 1.0),                 feather_fac: 0.0,                                 noise_fac: 0.0,                                   bloom_fac: 0.0,                                   crt_intensity: 0.0,                               glitch_intensity: 0.0,                            scanlines: 0.0                                )
        
               passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        
               guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&shaderParams, length: MemoryLayout<ShaderParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
           }
}

struct CapturedScreenMetalView: NSViewRepresentable {
    @StateObject private var captureCoordinator = CaptureCoordinator()
    
    class Coordinator {
        var renderer: OptimizedMetalRenderer?
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> MTKView {
               let metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 60        metalView.framebufferOnly = true        metalView.clearColor = MTLClearColor()        
               let renderer = OptimizedMetalRenderer(view: metalView, frames: captureCoordinator.$latestFrame)
        metalView.delegate = renderer
        context.coordinator.renderer = renderer
        
               Task { 
            do {
                try await captureCoordinator.start()
            } catch {
                print("Screen capture failed to start: \(error)")
            }
        }
        
        return metalView
    }
    
    func updateNSView(_ view: MTKView, context: Context) {
           }
}
