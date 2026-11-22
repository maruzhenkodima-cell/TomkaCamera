import SwiftUI

@main
struct TomkaCameraApp: App {
    var body: some Scene {
        WindowGroup {
            // Expand the scene's root content before SwiftUI computes child layout.
            // ContentView also ignores safe areas, but applying it here ensures the
            // hosting root receives the full window proposal, not only the safe-area box.
            GeometryReader { geometry in
                ContentView()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .ignoresSafeArea(.all, edges: .all)
            }
            .ignoresSafeArea(.all, edges: .all)
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
    @State private var pinchStartZoom: CGFloat = 1
    @State private var isPinching = false

    private let zoomPresets: [CGFloat] = [1, 2, 3, 5, 10, 15]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                CameraPreview(session: camera.session) { devicePoint, displayPoint in
                    camera.focus(at: devicePoint, displayPoint: displayPoint)
                }
                .ignoresSafeArea()
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { magnification in
                            if !isPinching {
                                pinchStartZoom = camera.zoomFactor
                                isPinching = true
                            }
                            camera.setZoom(pinchStartZoom * magnification)
                        }
                        .onEnded { magnification in
                            camera.setZoom(pinchStartZoom * magnification)
                            isPinching = false
                        }
                )
                .zIndex(0)

                if camera.showCompositionGrid {
                    CompositionGrid()
                        .stroke(.white.opacity(0.42), lineWidth: 0.7)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .zIndex(1)
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
                .zIndex(2)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Ожидание доступа к камере…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.10), location: 0.28),
                    .init(color: .black.opacity(0.68), location: 0.72),
                    .init(color: .black.opacity(0.94), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity)
            .frame(height: 330)
            .ignoresSafeArea(edges: .bottom)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .zIndex(3)

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 20)

                if let message = camera.errorMessage ?? camera.statusMessage {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(camera.errorMessage == nil ? .white : .red)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .cameraChromeGlass(in: Capsule())
                        .padding(.bottom, 14)
                }

                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 58)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all, edges: .all)
        .background(Color.black.ignoresSafeArea())
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

    @ViewBuilder
    private var topBar: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                topBarControls
            }
        } else {
            topBarControls
        }
    }

    private var topBarControls: some View {
        HStack(spacing: 6) {
            chromeButton(
                symbol: flashSymbol,
                title: flashShortTitle,
                isActive: camera.flashMode != .off,
                isDisabled: !camera.hasFlash
            ) {
                cycleFlashMode()
            }

            chromeButton(
                symbol: camera.showCompositionGrid ? "grid" : "grid",
                title: "СЕТКА",
                isActive: camera.showCompositionGrid
            ) {
                camera.showCompositionGrid.toggle()
            }

            chromeButton(
                symbol: "camera.aperture",
                title: "RAW",
                isActive: camera.useProRAW,
                isDisabled: !camera.proRAWAvailable
            ) {
                camera.setProRAWEnabled(!camera.useProRAW)
            }

            chromeButton(
                symbol: "square.stack.3d.up",
                title: "3 КАДРА",
                isActive: camera.multiFrameEnabled,
                isDisabled: camera.useProRAW || camera.flashMode != .off
            ) {
                camera.setMultiFrameEnabled(!camera.multiFrameEnabled)
            }
        }
        .padding(5)
        .cameraChromeGlass(in: Capsule())
    }

    private func chromeButton(
        symbol: String,
        title: String,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.3)
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Color.yellow : Color.white)
            .frame(width: 52, height: 43)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.36 : 1)
        .accessibilityLabel(title)
    }

    private var flashSymbol: String {
        switch camera.flashMode {
        case .off: return "bolt.slash"
        case .auto: return "bolt.badge.a"
        case .on: return "bolt.fill"
        }
    }

    private var flashShortTitle: String {
        switch camera.flashMode {
        case .off: return "ВЫКЛ"
        case .auto: return "АВТО"
        case .on: return "ВКЛ"
        }
    }

    private func cycleFlashMode() {
        let modes = camera.availableFlashModes
        guard !modes.isEmpty else { return }
        let currentIndex = modes.firstIndex(of: camera.flashMode) ?? 0
        camera.setFlashMode(modes[(currentIndex + 1) % modes.count])
    }

    private var bottomControls: some View {
        VStack(spacing: 17) {
            zoomControls

            HStack(alignment: .center, spacing: 0) {
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
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.72), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(camera.capturedImage == nil)
                .opacity(camera.capturedImage == nil ? 0.58 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Последняя фотография")

                Button {
                    camera.takePhoto()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 78, height: 78)
                        Circle()
                            .stroke(.white.opacity(0.78), lineWidth: 2)
                            .frame(width: 68, height: 68)
                        if camera.isCapturing {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(1.1)
                        }
                    }
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(!camera.isAuthorized || camera.isCapturing)
                .accessibilityLabel("Сделать фотографию")

                Button {
                    activeSheet = .settings
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .cameraChromeGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Настройки съёмки")
            }

            Text(captureModeLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(.horizontal, 5)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var captureModeLabel: String {
        if camera.useProRAW { return "APPLE PRORAW · DNG" }
        if camera.multiFrameEnabled { return "СЕРИЯ · 3 КАДРА" }
        return "ФОТО"
    }

    private var zoomControls: some View {
        VStack(spacing: 9) {
            zoomPresetRow

            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { Double(camera.zoomFactor) },
                        set: { camera.setZoom(CGFloat($0)) }
                    ),
                    in: 1.0...Double(max(1.0, camera.maxZoomFactor))
                )
                .tint(.white)
                .disabled(!camera.isAuthorized || camera.maxZoomFactor <= 1.0)

                Text(String(format: "%.1f×", Double(camera.zoomFactor)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 43, alignment: .trailing)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 5)
            .cameraChromeGlass(in: Capsule())
        }
    }

    @ViewBuilder
    private var zoomPresetRow: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 5) {
                zoomPresetButtons
            }
        } else {
            zoomPresetButtons
        }
    }

    private var zoomPresetButtons: some View {
        HStack(spacing: 5) {
            ForEach(zoomPresets, id: \.self) { preset in
                let selected = abs(camera.zoomFactor - preset) < 0.08
                Button {
                    camera.setZoom(preset)
                } label: {
                    Text(String(format: "%.0f×", Double(preset)))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .frame(width: 43, height: 36)
                        .background(
                            selected ? Color.white : Color.clear,
                            in: Capsule()
                        )
                        .cameraChromeGlass(in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!camera.isAuthorized || camera.maxZoomFactor + 0.01 < preset)
                .opacity(camera.maxZoomFactor + 0.01 < preset ? 0.34 : 1)
                .accessibilityLabel("Увеличение \(Int(preset))×")
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func cameraChromeGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.16), lineWidth: 0.7))
        }
    }
}

private struct CameraSettingsView: View {
    @ObservedObject var camera: CameraManager
    let onDismiss: () -> Void
    @State private var diagnosticsURL: URL?
    @State private var diagnosticsError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Съёмка") {
                    Picker(
                        "Вспышка",
                        selection: Binding(
                            get: { camera.flashMode },
                            set: { camera.setFlashMode($0) }
                        )
                    ) {
                        ForEach(camera.availableFlashModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Toggle(
                        "Серия из 3 кадров",
                        isOn: Binding(
                            get: { camera.multiFrameEnabled },
                            set: { camera.setMultiFrameEnabled($0) }
                        )
                    )
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

                    Toggle(
                        "Apple ProRAW (DNG)",
                        isOn: Binding(
                            get: { camera.useProRAW },
                            set: { camera.setProRAWEnabled($0) }
                        )
                    )
                    .disabled(!camera.proRAWAvailable)

                    if !camera.proRAWAvailable {
                        Text("ProRAW недоступен в текущей конфигурации камеры.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Сетка третей", isOn: $camera.showCompositionGrid)
                }

                Section("Диагностика") {
                    Text("Технический JSON-отчёт о последних 100 снимках. Фотографии и GPS-координаты в отчёт не включаются.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Подготовить отчёт JSON") {
                        diagnosticsURL = camera.exportDiagnostics()
                        diagnosticsError = diagnosticsURL == nil
                            ? "Не удалось сформировать отчёт."
                            : nil
                    }

                    if let diagnosticsURL {
                        ShareLink(item: diagnosticsURL) {
                            Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                        }
                    }

                    if let diagnosticsError {
                        Text(diagnosticsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
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
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("Нет снимка")
                            .font(.headline)
                        Text("Сделайте фотографию, чтобы посмотреть результат.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
