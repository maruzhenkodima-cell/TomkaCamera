import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = { layerPoint, viewSize in
            let devicePoint = view.previewLayer.captureDevicePointConverted(
                fromLayerPoint: layerPoint
            )
            let displayPoint = CGPoint(
                x: min(1, max(0, layerPoint.x / max(viewSize.width, 1))),
                y: min(1, max(0, layerPoint.y / max(viewSize.height, 1)))
            )
            onFocus(devicePoint, displayPoint)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.onTap = { layerPoint, viewSize in
            let devicePoint = uiView.previewLayer.captureDevicePointConverted(
                fromLayerPoint: layerPoint
            )
            let displayPoint = CGPoint(
                x: min(1, max(0, layerPoint.x / max(viewSize.width, 1))),
                y: min(1, max(0, layerPoint.y / max(viewSize.height, 1)))
            )
            onFocus(devicePoint, displayPoint)
        }
    }
}

final class PreviewView: UIView {
    var onTap: ((CGPoint, CGSize) -> Void)?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        onTap?(point, bounds.size)
    }
}
