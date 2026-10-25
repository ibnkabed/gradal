import SwiftUI

@main
struct GradalApp: App {
    @StateObject private var store = Store()
    @StateObject private var companion = Companion()
    @StateObject private var prints = Prints.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(companion)
                .environmentObject(prints)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var companion: Companion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            QuizListView()
                .tabItem { Label("الاختبارات", systemImage: "checklist") }
            SettingsView()
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }
        }
        .onAppear {
            let s = store
            let c = companion
            s.onLocalChange = { [weak s, weak c] in
                guard let s, let c else { return }
                c.scheduleSync(s)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { companion.autoSync(store) }
        }
    }
}
