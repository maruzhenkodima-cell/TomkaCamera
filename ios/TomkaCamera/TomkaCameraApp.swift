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
    @StateObject private var camera = CameraManager()
    @State private var showManualControls = false

    private let zoomPresets: [CGFloat] = [1.0, 2.0, 3.0]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = camera.capturedImage {
                photoReview(image)
            } else {
                cameraScreen
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: camera.zoomFactor) { newValue in
            camera.setZoom(newValue)
        }
        .onChange(of: camera.isoValue) { newValue in
            camera.setISO(newValue)
        }
        .onChange(of: camera.shutterPosition) { newValue in
            camera.setShutterPosition(newValue)
        }
        .onChange(of: camera.focusPosition) { newValue in
            camera.setFocus(newValue)
        }
        .onChange(of: camera.colorTemperature) { newValue in
            camera.setColorTemperature(newValue)
        }
        .onAppear {
            camera.requestPermission()
        }
    }

    private var cameraScreen: some View {
        ZStack {
            if camera.isAuthorized {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
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
                        value: $camera.zoomFactor,
                        in: 1.0...max(1.0, camera.maxZoomFactor)
                    )
                    .tint(.white)
                    .disabled(!camera.isAuthorized || camera.maxZoomFactor <= 1.0)
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
                    .disabled(!camera.isAuthorized || camera.isCapturing)
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
                Slider(value: $camera.isoValue, in: camera.minISO...camera.maxISO)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Выдержка")
                    Spacer()
                    Text(camera.shutterSpeedLabel)
                        .monospacedDigit()
                }
                Slider(value: $camera.shutterPosition, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Фокус")
                    Spacer()
                    Text(String(format: "%.2f", camera.focusPosition))
                        .monospacedDigit()
                }
                Slider(value: $camera.focusPosition, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Баланс белого")
                    Spacer()
                    Text("\(Int(camera.colorTemperature)) K")
                        .monospacedDigit()
                }
                Slider(value: $camera.colorTemperature, in: 2500...8000, step: 50)
            }

            Text("Ручные значения фиксируют параметры камеры. Кнопка «Авто» возвращает автоматическую экспозицию, фокус и баланс белого.")
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
                camera.statusMessage = nil
                camera.errorMessage = nil
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
