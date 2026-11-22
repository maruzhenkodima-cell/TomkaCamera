import SwiftUI

@main
struct TomkaCameraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private enum CameraSheet: String, Identifiable {
    case settings
    case photoReview

    var id: String { rawValue }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraManager()
    @State private var activeSheet: CameraSheet?

    private let zoomPresets: [CGFloat] = [1.0, 2.0, 3.0]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cameraScreen
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                CameraSettingsView(camera: camera) {
                    activeSheet = nil
                }
            case .photoReview:
                PhotoReviewView(camera: camera) {
                    activeSheet = nil
                }
            }
        }
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
            } else {
                Text("Ожидание доступа к камере…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 12)

                if let message = camera.errorMessage ?? camera.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(camera.errorMessage == nil ? .white : .red)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.68), in: Capsule())
                        .padding(.bottom, 10)
                }

                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("TOMKA CAMERA")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.5)
                Text("BETA")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            Button(action: cycleFlashMode) {
                VStack(spacing: 2) {
                    Image(systemName: flashSymbol)
                        .font(.system(size: 17, weight: .semibold))
                    Text(camera.flashMode.title)
                        .font(.system(size: 9, weight: .semibold))
                }
                .frame(width: 48, height: 42)
                .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Вспышка: \(camera.flashMode.title)")

            Button {
                camera.showCompositionGrid.toggle()
            } label: {
                Image(systemName: camera.showCompositionGrid ? "grid" : "grid")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(
                        camera.showCompositionGrid ? .white.opacity(0.24) : .black.opacity(0.42),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Переключить сетку")
        }
        .foregroundStyle(.white)
    }

    private var flashSymbol: String {
        switch camera.flashMode {
        case .off: return "bolt.slash"
        case .auto: return "bolt.badge.a"
        case .on: return "bolt.fill"
        }
    }

    private func cycleFlashMode() {
        let modes = camera.availableFlashModes
        guard !modes.isEmpty else { return }
        let currentIndex = modes.firstIndex(of: camera.flashMode) ?? 0
        camera.flashMode = modes[(currentIndex + 1) % modes.count]
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ForEach(zoomPresets, id: \.self) { preset in
                    Button {
                        camera.setZoom(preset)
                    } label: {
                        Text(preset == 1 ? "1×" : String(format: "%.0f×", Double(preset)))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 48, minHeight: 34)
                            .background(
                                abs(camera.zoomFactor - preset) < 0.05
                                    ? Color.white.opacity(0.3)
                                    : Color.white.opacity(0.12),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!camera.isAuthorized || camera.maxZoomFactor < preset)
                    .opacity(camera.maxZoomFactor < preset ? 0.35 : 1)
                }

                Spacer(minLength: 8)

                Text(String(format: "%.1f×", Double(camera.zoomFactor)))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
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
            .frame(height: 18)

            HStack {
                Button {
                    activeSheet = .photoReview
                } label: {
                    Group {
                        if let image = camera.capturedImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(.white.opacity(0.6), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(camera.capturedImage == nil)
                .opacity(camera.capturedImage == nil ? 0.55 : 1)
                .accessibilityLabel("Посмотреть последний снимок")

                Spacer()

                Button {
                    camera.takePhoto()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 76, height: 76)
                        Circle()
                            .stroke(.gray.opacity(0.8), lineWidth: 4)
                            .frame(width: 66, height: 66)
                        if camera.isCapturing {
                            ProgressView()
                                .tint(.black)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!camera.isAuthorized || camera.isCapturing)
                .accessibilityLabel("Сделать фотографию")

                Spacer()

                Button {
                    activeSheet = .settings
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Настройки камеры")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.72), .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

private struct CameraSettingsView: View {
    @ObservedObject var camera: CameraManager
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Съёмка") {
                    Picker("Вспышка", selection: $camera.flashMode) {
                        ForEach(camera.availableFlashModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Toggle("Серия из 3 кадров", isOn: $camera.multiFrameEnabled)
                        .disabled(camera.useProRAW || camera.flashMode != .off)

                    if camera.flashMode != .off {
                        Text("Серия временно недоступна со вспышкой: для стабильного совмещения трёх кадров нужна одинаковая подсветка.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if camera.useProRAW {
                        Text("Серия отключена, пока включён ProRAW.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Apple ProRAW (DNG)", isOn: $camera.useProRAW)
                        .disabled(!camera.proRAWAvailable)

                    if !camera.proRAWAvailable {
                        Text("ProRAW недоступен в текущей конфигурации камеры.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Сетка третей", isOn: $camera.showCompositionGrid)
                }

                Section("Экспозиция") {
                    VStack(alignment: .leading, spacing: 6) {
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

                    VStack(alignment: .leading, spacing: 6) {
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

                    VStack(alignment: .leading, spacing: 6) {
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
                }

                Section("Фокус и цвет") {
                    VStack(alignment: .leading, spacing: 6) {
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

                    VStack(alignment: .leading, spacing: 6) {
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

                    Button("Вернуть автоматические настройки") {
                        camera.enableAutomaticControls()
                    }
                }

                Section {
                    Text("Коснись нужной области видоискателя для фокусировки. EV работает в автоматическом режиме экспозиции. ProRAW сохраняет DNG и обработанную копию.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки камеры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово", action: onDismiss)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

private struct PhotoReviewView: View {
    @ObservedObject var camera: CameraManager
    let onDismiss: () -> Void
    @State private var showOriginal = false

    private var displayedImage: UIImage? {
        if showOriginal {
            return camera.originalCapturedImage ?? camera.capturedImage
        }
        return camera.capturedImage
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let image = displayedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                } else {
                    ContentUnavailableView(
                        "Нет снимка",
                        systemImage: "photo",
                        description: Text("Сделайте фотографию, чтобы посмотреть результат.")
                    )
                }

                if camera.originalCapturedImage != nil {
                    Picker("Вариант", selection: $showOriginal) {
                        Text("Обработка").tag(false)
                        Text("Оригинал").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                if !camera.processingDescription.isEmpty {
                    Text(camera.processingDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if camera.isSavingPhoto {
                    Label("Сохраняю в Фото…", systemImage: "arrow.down.to.line")
                        .font(.footnote)
                } else if let error = camera.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else if let status = camera.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle("Последний снимок")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово", action: onDismiss)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
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
