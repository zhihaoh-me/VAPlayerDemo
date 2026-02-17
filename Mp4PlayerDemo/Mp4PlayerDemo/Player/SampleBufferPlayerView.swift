import SwiftUI
import AVFoundation

/// UIViewRepresentable that hosts an AVSampleBufferDisplayLayer.
struct SampleBufferPlayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(displayLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        displayLayer.frame = uiView.bounds
    }
}
