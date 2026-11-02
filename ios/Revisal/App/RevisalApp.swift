import SwiftUI

@main
struct RevisalApp: App {
    @StateObject private var store = Store()
    @StateObject private var ai = AIClient.shared

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
    var body: some View {
        TabView {
            CurriculaView()
                .tabItem { Label("المنهج", systemImage: "books.vertical") }
            BankView(track: .tahsili)
                .tabItem { Label("التحصيلي", systemImage: "graduationcap") }
            BankView(track: .qudurat)
                .tabItem { Label("القدرات", systemImage: "brain.head.profile") }
            SettingsView()
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }
        }
    }
}

/// A review to open from a list.
struct OpenSet: Identifiable, Hashable {
    let id: String
}
