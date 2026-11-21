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
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 55))
                    .foregroundStyle(.white)

                Text("Tomka Camera")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text("Первая версия приложения")
                    .foregroundStyle(.gray)
            }
        }
    }
}
