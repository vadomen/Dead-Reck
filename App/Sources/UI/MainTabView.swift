import SwiftUI

/// The tabs, with the screens injected so previews can use fake data.
struct MainTabView<Map: View, Sessions: View, Settings: View>: View {
    @Binding var selection: AppTab
    @ViewBuilder var map: () -> Map
    @ViewBuilder var sessions: () -> Sessions
    @ViewBuilder var settings: () -> Settings

    var body: some View {
        TabView(selection: $selection) {
            map().opaqueTabBar().tabItem { Label("Map", systemImage: "map") }.tag(AppTab.map)
            sessions().opaqueTabBar().tabItem { Label("Sessions", systemImage: "list.bullet") }.tag(AppTab.sessions)
            settings().opaqueTabBar().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
    }
}

private extension View {
    /// An opaque system-background tab bar. The translucent default blurs the
    /// map under it and the selected tab's accent colour washes out (light
    /// and dark); the standard bar colour keeps the system look and reads
    /// clearly at arm's length.
    func opaqueTabBar() -> some View {
        toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(Color(.systemBackground), for: .tabBar)
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
