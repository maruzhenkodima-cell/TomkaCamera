import AVFoundation
import Combine
import UIKit

final class CameraManager: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "tomka.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var cameraDevice: AVCaptureDevice?
    private var isConfigured = false

    @Published var isAuthorized = false
    @Published var errorMessage: String?
    @Published var capturedImage: UIImage?
    @Published var zoomFactor: CGFloat = 1.0
    @Published var maxZoomFactor: CGFloat = 10.0

    func requestPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async {
                self.isAuthorized = true
            }
            configure()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                    if !granted {
                        self?.errorMessage = "Разрешите доступ к камере в настройках iPhone."
                    }
                }
                if granted {
                    self?.configure()
                }
            }

        default:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.errorMessage = "Разрешите доступ к камере в настройках iPhone."
            }
        }
    }

    private func configure() {
        sessionQueue.async {
            guard !self.isConfigured else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.errorMessage = "Основная камера не найдена."
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)

                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(input)

                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    return
                }
                self.session.addOutput(self.photoOutput)

                self.cameraDevice = camera
                let supportedZoom = min(CGFloat(10.0), camera.activeFormat.videoMaxZoomFactor)
                DispatchQueue.main.async {
                    self.maxZoomFactor = max(1.0, supportedZoom)
                }

                self.isConfigured = true
                self.session.commitConfiguration()
                self.session.startRunning()
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async {
            guard let camera = self.cameraDevice else { return }

            let deviceMaximum = min(CGFloat(10.0), camera.activeFormat.videoMaxZoomFactor)
            let clampedFactor = max(1.0, min(factor, deviceMaximum))

            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = clampedFactor
                camera.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.zoomFactor = clampedFactor
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Не удалось изменить увеличение: \(error.localizedDescription)"
                }
            }
        }
    }

    func takePhoto() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
            }
            return
        }

        guard
            let data = photo.fileDataRepresentation(),
            let image = UIImage(data: data)
        else {
            return
        }

        DispatchQueue.main.async {
            self.capturedImage = image
        }
    }
}
