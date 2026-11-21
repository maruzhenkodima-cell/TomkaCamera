import AVFoundation
import Combine
import Photos
import UIKit

final class CameraManager: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "tomka.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var cameraDevice: AVCaptureDevice?
    private var isConfigured = false

    // These values are read and written only on sessionQueue.
    private var currentISO: Double = 100
    private var currentShutterPosition: Double = 0.65
    private var currentFocusPosition: Double = 0.5
    private var currentTemperature: Double = 5000

    @Published var isAuthorized = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var capturedImage: UIImage?
    @Published var isCapturing = false
    @Published var isSavingPhoto = false

    @Published var zoomFactor: CGFloat = 1.0
    @Published var maxZoomFactor: CGFloat = 10.0

    @Published var isoValue: Double = 100
    @Published var minISO: Double = 25
    @Published var maxISO: Double = 1600
    @Published var shutterPosition: Double = 0.65
    @Published var minShutterSeconds: Double = 1.0 / 10000.0
    @Published var maxShutterSeconds: Double = 1.0 / 4.0
    @Published var focusPosition: Double = 0.5
    @Published var colorTemperature: Double = 5000

    var shutterSpeedLabel: String {
        let minimum = max(minShutterSeconds, 0.00001)
        let maximum = max(maxShutterSeconds, minimum)
        let seconds = minimum * pow(maximum / minimum, shutterPosition)

        if seconds >= 1 {
            return String(format: "%.1f s", seconds)
        }

        return String(format: "1/%d s", max(1, Int((1.0 / seconds).rounded())))
    }

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
                self.publishError("Основная камера не найдена.")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)

                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    self.publishError("Не удалось подключить основную камеру.")
                    return
                }
                self.session.addInput(input)

                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    self.publishError("Не удалось подключить модуль фотосъёмки.")
                    return
                }
                self.session.addOutput(self.photoOutput)

                // Request the largest still-photo dimensions supported by this active format.
                if let dimensions = camera.activeFormat.supportedMaxPhotoDimensions.max(by: {
                    Int64($0.width) * Int64($0.height) <
                    Int64($1.width) * Int64($1.height)
                }) {
                    self.photoOutput.maxPhotoDimensions = dimensions
                }

                self.photoOutput.maxPhotoQualityPrioritization = .quality

                self.cameraDevice = camera
                self.currentISO = Double(camera.iso)
                self.currentFocusPosition = Double(camera.lensPosition)

                let supportedZoom = min(CGFloat(10.0), camera.activeFormat.videoMaxZoomFactor)
                let minimumISO = Double(camera.activeFormat.minISO)
                let maximumISO = Double(camera.activeFormat.maxISO)

                let minimumShutter = max(
                    1.0 / 10000.0,
                    camera.activeFormat.minExposureDuration.seconds
                )
                let maximumShutter = max(
                    minimumShutter,
                    min(1.0, camera.activeFormat.maxExposureDuration.seconds)
                )

                let currentDuration = max(
                    minimumShutter,
                    min(maximumShutter, camera.exposureDuration.seconds)
                )
                let shutterPosition: Double
                if maximumShutter > minimumShutter {
                    shutterPosition = log(currentDuration / minimumShutter) /
                        log(maximumShutter / minimumShutter)
                } else {
                    shutterPosition = 0.5
                }

                let temperatureAndTint = camera.temperatureAndTintValues(
                    for: camera.deviceWhiteBalanceGains
                )
                self.currentTemperature = Double(temperatureAndTint.temperature)

                DispatchQueue.main.async {
                    self.maxZoomFactor = max(1.0, supportedZoom)
                    self.minISO = minimumISO
                    self.maxISO = max(minimumISO + 1, maximumISO)
                    self.isoValue = self.currentISO
                    self.minShutterSeconds = minimumShutter
                    self.maxShutterSeconds = maximumShutter
                    self.shutterPosition = min(1.0, max(0.0, shutterPosition))
                    self.focusPosition = self.currentFocusPosition
                    self.colorTemperature = self.currentTemperature
                }

                self.isConfigured = true
                self.session.commitConfiguration()
                self.session.startRunning()
            } catch {
                self.session.commitConfiguration()
                self.publishError(error.localizedDescription)
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
                self.publishError("Не удалось изменить увеличение: \(error.localizedDescription)")
            }
        }
    }

    func setISO(_ value: Double) {
        sessionQueue.async {
            guard let camera = self.cameraDevice else { return }

            let newISO = min(
                Double(camera.activeFormat.maxISO),
                max(Double(camera.activeFormat.minISO), value)
            )
            let duration = self.exposureDuration(
                for: self.currentShutterPosition,
                on: camera
            )

            guard self.applyExposure(iso: newISO, duration: duration, on: camera) else {
                return
            }

            self.currentISO = newISO
            DispatchQueue.main.async {
                self.isoValue = newISO
            }
        }
    }

    func setShutterPosition(_ position: Double) {
        sessionQueue.async {
            guard let camera = self.cameraDevice else { return }

            let clampedPosition = min(1.0, max(0.0, position))
            let duration = self.exposureDuration(for: clampedPosition, on: camera)

            guard self.applyExposure(
                iso: self.currentISO,
                duration: duration,
                on: camera
            ) else {
                return
            }

            self.currentShutterPosition = clampedPosition
            DispatchQueue.main.async {
                self.shutterPosition = clampedPosition
            }
        }
    }

    private func exposureDuration(
        for position: Double,
        on camera: AVCaptureDevice
    ) -> Double {
        let minimum = max(
            1.0 / 10000.0,
            camera.activeFormat.minExposureDuration.seconds
        )
        let maximum = max(
            minimum,
            min(1.0, camera.activeFormat.maxExposureDuration.seconds)
        )

        guard maximum > minimum else { return minimum }
        return minimum * pow(maximum / minimum, min(1.0, max(0.0, position)))
    }

    private func applyExposure(
        iso: Double,
        duration: Double,
        on camera: AVCaptureDevice
    ) -> Bool {
        guard camera.isExposureModeSupported(.custom) else {
            publishError("Ручная выдержка и ISO не поддерживаются этим режимом камеры.")
            return false
        }

        do {
            try camera.lockForConfiguration()
            camera.setExposureModeCustom(
                duration: CMTime(seconds: duration, preferredTimescale: 1_000_000),
                iso: Float(iso),
                completionHandler: nil
            )
            camera.unlockForConfiguration()
            return true
        } catch {
            publishError("Не удалось настроить экспозицию: \(error.localizedDescription)")
            return false
        }
    }

    func setFocus(_ position: Double) {
        sessionQueue.async {
            guard let camera = self.cameraDevice,
                  camera.isFocusModeSupported(.locked) else {
                self.publishError("Ручная фокусировка недоступна.")
                return
            }

            let value = min(1.0, max(0.0, position))

            do {
                try camera.lockForConfiguration()
                camera.setFocusModeLocked(
                    lensPosition: Float(value),
                    completionHandler: nil
                )
                camera.unlockForConfiguration()

                self.currentFocusPosition = value
                DispatchQueue.main.async {
                    self.focusPosition = value
                }
            } catch {
                self.publishError("Не удалось настроить фокус: \(error.localizedDescription)")
            }
        }
    }

    func setColorTemperature(_ temperature: Double) {
        sessionQueue.async {
            guard let camera = self.cameraDevice,
                  camera.isWhiteBalanceModeSupported(.locked) else {
                self.publishError("Ручной баланс белого недоступен.")
                return
            }

            let value = min(8000.0, max(2500.0, temperature))
            let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: Float(value),
                tint: 0
            )
            let gains = camera.deviceWhiteBalanceGains(for: temperatureAndTint)
            let maximumGain = camera.maxWhiteBalanceGain

            let clampedGains = AVCaptureDevice.WhiteBalanceGains(
                redGain: min(max(gains.redGain, 1.0), maximumGain),
                greenGain: min(max(gains.greenGain, 1.0), maximumGain),
                blueGain: min(max(gains.blueGain, 1.0), maximumGain)
            )

            do {
                try camera.lockForConfiguration()
                camera.setWhiteBalanceModeLocked(
                    with: clampedGains,
                    completionHandler: nil
                )
                camera.unlockForConfiguration()

                self.currentTemperature = value
                DispatchQueue.main.async {
                    self.colorTemperature = value
                }
            } catch {
                self.publishError("Не удалось настроить баланс белого: \(error.localizedDescription)")
            }
        }
    }

    func enableAutomaticControls() {
        sessionQueue.async {
            guard let camera = self.cameraDevice else { return }

            do {
                try camera.lockForConfiguration()

                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }

                camera.unlockForConfiguration()

                self.currentISO = Double(camera.iso)
                self.currentFocusPosition = Double(camera.lensPosition)

                DispatchQueue.main.async {
                    self.isoValue = self.currentISO
                    self.focusPosition = self.currentFocusPosition
                    self.statusMessage = "Автоматические настройки включены"
                }
            } catch {
                self.publishError("Не удалось включить автоматику: \(error.localizedDescription)")
            }
        }
    }

    func takePhoto() {
        sessionQueue.async {
            guard self.session.isRunning else { return }

            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions

            DispatchQueue.main.async {
                self.isCapturing = true
                self.statusMessage = nil
                self.errorMessage = nil
            }

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
                self.isCapturing = false
                self.errorMessage = error.localizedDescription
            }
            return
        }

        guard
            let data = photo.fileDataRepresentation(),
            let image = UIImage(data: data)
        else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.errorMessage = "Не удалось обработать полученный снимок."
            }
            return
        }

        DispatchQueue.main.async {
            self.capturedImage = image
            self.isCapturing = false
        }

        savePhotoToLibrary(data)
    }

    private func savePhotoToLibrary(_ data: Data) {
        DispatchQueue.main.async {
            self.isSavingPhoto = true
            self.statusMessage = "Сохраняю снимок в Фото…"
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized:
            performPhotoSave(data)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                guard let self else { return }
                if status == .authorized {
                    self.performPhotoSave(data)
                } else {
                    self.finishPhotoSave(
                        success: false,
                        message: "Нет разрешения сохранять фото. Проверьте настройки приватности."
                    )
                }
            }
        default:
            finishPhotoSave(
                success: false,
                message: "Нет разрешения сохранять фото. Проверьте настройки приватности."
            )
        }
    }

    private func performPhotoSave(_ data: Data) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }) { [weak self] success, error in
            if success {
                self?.finishPhotoSave(
                    success: true,
                    message: "Снимок сохранён в приложении Фото"
                )
            } else {
                self?.finishPhotoSave(
                    success: false,
                    message: error?.localizedDescription ?? "Не удалось сохранить снимок."
                )
            }
        }
    }

    private func finishPhotoSave(success: Bool, message: String) {
        DispatchQueue.main.async {
            self.isSavingPhoto = false
            self.statusMessage = success ? message : nil
            self.errorMessage = success ? nil : message
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
        }
    }
}
