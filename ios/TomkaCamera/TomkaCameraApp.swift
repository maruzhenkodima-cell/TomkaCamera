import SwiftUI

@main
struct TomkaCameraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraManager()
    @State private var showManualControls = false
    @State private var showOriginal = false

    private let zoomPresets: [CGFloat] = [1.0, 2.0, 3.0]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = showOriginal
                ? camera.originalCapturedImage
                : camera.capturedImage {
                photoReview(image)
            } else if let image = camera.capturedImage {
                photoReview(image)
            } else {
                cameraScreen
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            camera.requestPermission()
            camera.setSessionActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { newPhase in
            camera.setSessionActive(newPhase == .active)
        }
    }

    private var cameraScreen: some View {
        ZStack {
            if camera.isAuthorized {
                CameraPreview(session: camera.session) { devicePoint, displayPoint in
                    camera.focus(at: devicePoint, displayPoint: displayPoint)
                }
                .ignoresSafeArea()

                if camera.showCompositionGrid {
                    CompositionGrid()
                        .stroke(.white.opacity(0.42), lineWidth: 0.7)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                GeometryReader { geometry in
                    if let point = camera.focusIndicatorPoint {
                        FocusReticle()
                            .position(
                                x: point.x * geometry.size.width,
                                y: point.y * geometry.size.height
                            )
                            .allowsHitTesting(false)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            VStack(spacing: 12) {
                HStack {
                    Text("TOMKA CAMERA")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .tracking(2)
                    Spacer()
                    Button {
                        showManualControls.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 42, height: 42)
                            .background(.black.opacity(0.42), in: Circle())
                    }
                    .accessibilityLabel("Ручные настройки")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                if let message = camera.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                } else if let status = camera.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.65), in: Capsule())
                } else if !camera.isAuthorized {
                    Text("Ожидание доступа к камере…")
                        .foregroundStyle(.white)
                }

                if showManualControls {
                    manualControls
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                VStack(spacing: 13) {
                    Text(String(format: "%.1f×", Double(camera.zoomFactor)))
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    HStack(spacing: 24) {
                        ForEach(zoomPresets, id: \.self) { preset in
                            Button {
                                camera.setZoom(preset)
                            } label: {
                                Text(preset == 1 ? "1×" : String(format: "%.0f×", Double(preset)))
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 48, height: 40)
                                    .background(
                                        abs(camera.zoomFactor - preset) < 0.05
                                            ? Color.white.opacity(0.32)
                                            : Color.white.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                            .disabled(!camera.isAuthorized || camera.maxZoomFactor < preset)
                        }
                    }

                    Slider(
                        value: Binding(
                            get: { camera.zoomFactor },
                            set: { camera.setZoom($0) }
                        ),
                        in: 1.0...max(1.0, camera.maxZoomFactor)
                    )
                    .tint(.white)
                    .disabled(!camera.isAuthorized || camera.maxZoomFactor <= 1.0)
                    .padding(.horizontal, 24)

                    if camera.hasFlash {
                        HStack(spacing: 10) {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(.yellow)
                            Picker("Вспышка", selection: $camera.flashMode) {
                                ForEach(camera.availableFlashModes) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(camera.useProRAW)
                        }
                        .font(.caption)
                        .padding(.horizontal, 24)
                    }

                    Toggle("Серия из 3 кадров (меньше шума)", isOn: $camera.multiFrameEnabled)
                        .font(.caption)
                        .tint(.white)
                        .padding(.horizontal, 24)
                        .disabled(camera.useProRAW || camera.flashMode != .off)

                    Toggle(
                        camera.proRAWAvailable ? "Apple ProRAW (DNG)" : "Apple ProRAW недоступен",
                        isOn: $camera.useProRAW
                    )
                    .font(.caption)
                    .tint(.white)
                    .padding(.horizontal, 24)
                    .disabled(!camera.proRAWAvailable || camera.flashMode != .off)

                    Toggle("Сетка третей", isOn: $camera.showCompositionGrid)
                        .font(.caption)
                        .tint(.white)
                        .padding(.horizontal, 24)

                    Button {
                        camera.takePhoto()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.white)
                                .frame(width: 76, height: 76)
                            Circle()
                                .stroke(.gray, lineWidth: 4)
                                .frame(width: 66, height: 66)
                            if camera.isCapturing || camera.isSavingPhoto {
                                ProgressView()
                                    .tint(.black)
                            }
                        }
                    }
                    .disabled(!camera.isAuthorized || camera.isCapturing || camera.isSavingPhoto)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 26)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72), .black.opacity(0.88)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
            }
        }
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("РУЧНЫЕ НАСТРОЙКИ")
                    .font(.caption.weight(.bold))
                    .tracking(1)
                Spacer()
                Button("Авто") {
                    camera.enableAutomaticControls()
                }
                .font(.caption.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("ISO")
                    Spacer()
                    Text("\(Int(camera.isoValue))")
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { camera.isoValue },
                        set: { camera.setISO($0) }
                    ),
                    in: camera.minISO...camera.maxISO
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Выдержка")
                    Spacer()
                    Text(camera.shutterSpeedLabel)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { camera.shutterPosition },
                        set: { camera.setShutterPosition($0) }
                    ),
                    in: 0...1
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Экспокоррекция EV")
                    Spacer()
                    Text(String(format: "%+.1f", camera.exposureBias))
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { camera.exposureBias },
                        set: { camera.setExposureBias($0) }
                    ),
                    in: camera.minExposureBias...camera.maxExposureBias,
                    step: 0.1
                )
                .disabled(camera.isExposureManual)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Фокус")
                    Spacer()
                    Text(String(format: "%.2f", camera.focusPosition))
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { camera.focusPosition },
                        set: { camera.setFocus($0) }
                    ),
                    in: 0...1
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Баланс белого")
                    Spacer()
                    Text("\(Int(camera.colorTemperature)) K")
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { camera.colorTemperature },
                        set: { camera.setColorTemperature($0) }
                    ),
                    in: 2500...8000,
                    step: 50
                )
            }

            Text("Коснись нужной области кадра для фокусировки. EV регулирует яркость в автоматическом режиме. ProRAW сохраняет DNG. Вспышка отключает серию кадров.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(16)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14)
    }

    private func photoReview(_ image: UIImage) -> some View {
        VStack(spacing: 16) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if camera.originalCapturedImage != nil {
                HStack(spacing: 12) {
                    Button {
                        showOriginal = false
                    } label: {
                        Text("Обработанное")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                !showOriginal ? .white.opacity(0.22) : .clear,
                                in: Capsule()
                            )
                    }

                    Button {
                        showOriginal = true
                    } label: {
                        Text("Оригинал")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                showOriginal ? .white.opacity(0.22) : .clear,
                                in: Capsule()
                            )
                    }
                }
                .font(.subheadline.weight(.semibold))
                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
            }

            if camera.isSavingPhoto {
                Label("Сохраняю в Фото…", systemImage: "arrow.down.to.line")
                    .foregroundStyle(.white)
            } else if let status = camera.statusMessage {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            } else if let error = camera.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Назад к камере") {
                camera.capturedImage = nil
                camera.originalCapturedImage = nil
                camera.statusMessage = nil
                camera.errorMessage = nil
                showOriginal = false
            }
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
            .background(.white, in: Capsule())
            .padding(.bottom, 24)
        }
        .padding()
    }
}


private struct CompositionGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let x = rect.width * fraction
            let y = rect.height * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

private struct FocusReticle: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .stroke(.yellow, lineWidth: 1.5)
                .frame(width: 72, height: 72)

            Circle()
                .stroke(.yellow.opacity(0.9), lineWidth: 1)
                .frame(width: 7, height: 7)
        }
        .shadow(color: .black.opacity(0.65), radius: 2)
        .transition(.opacity)
    }
}
