import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let zoomFactor: CGFloat
    let maxZoomFactor: CGFloat
    let onFocus: (CGPoint, CGPoint, Bool) -> Void
    let onZoom: (CGFloat) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.currentZoomFactor = zoomFactor
        view.maximumZoomFactor = maxZoomFactor
        view.onFocus = { layerPoint, viewSize, shouldLock in
            let devicePoint = view.previewLayer.captureDevicePointConverted(
                fromLayerPoint: layerPoint
            )
            let displayPoint = CGPoint(
                x: min(1, max(0, layerPoint.x / max(viewSize.width, 1))),
                y: min(1, max(0, layerPoint.y / max(viewSize.height, 1)))
            )
            onFocus(devicePoint, displayPoint, shouldLock)
        }
        view.onZoom = onZoom
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.currentZoomFactor = zoomFactor
        uiView.maximumZoomFactor = maxZoomFactor
        uiView.onFocus = { layerPoint, viewSize, shouldLock in
            let devicePoint = uiView.previewLayer.captureDevicePointConverted(
                fromLayerPoint: layerPoint
            )
            let displayPoint = CGPoint(
                x: min(1, max(0, layerPoint.x / max(viewSize.width, 1))),
                y: min(1, max(0, layerPoint.y / max(viewSize.height, 1)))
            )
            onFocus(devicePoint, displayPoint, shouldLock)
        }
        uiView.onZoom = onZoom
    }
}

final class PreviewView: UIView, UIGestureRecognizerDelegate {
    var onFocus: ((CGPoint, CGSize, Bool) -> Void)?
    var onZoom: ((CGFloat) -> Void)?

    var currentZoomFactor: CGFloat = 1
    var maximumZoomFactor: CGFloat = 15

    private var pinchStartZoom: CGFloat = 1
    private var lastPinchZoom: CGFloat = 1

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        backgroundColor = .black
        isUserInteractionEnabled = true
        previewLayer.videoGravity = .resizeAspectFill

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false

        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.55
        longPress.allowableMovement = 18
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false

        // A short tap focuses; holding the same point triggers AE/AF lock instead.
        tap.require(toFail: longPress)
        addGestureRecognizer(longPress)
        addGestureRecognizer(tap)

        // Pinch is handled by the preview view itself, not a SwiftUI gesture layered
        // over the full-screen representable. This keeps the zoom controls independent.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Let the pinch recognizer coexist only with recognizers needed for the preview.
        gestureRecognizer is UIPinchGestureRecognizer ||
            otherGestureRecognizer is UIPinchGestureRecognizer
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        onFocus?(point, bounds.size, false)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: self)
        onFocus?(point, bounds.size, true)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartZoom = currentZoomFactor
            lastPinchZoom = currentZoomFactor
        case .changed, .ended:
            let value = min(
                maximumZoomFactor,
                max(1, pinchStartZoom * recognizer.scale)
            )
            lastPinchZoom = value
            onZoom?(value)
            if recognizer.state == .ended {
                pinchStartZoom = value
            }
        case .cancelled, .failed:
            pinchStartZoom = lastPinchZoom
        default:
            break
        }
    }
}
