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

                VStack {
                    Spacer()

                    if let message = camera.errorMessage {
                        Text(message)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                    } else if !camera.isAuthorized {
                        Text("Ожидание доступа к камере…")
                            .foregroundStyle(.white)
                    }

                    Button {
                        camera.takePhoto()
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                            .overlay {
                                Circle()
                                    .stroke(.gray, lineWidth: 4)
                                    .padding(5)
                            }
                    }
                    .disabled(!camera.isAuthorized)
                    .padding(.bottom, 35)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            camera.requestPermission()
        }
    }
}
