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

    private let zoomPresets: [CGFloat] = [1.0, 2.0, 3.0]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = camera.capturedImage {
                VStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Button("Назад к камере") {
                        camera.capturedImage = nil
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.bottom, 30)
                }
                .padding()
            } else {
                if camera.isAuthorized {
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea()
                }

                VStack(spacing: 18) {
                    Spacer()

                    if let message = camera.errorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else if !camera.isAuthorized {
                        Text("Ожидание доступа к камере…")
                            .foregroundStyle(.white)
                    }

                    VStack(spacing: 12) {
                        Text(String(format: "%.1f×", Double(camera.zoomFactor)))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()

                        HStack(spacing: 28) {
                            ForEach(zoomPresets, id: \.self) { preset in
                                Button {
                                    camera.setZoom(preset)
                                } label: {
                                    Text(preset == 1 ? "1×" : String(format: "%.0f×", Double(preset)))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 48, height: 40)
                                        .background(
                                            abs(camera.zoomFactor - preset) < 0.05
                                                ? Color.white.opacity(0.28)
                                                : Color.white.opacity(0.12)
                                        )
                                        .clipShape(Capsule())
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
                    }

                    Button {
                        camera.takePhoto()
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 76, height: 76)
                            .overlay {
                                Circle()
                                    .stroke(.gray, lineWidth: 4)
                                    .padding(5)
                            }
                    }
                    .disabled(!camera.isAuthorized)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: camera.zoomFactor) { newValue in
            camera.setZoom(newValue)
        }
        .onAppear {
            camera.requestPermission()
        }
    }
}
