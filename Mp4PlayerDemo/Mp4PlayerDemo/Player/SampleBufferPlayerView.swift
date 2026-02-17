import SwiftUI
import AVFoundation

/// UIView subclass that keeps its sublayer sized to bounds.
class DisplayLayerHostView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // CALayer doesn't auto-resize with UIView; update on every layout pass.
        displayLayer.frame = bounds
    }
}

/// UIViewRepresentable that hosts an AVSampleBufferDisplayLayer.
struct SampleBufferPlayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> DisplayLayerHostView {
        DisplayLayerHostView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: DisplayLayerHostView, context: Context) {}
}
