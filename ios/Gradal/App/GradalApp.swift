import SwiftUI

@main
struct GradalApp: App {
    @StateObject private var store = Store()
    @StateObject private var ai = AIClient.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(ai)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}

/// Three tabs: the tests, the class lists, the settings (AI, school header, backup).
struct RootView: View {
    var body: some View {
        TabView {
            QuizListView()
                .tabItem { Label("الاختبارات", systemImage: "checklist") }
            StudentsView()
                .tabItem { Label("الطلاب", systemImage: "person.3") }
            SettingsView()
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }
        }
    }
}
