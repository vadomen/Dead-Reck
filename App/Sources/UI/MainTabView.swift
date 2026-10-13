import SwiftUI

/// The four tabs, with the screens injected so previews can use fake data.
struct MainTabView<Record: View, Map: View, Sessions: View, Console: View>: View {
    /// Raw values follow the tab order, Map first (the `-uiTab` debug override uses them).
    enum Tab: Int, Hashable { case map = 0, record = 1, sessions = 2, console = 3 }

    @Binding var selection: Tab
    @ViewBuilder var record: () -> Record
    @ViewBuilder var map: () -> Map
    @ViewBuilder var sessions: () -> Sessions
    @ViewBuilder var console: () -> Console

    var body: some View {
        TabView(selection: $selection) {
            map().tabItem { Label("Map", systemImage: "map") }.tag(Tab.map)
            record().tabItem { Label("Record", systemImage: "record.circle") }.tag(Tab.record)
            sessions().tabItem { Label("Sessions", systemImage: "list.bullet") }.tag(Tab.sessions)
            console().tabItem { Label("Console", systemImage: "terminal") }.tag(Tab.console)
        }
    }
}

#Preview("Tabs") {
    MainTabView(selection: .constant(.map)) {
        Text("Record")
    } map: {
        Text("Map")
    } sessions: {
        Text("Sessions")
    } console: {
        Text("Console")
    }
}
