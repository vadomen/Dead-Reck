import SwiftUI

/// The three tabs, with the screens injected so previews can use fake data.
struct MainTabView<Record: View, Sessions: View, Console: View>: View {
    enum Tab: Int, Hashable { case record, sessions, console }

    @Binding var selection: Tab
    @ViewBuilder var record: () -> Record
    @ViewBuilder var sessions: () -> Sessions
    @ViewBuilder var console: () -> Console

    var body: some View {
        TabView(selection: $selection) {
            record().tabItem { Label("Record", systemImage: "record.circle") }.tag(Tab.record)
            sessions().tabItem { Label("Sessions", systemImage: "list.bullet") }.tag(Tab.sessions)
            console().tabItem { Label("Console", systemImage: "terminal") }.tag(Tab.console)
        }
    }
}

#Preview("Tabs") {
    MainTabView(selection: .constant(.record)) {
        Text("Record")
    } sessions: {
        Text("Sessions")
    } console: {
        Text("Console")
    }
}
