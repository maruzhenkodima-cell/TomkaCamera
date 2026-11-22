import AVFoundation
import Combine
import Photos
import UIKit

enum CameraFlashMode: String, CaseIterable, Identifiable {
    case off
    case auto
    case on

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Выкл."
        case .auto: return "Авто"
        case .on: return "Вкл."
        }
    }

    var captureMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }
}

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "tomka.camera.session")
    private let processingQueue = DispatchQueue(
        label: "tomka.camera.processing",
        qos: .userInitiated
    )
    private let diagnostics = CaptureDiagnosticsStore()
    private let photoOutput = AVCapturePhotoOutput()

    private var cameraDevice: AVCaptureDevice?
    // Stored without an availability annotation; cast only inside an iOS 17+ check.
    private var rotationCoordinator: AnyObject?
    private var burstPhotoDimensions: CMVideoDimensions?
    private var isConfigured = false
    private var captureDelegates: [Int64: PhotoFrameCaptureDelegate] = [:]
    private var pendingBurstFrames: [Data] = []
    private var requestedBurstCount = 1
    private var isBurstRunning = false
    private var burstUsesProRAW = false
    private var pendingRawPhotoData: Data?
    private var burstFlashMode: AVCaptureDevice.FlashMode = .off
    private var savedBurstModes: SavedAutomaticModes?
    private var shouldRunSession = true
    private var sessionObservers: [NSObjectProtocol] = []
    // Accessed only on sessionQueue; invalidates delayed locks after a newer tap.
    private var focusOperationID = UUID()

    private struct SavedAutomaticModes {
        let exposure: AVCaptureDevice.ExposureMode?
        let focus: AVCaptureDevice.FocusMode?
        let whiteBalance: AVCaptureDevice.WhiteBalanceMode?
    }

    // These values are read and written only on sessionQueue.
    private var currentISO: Double = 100
    private var currentShutterPosition: Double = 0.65
    private var currentFocusPosition: Double = 0.5
    private var currentTemperature: Double = 5000
    private var currentExposureBias: Double = 0

    @Published var isAuthorized = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var capturedImage: UIImage?
    @Published var originalCapturedImage: UIImage?
    @Published var isCapturing = false
    @Published var isSavingPhoto = false
    @Published var mergedFrameCount = 1
    @Published var processingDescription = ""

    // Single-shot capture is the safest default for the first public beta.
    @Published var multiFrameEnabled = false
    @Published var flashMode: CameraFlashMode = .off
    @Published var availableFlashModes: [CameraFlashMode] = [.off]
    @Published var hasFlash = false
    @Published var proRAWAvailable = false
    @Published var useProRAW = false
    @Published var showCompositionGrid = true
    @Published var focusIndicatorPoint: CGPoint?
    @Published var isFocusExposureLocked = false
    @Published var zoomFactor: CGFloat = 1.0
    @Published var maxZoomFactor: CGFloat = 15.0

    @Published var isoValue: Double = 100
    @Published var minISO: Double = 25
    @Published var maxISO: Double = 1600
    @Published var shutterPosition: Double = 0.65
    @Published var minShutterSeconds: Double = 1.0 / 10000.0
    @Published var maxShutterSeconds: Double = 1.0 / 4.0
    @Published var focusPosition: Double = 0.5
    @Published var colorTemperature: Double = 5000
    @Published var exposureBias: Double = 0
    @Published var minExposureBias: Double = -2
    @Published var maxExposureBias: Double = 2

    @Published var isExposureManual = false
    @Published var isFocusManual = false
    @Published var isWhiteBalanceManual = false

    // Keep capture modes mutually exclusive and update the UI state immediately.
    func setMultiFrameEnabled(_ enabled: Bool) {
        multiFrameEnabled = enabled && !useProRAW && flashMode == .off
    }

    func setProRAWEnabled(_ enabled: Bool) {
        useProRAW = enabled && proRAWAvailable
        if useProRAW {
            multiFrameEnabled = false
        }
    }

    func setFlashMode(_ mode: CameraFlashMode) {
        flashMode = mode
        if mode != .off {
            multiFrameEnabled = false
        }
    }

    override init() {
        super.init()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        installSessionObservers()
    }

    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        let captureSession = session
        let queue = sessionQueue
        queue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    private func installSessionObservers() {
        let center = NotificationCenter.default

        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.statusMessage = "Камера временно приостановлена системой."
        })

        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.statusMessage = nil
            self?.restartSessionIfNeeded()
        })

        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError

            if error?.code == .mediaServicesWereReset {
                self.statusMessage = "Восстанавливаю камеру…"
                self.restartSessionIfNeeded()
            } else {
                self.errorMessage = error?.localizedDescription
                    ?? "Произошла ошибка работы камеры."
            }
        })
    }

    func setSessionActive(_ active: Bool) {
        sessionQueue.async {
            self.shouldRunSession = active

            if active {
                if self.isConfigured && !self.session.isRunning {
                    self.session.startRunning()
                }
            } else if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func restartSessionIfNeeded() {
        sessionQueue.async {
            guard self.shouldRunSession, self.isConfigured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func exportDiagnostics() -> URL? {
        diagnostics.exportJSON()
    }

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

                // Enable Apple's content-aware lens correction before startRunning.
                // It corrects wide-angle edge distortion while preserving natural-looking
                // subjects; the system may make a small scene-dependent FOV adjustment.
                if self.photoOutput.isContentAwareDistortionCorrectionSupported {
                    self.photoOutput.isContentAwareDistortionCorrectionEnabled = true
                }

                // Use the largest supported size for single shots and ProRAW.
                // Three full-resolution frames can use a lot of memory, so burst capture
                // uses the largest supported size up to 16 MP (or the smallest available size).
                let supportedDimensions = camera.activeFormat.supportedMaxPhotoDimensions
                let pixelCount: (CMVideoDimensions) -> Int64 = {
                    Int64($0.width) * Int64($0.height)
                }
                let maximumDimensions = supportedDimensions.max {
                    pixelCount($0) < pixelCount($1)
                }
                let burstCandidates = supportedDimensions.filter {
                    pixelCount($0) <= 16_000_000
                }
                self.burstPhotoDimensions = burstCandidates.max {
                    pixelCount($0) < pixelCount($1)
                } ?? supportedDimensions.min {
                    pixelCount($0) < pixelCount($1)
                }

                if let maximumDimensions {
                    self.photoOutput.maxPhotoDimensions = maximumDimensions
                }

                self.photoOutput.maxPhotoQualityPrioritization = .quality

                // Enable ProRAW before startRunning, as recommended by Apple.
                let proRAWSupported = self.photoOutput.isAppleProRAWSupported
                if proRAWSupported {
                    self.photoOutput.isAppleProRAWEnabled = true
                }
                let proRAWAvailable = self.photoOutput.availableRawPhotoPixelFormatTypes.contains {
                    AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
                }

                self.cameraDevice = camera

                // Start in continuous autofocus, auto exposure, and auto white balance.
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                camera.isSubjectAreaChangeMonitoringEnabled = true
                camera.unlockForConfiguration()

                if #available(iOS 17.0, *) {
                    self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                        device: camera,
                        previewLayer: nil
                    )
                }
                self.currentISO = Double(camera.iso)
                self.currentFocusPosition = Double(camera.lensPosition)

                let supportedZoom = min(CGFloat(15.0), camera.activeFormat.videoMaxZoomFactor)
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
                let initialShutterPosition: Double
                if maximumShutter > minimumShutter {
                    initialShutterPosition = log(currentDuration / minimumShutter) /
                        log(maximumShutter / minimumShutter)
                } else {
                    initialShutterPosition = 0.5
                }
                self.currentShutterPosition = initialShutterPosition

                let temperatureAndTint = camera.temperatureAndTintValues(
                    for: camera.deviceWhiteBalanceGains
                )
                self.currentTemperature = Double(temperatureAndTint.temperature)
                self.currentExposureBias = Double(camera.exposureTargetBias)

                let minimumExposureBias = Double(camera.minExposureTargetBias)
                let maximumExposureBias = Double(camera.maxExposureTargetBias)

                DispatchQueue.main.async {
                    self.proRAWAvailable = proRAWAvailable
                    let supportedFlashModes = self.photoOutput.supportedFlashModes
                    var availableModes: [CameraFlashMode] = [.off]
                    if supportedFlashModes.contains(.auto) {
                        availableModes.append(.auto)
                    }
                    if supportedFlashModes.contains(.on) {
                        availableModes.append(.on)
                    }
                    self.availableFlashModes = availableModes
                    self.hasFlash = camera.hasFlash && availableModes.count > 1
                    self.maxZoomFactor = max(1.0, supportedZoom)
                    self.minISO = minimumISO
                    self.maxISO = max(minimumISO + 1, maximumISO)
                    self.isoValue = self.currentISO
                    self.minShutterSeconds = minimumShutter
                    self.maxShutterSeconds = maximumShutter
                    self.shutterPosition = min(1.0, max(0.0, initialShutterPosition))
                    self.focusPosition = self.currentFocusPosition
                    self.colorTemperature = self.currentTemperature
                    self.minExposureBias = minimumExposureBias
                    self.maxExposureBias = maximumExposureBias
                    self.exposureBias = self.currentExposureBias
                }

                self.isConfigured = true
                self.session.commitConfiguration()
                if self.shouldRunSession {
                    self.session.startRunning()
                }
            } catch {
                self.session.commitConfiguration()
                self.publishError(error.localizedDescription)
            }
        }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async {
            guard let camera = self.cameraDevice else { return }

            let deviceMaximum = min(CGFloat(15.0), camera.activeFormat.videoMaxZoomFactor)
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
                self.isExposureManual = true
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
                self.isExposureManual = true
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

    func setExposureBias(_ value: Double) {
        sessionQueue.async {
            guard let camera = self.cameraDevice else { return }

            guard camera.exposureMode != .custom else {
                self.publishError("Коррекция EV доступна в автоматическом режиме экспозиции.")
                return
            }

            let bias = min(
                Double(camera.maxExposureTargetBias),
                max(Double(camera.minExposureTargetBias), value)
            )

            do {
                try camera.lockForConfiguration()
                camera.setExposureTargetBias(Float(bias), completionHandler: nil)
                camera.unlockForConfiguration()

                self.currentExposureBias = bias
                DispatchQueue.main.async {
                    self.exposureBias = bias
                }
            } catch {
                self.publishError("Не удалось изменить EV: \(error.localizedDescription)")
            }
        }
    }

    func focus(
        at devicePoint: CGPoint,
        displayPoint: CGPoint,
        lockAfterFocus: Bool = false
    ) {
        sessionQueue.async {
            guard let camera = self.cameraDevice else { return }

            let point = CGPoint(
                x: min(1, max(0, devicePoint.x)),
                y: min(1, max(0, devicePoint.y))
            )
            let operationID = UUID()
            self.focusOperationID = operationID

            do {
                try camera.lockForConfiguration()

                if camera.isFocusPointOfInterestSupported {
                    camera.focusPointOfInterest = point
                }

                // A normal tap starts continuous AF at the selected point. The long-press
                // path waits briefly for AF/AE to settle, then locks the achieved settings.
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                } else if camera.isFocusModeSupported(.autoFocus) {
                    camera.focusMode = .autoFocus
                }

                let canAdjustExposure =
                    camera.exposureMode != .custom &&
                    camera.isExposurePointOfInterestSupported
                if canAdjustExposure {
                    camera.exposurePointOfInterest = point
                    if camera.isExposureModeSupported(.continuousAutoExposure) {
                        camera.exposureMode = .continuousAutoExposure
                    } else if camera.isExposureModeSupported(.autoExpose) {
                        camera.exposureMode = .autoExpose
                    }
                }

                camera.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.isFocusManual = false
                    self.isFocusExposureLocked = false
                    self.focusPosition = Double(camera.lensPosition)
                    self.focusIndicatorPoint = displayPoint
                    self.statusMessage = lockAfterFocus
                        ? "Фиксирую фокус и экспозицию…"
                        : (self.isExposureManual
                            ? "Автофокусировка"
                            : "Автофокус и автоэкспозиция")
                }

                if lockAfterFocus {
                    self.sessionQueue.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                        guard let self,
                              self.focusOperationID == operationID,
                              let activeCamera = self.cameraDevice else { return }

                        do {
                            try activeCamera.lockForConfiguration()

                            var focusLocked = false
                            if activeCamera.isFocusModeSupported(.locked) {
                                activeCamera.setFocusModeLocked(
                                    lensPosition: activeCamera.lensPosition,
                                    completionHandler: nil
                                )
                                focusLocked = true
                            }

                            var exposureLocked = false
                            if activeCamera.exposureMode != .custom &&
                                activeCamera.isExposureModeSupported(.locked) {
                                activeCamera.exposureMode = .locked
                                exposureLocked = true
                            }

                            activeCamera.unlockForConfiguration()

                            guard focusLocked || exposureLocked else {
                                self.publishError("Эта камера не поддерживает фиксацию фокуса и экспозиции.")
                                return
                            }

                            self.currentFocusPosition = Double(activeCamera.lensPosition)
                            DispatchQueue.main.async {
                                self.isFocusExposureLocked = true
                                self.isFocusManual = focusLocked
                                self.focusPosition = self.currentFocusPosition
                                self.statusMessage = self.isExposureManual
                                    ? "AF LOCK · ручная экспозиция"
                                    : "AE/AF LOCK"
                            }
                        } catch {
                            self.publishError("Не удалось зафиксировать фокус и экспозицию: \(error.localizedDescription)")
                        }
                    }
                } else {
                    self.sessionQueue.asyncAfter(deadline: .now() + 1.7) { [weak self] in
                        guard let self,
                              self.focusOperationID == operationID else { return }
                        DispatchQueue.main.async {
                            guard !self.isFocusExposureLocked,
                                  self.focusIndicatorPoint == displayPoint else { return }
                            self.focusIndicatorPoint = nil
                        }
                    }
                }
            } catch {
                self.publishError("Не удалось сфокусироваться: \(error.localizedDescription)")
            }
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
                    self.isFocusManual = true
                    self.isFocusExposureLocked = false
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
                    self.isWhiteBalanceManual = true
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

                camera.setExposureTargetBias(0, completionHandler: nil)
                camera.unlockForConfiguration()

                self.currentISO = Double(camera.iso)
                self.currentFocusPosition = Double(camera.lensPosition)
                self.currentShutterPosition = self.shutterPositionForCurrentExposure(camera)
                let temperatureAndTint = camera.temperatureAndTintValues(
                    for: camera.deviceWhiteBalanceGains
                )
                self.currentTemperature = Double(temperatureAndTint.temperature)

                DispatchQueue.main.async {
                    self.isoValue = self.currentISO
                    self.focusPosition = self.currentFocusPosition
                    self.shutterPosition = self.currentShutterPosition
                    self.colorTemperature = self.currentTemperature
                    self.isExposureManual = false
                    self.isFocusManual = false
                    self.isWhiteBalanceManual = false
                    self.isFocusExposureLocked = false
                    self.focusIndicatorPoint = nil
                    self.currentExposureBias = 0
                    self.exposureBias = 0
                    self.statusMessage = "Автоматические настройки включены"
                }
            } catch {
                self.publishError("Не удалось включить автоматику: \(error.localizedDescription)")
            }
        }
    }

    private func shutterPositionForCurrentExposure(_ camera: AVCaptureDevice) -> Double {
        let minimum = max(
            1.0 / 10000.0,
            camera.activeFormat.minExposureDuration.seconds
        )
        let maximum = max(
            minimum,
            min(1.0, camera.activeFormat.maxExposureDuration.seconds)
        )
        guard maximum > minimum else { return 0.5 }

        let duration = min(
            maximum,
            max(minimum, camera.exposureDuration.seconds)
        )
        return min(
            1.0,
            max(0.0, log(duration / minimum) / log(maximum / minimum))
        )
    }

    func takePhoto() {
        let useMultiFrame = multiFrameEnabled
        let requestProRAW = useProRAW && proRAWAvailable
        let selectedFlashMode = flashMode.captureMode

        sessionQueue.async {
            guard self.session.isRunning, !self.isBurstRunning else { return }

            self.isBurstRunning = true
            self.pendingBurstFrames.removeAll(keepingCapacity: true)
            self.pendingRawPhotoData = nil
            self.burstUsesProRAW = requestProRAW
            self.burstFlashMode = self.photoOutput.supportedFlashModes.contains(selectedFlashMode)
                ? selectedFlashMode
                : .off

            let canUseBurst = useMultiFrame &&
                !requestProRAW &&
                self.burstFlashMode == .off
            self.requestedBurstCount = canUseBurst ? 3 : 1
            let captureCount = self.requestedBurstCount

            DispatchQueue.main.async {
                self.isCapturing = true
                self.statusMessage = requestProRAW
                    ? "Снимаю Apple ProRAW…"
                    : (captureCount == 3 ? "Снимаю серию из 3 кадров…" : "Снимаю…")
                self.errorMessage = nil
            }

            if captureCount > 1 {
                self.freezeAutomaticControlsForBurst {
                    self.captureNextBurstFrame()
                }
            } else {
                self.captureNextBurstFrame()
            }
        }
    }

    private func freezeAutomaticControlsForBurst(completion: @escaping () -> Void) {
        guard let camera = cameraDevice else {
            completion()
            return
        }

        let group = DispatchGroup()

        do {
            try camera.lockForConfiguration()

            var exposureMode: AVCaptureDevice.ExposureMode?
            var focusMode: AVCaptureDevice.FocusMode?
            var whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode?

            if camera.exposureMode != .custom &&
                camera.exposureMode != .locked &&
                camera.isExposureModeSupported(.locked) {
                exposureMode = camera.exposureMode
                camera.exposureMode = .locked
            }

            if camera.focusMode != .locked &&
                camera.isFocusModeSupported(.locked) {
                focusMode = camera.focusMode
                group.enter()
                camera.setFocusModeLocked(
                    lensPosition: camera.lensPosition
                ) { _ in
                    group.leave()
                }
            }

            if camera.whiteBalanceMode != .locked &&
                camera.isWhiteBalanceModeSupported(.locked) {
                whiteBalanceMode = camera.whiteBalanceMode
                group.enter()
                camera.setWhiteBalanceModeLocked(
                    with: camera.deviceWhiteBalanceGains
                ) { _ in
                    group.leave()
                }
            }

            camera.unlockForConfiguration()
            savedBurstModes = SavedAutomaticModes(
                exposure: exposureMode,
                focus: focusMode,
                whiteBalance: whiteBalanceMode
            )

            group.notify(queue: sessionQueue, execute: completion)
        } catch {
            savedBurstModes = nil
            publishError("Не удалось зафиксировать настройки для серии: \(error.localizedDescription)")
            completion()
        }
    }

    private func restoreAutomaticControlsAfterBurst() {
        guard let camera = cameraDevice, let saved = savedBurstModes else { return }
        savedBurstModes = nil

        do {
            try camera.lockForConfiguration()

            if let mode = saved.exposure,
               camera.isExposureModeSupported(mode) {
                camera.exposureMode = mode
            }

            if let mode = saved.focus,
               camera.isFocusModeSupported(mode) {
                camera.focusMode = mode
            }

            if let mode = saved.whiteBalance,
               camera.isWhiteBalanceModeSupported(mode) {
                camera.whiteBalanceMode = mode
            }

            camera.unlockForConfiguration()
        } catch {
            publishError("Не удалось вернуть автоматические настройки: \(error.localizedDescription)")
        }
    }

    private func captureNextBurstFrame() {
        guard isBurstRunning else { return }

        if pendingBurstFrames.count >= requestedBurstCount {
            isBurstRunning = false
            let frames = pendingBurstFrames
            let rawData = pendingRawPhotoData
            pendingBurstFrames.removeAll(keepingCapacity: true)
            pendingRawPhotoData = nil
            restoreAutomaticControlsAfterBurst()
            processCapturedFrames(frames, rawData: rawData)
            return
        }

        let settings: AVCapturePhotoSettings
        if burstUsesProRAW,
           photoOutput.isAppleProRAWEnabled,
           let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
               AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
           }) {
            // Use JPEG for the rendered companion so its PhotoKit UTI is exact.
            let codec: AVVideoCodecType = .jpeg
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawFormat,
                processedFormat: [AVVideoCodecKey: codec]
            )
        } else {
            settings = AVCapturePhotoSettings()
        }

        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = requestedBurstCount > 1
            ? (burstPhotoDimensions ?? photoOutput.maxPhotoDimensions)
            : photoOutput.maxPhotoDimensions
        if photoOutput.supportedFlashModes.contains(burstFlashMode) {
            settings.flashMode = burstFlashMode
        }

        let identifier = settings.uniqueID
        let delegate = PhotoFrameCaptureDelegate { [weak self] finishedID, processedData, rawData, error in
            guard let self else { return }

            self.sessionQueue.async {
                self.captureDelegates.removeValue(forKey: finishedID)

                if let data = processedData, error == nil {
                    self.pendingBurstFrames.append(data)
                    if self.pendingRawPhotoData == nil {
                        self.pendingRawPhotoData = rawData
                    }
                    self.captureNextBurstFrame()
                    return
                }

                if !self.pendingBurstFrames.isEmpty {
                    // Keep usable frames if one capture in the series fails.
                    self.requestedBurstCount = self.pendingBurstFrames.count
                    self.captureNextBurstFrame()
                } else {
                    self.isBurstRunning = false
                    self.restoreAutomaticControlsAfterBurst()
                    DispatchQueue.main.async {
                        self.isCapturing = false
                        self.errorMessage = error?.localizedDescription
                            ?? "Не удалось получить фотографию."
                    }
                }
            }
        }

        captureDelegates[identifier] = delegate
        updatePhotoOutputRotation()
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    private func updatePhotoOutputRotation() {
        guard let connection = photoOutput.connection(with: .video) else { return }

        if #available(iOS 17.0, *),
           let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            return
        }

        guard connection.isVideoOrientationSupported else { return }
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            connection.videoOrientation = .landscapeRight
        case .landscapeRight:
            connection.videoOrientation = .landscapeLeft
        case .portraitUpsideDown:
            connection.videoOrientation = .portraitUpsideDown
        default:
            connection.videoOrientation = .portrait
        }
    }

    private func processCapturedFrames(_ frames: [Data], rawData: Data?) {
        guard !frames.isEmpty else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.errorMessage = "Камера не вернула изображение."
            }
            return
        }

        DispatchQueue.main.async {
            self.statusMessage = frames.count > 1
                ? "Совмещаю кадры и уменьшаю шум…"
                : "Подготавливаю фотографию…"
        }

        processingQueue.async {
            let processingStartedAt = ProcessInfo.processInfo.systemUptime
            let result: PhotoProcessingResult

            do {
                result = try PhotoProcessor.process(frames)
            } catch {
                guard let data = frames.first, let image = UIImage(data: data) else {
                    DispatchQueue.main.async {
                        self.isCapturing = false
                        self.errorMessage = "Не удалось обработать фотографию."
                    }
                    return
                }

                result = PhotoProcessingResult(
                    originalImage: image,
                    enhancedImage: image,
                    outputData: data,
                    mergedFrameCount: 1,
                    outputScale: 1,
                    mergeBackend: "processing-error-original",
                    usedHighResolutionUpscale: false,
                    processingDescription: "Обработка не удалась; сохранён оригинал"
                )
            }

            let processingMilliseconds = (
                ProcessInfo.processInfo.systemUptime - processingStartedAt
            ) * 1000
            let diagnosticID = self.diagnostics.recordCapture(
                inputData: frames.first,
                rawData: rawData,
                outputData: result.outputData,
                requestedFrameCount: frames.count,
                mergedFrameCount: result.mergedFrameCount,
                processingMilliseconds: processingMilliseconds,
                mergeBackend: result.mergeBackend,
                outputScale: result.outputScale
            )

            DispatchQueue.main.async {
                self.originalCapturedImage = result.originalImage
                self.capturedImage = result.enhancedImage
                self.mergedFrameCount = result.mergedFrameCount
                self.processingDescription = result.processingDescription
                self.isCapturing = false

                let saveMessage: String
                if result.mergedFrameCount > 1 {
                    saveMessage = "Объединено кадров: \(result.mergedFrameCount). Фото сохранено."
                } else if frames.count > 1 {
                    saveMessage = "Кадры не удалось надёжно совместить. Сохранён оригинальный снимок."
                } else {
                    saveMessage = "Фото сохранено в приложении «Фото»."
                }

                let finalMessage = rawData == nil
                    ? saveMessage
                    : saveMessage + " ProRAW (DNG) и обработанная копия сохранены вместе."

                self.savePhotoToLibrary(
                    result.outputData,
                    rawData: rawData,
                    successMessage: finalMessage,
                    diagnosticID: diagnosticID
                )
            }
        }
    }

    private func savePhotoToLibrary(
        _ data: Data,
        rawData: Data?,
        successMessage: String,
        diagnosticID: UUID? = nil
    ) {
        DispatchQueue.main.async {
            self.isSavingPhoto = true
            self.statusMessage = "Сохраняю снимок в Фото…"
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized:
            performPhotoSave(
                data,
                rawData: rawData,
                successMessage: successMessage,
                diagnosticID: diagnosticID
            )
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                guard let self else { return }
                if status == .authorized {
                    self.performPhotoSave(
                        data,
                        rawData: rawData,
                        successMessage: successMessage,
                        diagnosticID: diagnosticID
                    )
                } else {
                    self.finishPhotoSave(
                        success: false,
                        message: "Нет разрешения сохранять фото. Проверьте настройки приватности.",
                        diagnosticID: diagnosticID
                    )
                }
            }
        default:
            finishPhotoSave(
                success: false,
                message: "Нет разрешения сохранять фото. Проверьте настройки приватности.",
                diagnosticID: diagnosticID
            )
        }
    }

    private func performPhotoSave(
        _ data: Data,
        rawData: Data?,
        successMessage: String,
        diagnosticID: UUID? = nil
    ) {
        // PhotoKit handles ProRAW/DNG more reliably as a file-backed resource.
        // In particular, keep the .dng extension so Photos can identify the RAW container.
        let rawFileURL: URL?
        if let rawData {
            let fileName = "TomkaCamera-\(UUID().uuidString).dng"
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName, isDirectory: false)

            do {
                try rawData.write(to: fileURL, options: .atomic)
                rawFileURL = fileURL
            } catch {
                finishPhotoSave(
                    success: false,
                    message: "Не удалось подготовить ProRAW-файл: \(error.localizedDescription)",
                    diagnosticID: diagnosticID
                )
                return
            }
        } else {
            rawFileURL = nil
        }

        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()

            if let rawFileURL {
                // Follow Apple's documented RAW + rendered companion pairing.
                // The .dng filename lets Photos infer the RAW container type.
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.shouldMoveFile = true
                request.addResource(
                    with: .photo,
                    fileURL: rawFileURL,
                    options: rawOptions
                )

                // Store the processed JPEG as the asset's alternate photo resource.
                request.addResource(
                    with: .alternatePhoto,
                    data: data,
                    options: nil
                )
            } else {
                request.addResource(with: .photo, data: data, options: nil)
            }
        }) { [weak self] success, error in
            // If Photos didn't move the temporary DNG (for example, on failure), clean it up.
            if let rawFileURL,
               FileManager.default.fileExists(atPath: rawFileURL.path) {
                try? FileManager.default.removeItem(at: rawFileURL)
            }

            if success {
                self?.finishPhotoSave(
                    success: true,
                    message: successMessage,
                    diagnosticID: diagnosticID
                )
            } else if let error {
                let nsError = error as NSError
                let details = "\(nsError.localizedDescription) (\(nsError.domain), code \(nsError.code))"
                self?.finishPhotoSave(
                    success: false,
                    message: details,
                    diagnosticID: diagnosticID
                )
            } else {
                self?.finishPhotoSave(
                    success: false,
                    message: "Не удалось сохранить снимок в медиатеку.",
                    diagnosticID: diagnosticID
                )
            }
        }
    }

    private func finishPhotoSave(
        success: Bool,
        message: String,
        diagnosticID: UUID? = nil
    ) {
        diagnostics.recordSave(id: diagnosticID, success: success, message: message)
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

private final class PhotoFrameCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Int64, Data?, Data?, Error?) -> Void
    private var processedPhotoData: Data?
    private var rawPhotoData: Data?
    private var processingError: Error?

    init(completion: @escaping (Int64, Data?, Data?, Error?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            processingError = error
        } else if photo.isRawPhoto {
            rawPhotoData = photo.fileDataRepresentation()
        } else {
            processedPhotoData = photo.fileDataRepresentation()
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        completion(
            resolvedSettings.uniqueID,
            processedPhotoData,
            rawPhotoData,
            processingError ?? error
        )
    }
}
