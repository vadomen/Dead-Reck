import SwiftUI

/// The tabs, with the screens injected so previews can use fake data.
struct MainTabView<Map: View, Sessions: View, Settings: View>: View {
    @Binding var selection: AppTab
    @ViewBuilder var map: () -> Map
    @ViewBuilder var sessions: () -> Sessions
    @ViewBuilder var settings: () -> Settings

    var body: some View {
        TabView(selection: $selection) {
            map().tabItem { Label("Map", systemImage: "map") }.tag(AppTab.map)
            sessions().tabItem { Label("Sessions", systemImage: "list.bullet") }.tag(AppTab.sessions)
            settings().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
    }
}

#Preview("Tabs") {
    MainTabView(selection: .constant(.map)) {
        Text("Map")
    } sessions: {
        Text("Sessions")
    } settings: {
        Text("Settings")
    }
}
