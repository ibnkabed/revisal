import SwiftUI

@main
struct RevisalApp: App {
    @StateObject private var store: Store
    @StateObject private var ai = AIClient.shared

    init() {
        // `-demo <screen>`: sample data in its own folder, for the README screenshots (App/Demo.swift)
        _store = StateObject(wrappedValue: Demo.screen == nil ? Store() : Store(folder: MainActor.assumeIsolated { Demo.folder() }))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(ai)
                .environment(\.layoutDirection, .rightToLeft)
                .task { BankStore.preload() }
        }
    }
}

/// Three parts and the settings: the curricula (the student's own books), التحصيلي and القدرات (question banks).
struct RootView: View {
    @State private var tab = Demo.screen == nil ? 0 : Demo.tab
    @State private var demoSet = Demo.openSet.map { OpenSet(id: $0) }

    var body: some View {
        TabView(selection: $tab) {
            CurriculaView()
                .tabItem { Label("المنهج", systemImage: "books.vertical") }.tag(0)
            BankView(track: .tahsili)
                .tabItem { Label("التحصيلي", systemImage: "graduationcap") }.tag(1)
            BankView(track: .qudurat)
                .tabItem { Label("القدرات", systemImage: "brain.head.profile") }.tag(2)
            SettingsView()
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }.tag(3)
        }
        .fullScreenCover(item: $demoSet) { open in RunView(setId: open.id) }
    }
}

/// A review to open from a list.
struct OpenSet: Identifiable, Hashable {
    let id: String
}
