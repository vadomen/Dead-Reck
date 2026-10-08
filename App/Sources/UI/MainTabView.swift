import SwiftUI

/// The four tabs, with the screens injected so previews can use fake data.
struct MainTabView<Record: View, Map: View, Sessions: View, Console: View>: View {
    enum Tab: Int, Hashable { case record = 0, sessions = 1, console = 2, map = 3 }

    @Binding var selection: Tab
    @ViewBuilder var record: () -> Record
    @ViewBuilder var map: () -> Map
    @ViewBuilder var sessions: () -> Sessions
    @ViewBuilder var console: () -> Console

    var body: some View {
        TabView(selection: $selection) {
            record().tabItem { Label("Record", systemImage: "record.circle") }.tag(Tab.record)
            map().tabItem { Label("Map", systemImage: "map") }.tag(Tab.map)
            sessions().tabItem { Label("Sessions", systemImage: "list.bullet") }.tag(Tab.sessions)
            console().tabItem { Label("Console", systemImage: "terminal") }.tag(Tab.console)
        }
    }
}

#Preview("Tabs") {
    MainTabView(selection: .constant(.record)) {
        Text("Record")
    } map: {
        Text("Map")
    } sessions: {
        Text("Sessions")
    } console: {
        Text("Console")
    }
}
