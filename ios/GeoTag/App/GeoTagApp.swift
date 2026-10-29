import SwiftUI

@main
struct GeoTagApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.paint)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            switch model.phase {
            case .loading:
                VStack(spacing: 24) {
                    GraffitiTitle(size: 96)
                    ProgressView().tint(Theme.chalk)
                }
            case .offline(let why):
                OfflineView(reason: why)
            case .onboarding:
                OnboardingView()
            case .ready:
                MainView()
            }
            if let t = model.toast {
                VStack {
                    Text(t)
                        .font(Theme.body(15, .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Theme.chalk, in: RoundedRectangle(cornerRadius: 10))
                        .shadow(color: Theme.paint, radius: 0, x: 3, y: 3)
                        .padding(.top, 64)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .task { await model.boot() }
    }
}

struct OfflineView: View {
    @EnvironmentObject var model: AppModel
    var reason: String

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            GraffitiTitle(size: 110)
            Text(reason)
                .font(Theme.body(17))
                .foregroundStyle(Theme.chalk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("try again") { Task { model.phase = .loading; await model.boot() } }
                    .buttonStyle(ChalkButton())
                Button("practice mode") { model.startPractice() }
                    .buttonStyle(ChalkButton(fill: Theme.paint))
            }
            Spacer()
            Text("practice mode lets you spray any wall. nothing gets saved or shared.")
                .font(Theme.body(13)).foregroundStyle(Theme.mute)
                .multilineTextAlignment(.center).padding(.horizontal, 40).padding(.bottom, 24)
        }
    }
}
