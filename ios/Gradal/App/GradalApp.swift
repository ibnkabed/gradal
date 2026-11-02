import SwiftUI

@main
struct GradalApp: App {
    @StateObject private var store: Store
    @StateObject private var ai = AIClient.shared

    init() {
        // `-demo <screen>`: sample data in its own folder, for the README screenshots (App/Demo.swift)
        let store = Demo.screen == nil ? Store() : Store(folder: Demo.folder())
        if Demo.screen != nil { MainActor.assumeIsolated { Demo.seed(store) } }
        _store = StateObject(wrappedValue: store)
    }

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
    @State private var tab = Demo.tab

    var body: some View {
        TabView(selection: $tab) {
            QuizListView()
                .tabItem { Label("الاختبارات", systemImage: "checklist") }.tag(0)
            StudentsView()
                .tabItem { Label("الطلاب", systemImage: "person.3") }.tag(1)
            SettingsView()
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }.tag(2)
        }
    }
}
