import SwiftUI

/// What the About screen says that is not computed: links and the fixed
/// wording. Plain values so tests can check them (UX-31).
enum AboutContent {
    /// The site root, the same host the pack manifest comes from.
    static let siteRoot = "https://fugps.pages.dev"
    static let privacyURL = URL(string: siteRoot + "/privacy")!
    static let supportURL = URL(string: siteRoot + "/support")!
    /// How to get the road data: the site's data page.
    static let dataURL = URL(string: siteRoot + "/data")!
    static let osmCopyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let odblURL = URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!

    /// Every data source the build uses. Nothing else is fetched or bundled.
    static let osmCredit = String(localized: "Road data © OpenStreetMap contributors, available under the Open Database License (ODbL) 1.0.")
    static let osmHowToGet = String(localized: "The road packs are a derived database; get the data on the site's data page.")
    /// The roads of the demo drive, bundled in the app (REL-DEMO): OSM data of
    /// 2026-10-08, a Geofabrik extract. No place name. Starts with the same
    /// credit the map shows during the demo (`DemoDriveRoads.attribution`).
    static let demoMapCredit = String(localized: "\(DemoDriveRoads.attribution), ODbL 1.0. Demo drive map data: OSM data of 2026-10-08 (Geofabrik extract), bundled in the app.")
    static let mapsCredit = String(localized: "The map picture comes from Apple Maps (MapKit).")
    /// Core's package has no dependencies and project.yml adds none.
    static let licences = String(localized: "This app bundles no third-party code.")
    static let attention = String(localized: "Keep your eyes on the road; set up the app before you drive.")
}

/// Settings → About (UX-31). The Version row keeps the 7-tap Diagnostics
/// gate (`DeveloperGate`), so it lives here now.
struct AboutScreen: View {
    let info: AppInfo
    var versionNote: String?
    var onVersionTap: () -> Void = {}

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: info.version)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onVersionTap)
                LabeledContent("Build", value: info.build)
                    .frame(minHeight: 44)
            } footer: {
                if let versionNote { Text(versionNote) }
            }
            Section {
                linkRow("Privacy policy", systemImage: "hand.raised", url: AboutContent.privacyURL)
                linkRow("Support", systemImage: "questionmark.circle", url: AboutContent.supportURL)
            }
            Section("Data and services") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenStreetMap").font(.headline)
                    Text(AboutContent.osmCredit)
                    Text(AboutContent.osmHowToGet).foregroundStyle(.secondary)
                    Text(AboutContent.demoMapCredit).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                // The credits are long sentences (longer still in Ukrainian): never cut one.
                .fixedSize(horizontal: false, vertical: true)
                linkRow("Get the road data", systemImage: "arrow.down.circle", url: AboutContent.dataURL)
                linkRow("OpenStreetMap copyright", systemImage: "c.circle", url: AboutContent.osmCopyrightURL)
                linkRow("ODbL 1.0 licence", systemImage: "doc.text", url: AboutContent.odblURL)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Maps").font(.headline)
                    Text(AboutContent.mapsCredit)
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section("Open-source licences") {
                Text(AboutContent.licences).font(.subheadline)
            }
            Section {
                Label(AboutContent.attention, systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func linkRow(_ title: LocalizedStringKey, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}

#Preview("About") {
    NavigationStack { AboutScreen(info: AppInfo(name: "DriveLogger", version: "0.1.0", build: "1")) }
}

#Preview("About, diagnostics toast") {
    NavigationStack {
        AboutScreen(info: AppInfo(name: "DriveLogger", version: "0.1.0", build: "1"), versionNote: "Developer diagnostics shown")
    }
}
