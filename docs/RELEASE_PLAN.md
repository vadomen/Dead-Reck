# Plan for preparing DriveLogger for App Store publication

Compiled 2026-10-16 (repo at `16db485`); decisions taken by the user on 2026-10-16. Status notes in *(italics)* were added on 2026-10-17.

Starting decisions (from the user, 2026-10-16):

- Account: Apple Developer Program, **individual**.
- First version: **Navigate (UX-1) as the main mode**; Record and Console stay in Settings for test drives.
- Road packs: **downloaded from a server** (row UX-8 in `docs/BACKLOG_UX.md`).
- Path: TestFlight → App Store (recommendation, awaiting confirmation).

**Decisions taken (2026-10-16):**

| # | Decision |
|---|---|
| D1 | Name **FuGPS** (check availability when creating the App Store Connect record) |
| D2 | Bundle ID **com.vadomen.fugps** (set in `Config/Local.xcconfig`, not in tracked files) |
| D3 | **Ukraine only**: DSA trader status is not needed |
| D4 | **Free**: Free Apps Agreement, no tax or banking forms |
| D5 | **uk + en** |
| D6 | **Cloudflare R2** (+ public bucket / custom domain), free egress |
| D7 | **No background location**: the app works with the screen on (see the consequences in 2.3) |

---

## Phase 0. Decisions (history, options)

| # | Decision | Options / recommendation |
|---|---|---|
| D1 | App Store name (≤ 30 characters) and subtitle | "DriveLogger" is a working name and probably already taken. Check in App Store Connect when the app record is created. The name should describe navigation without GPS, not a logger. |
| D2 | Bundle ID | Currently `com.example.drivelogger`. It goes into the App Store permanently and cannot be changed after the first upload. Set in `Config/Local.xcconfig`, the setting is `PRODUCT_BUNDLE_IDENTIFIER`. |
| D3 | Countries | Ukraine only, or all. For the EU an individual developer must declare trader / non-trader status under the DSA. A trader publishes address and phone number on the app page. Option: exclude the EU at launch. |
| D4 | Price | Free: only the Free Apps Agreement is needed, no tax or banking forms. |
| D5 | Languages | Ukrainian and English (String Catalog; `SWIFT_EMIT_LOC_STRINGS` is already YES). |
| D6 | Pack hosting | GitHub Releases, Cloudflare R2 or S3+CDN. The index is signed (UX-8). The server sees the IP of whoever downloads; this must be reflected in the privacy policy. |
| D7 | Whether Navigate needs background location | If Navigate works with the screen locked, the `location` mode stays and is justified in the Review Notes. If not, it can be removed, reducing the risk of rejection under 2.5.4. |

---

## Phase 1. Product: what must be functionally ready

1. **UX-1 Navigate mode**: autostart on OBD connection, writes no files (the specification is already in BACKLOG_UX).
2. **UX-8 + N3.4**: packs are downloaded into Application Support (not Documents) with the attribute `isExcludedFromBackup = true`. This is a requirement of the iOS Data Storage Guidelines: content that can be downloaded again must not end up in the iCloud backup, and a violation is a known cause of rejection. The `Documents/RoadPacks/` bridge remains only as a developer path.
3. **First launch (onboarding)**: what the app is and what it needs (an ELM327 BLE adapter), permissions one at a time and in context, pack selection and download, a one-time phone-mounting checklist (UX-1 (b)).
4. **"No OBD" scenario** (UX-1 (d)): a plain GPS position with a "Connect OBD" hint. Without it the app is empty for the reviewer (see 2.4, 2.1 App Completeness).
5. **Demo mode for App Review**: a hidden switch (for example Settings → About → 5 taps) that starts `SimulatedOBDLink` and `SimulatedSensors` on the device in a Release build. This is the most reliable way to show the functionality to someone without a car and an adapter. Check that turning it on does not change Record or the log format.
6. **Remove the "research" surfaces for an ordinary user**: Console and Record only in Settings → Developer; the SIMULATED badge visible only in demo mode; `DebugAutoRecord` is already under `#if DEBUG`, check the remaining launch arguments (`uiTab`).
7. **Safety disclaimer**: "do not interact with the phone while driving; the position estimate is approximate". Shown at first launch and in About. The uncertainty ellipse is already honest, which is a plus.

## Phase 2. Compliance with Apple requirements

### 2.1 Technical build requirements
- [ ] Build with Xcode 26+ and the iOS 26 SDK (mandatory from 2026-04-28). `project.yml` already has `xcodeVersion: "27.0"`. Upload only from a release or RC Xcode, because a beta build cannot be submitted for review.
- [ ] **App icon 1024×1024**: `AppIcon.appiconset` currently has only `Contents.json` **without an image**, and an upload with such a build will not pass. An icon is needed, preferably with dark and tinted variants. *(done: ab4ec07, 1024 px universal, no alpha; dark/tinted variants not yet)*
- [ ] `MARKETING_VERSION` 0.1.0 → 1.0.0. `CURRENT_PROJECT_VERSION` must grow with every upload (a script or `agvtool`).
- [ ] The `DriveLogger` scheme → Archive is already set to Release.
- [ ] `ITSAppUsesNonExemptEncryption = NO` in Info.plist (HTTPS only, through the system stack), so that the export question need not be answered on every upload.
- [ ] Keep dSYMs (crash logs in Xcode Organizer). No third-party SDKs.

### 2.2 Privacy manifest (`PrivacyInfo.xcprivacy`) — mandatory
The file is not in the repo. The code uses APIs from the "required reason" categories:

| API in code | Where | Category / reason (check in Apple's documentation) |
|---|---|---|
| `UserDefaults` | App (checklist, OBDLinkService, uiTab) | `NSPrivacyAccessedAPICategoryUserDefaults`, `CA92.1` |
| `ProcessInfo.systemUptime` | Core `SessionClock` | `NSPrivacyAccessedAPICategorySystemBootTime`, `35F9.1` |
| file `.modificationDate` | Core `RoadPackCatalog` | `NSPrivacyAccessedAPICategoryFileTimestamp`, `C617.1` / `3B52.1` |
| `volumeAvailableCapacity*` | Core `DiskSpace` | `NSPrivacyAccessedAPICategoryDiskSpace`, `E174.1` |

Also: `NSPrivacyTracking = false`, no tracking domains, `NSPrivacyCollectedDataTypes` empty if no data leaves the device. Core is statically linked into the app, so a manifest in the app target covers both modules. The file is added to `project.yml` as a resource, after which `xcodegen generate` is needed.

### 2.3 Info.plist: permission texts and background modes
- [ ] Rewrite the purpose strings for an ordinary user instead of "for dead-reckoning research", for example: "…to estimate your position when GPS is unavailable or jammed". Translate the texts (InfoPlist.xcstrings).
- [ ] `NSLocationAlwaysAndWhenInUseUsageDescription` is present, but the code only calls `requestWhenInUseAuthorization`. This is allowed, but the string must match what the app actually does.
- [ ] `UIBackgroundModes` (D7 = no location). Consequences: with the screen locked iOS suspends the app, CoreMotion and GNSS stop → Navigate and **Record** work only with the screen on. Needed: `isIdleTimerDisabled = true` during Navigate/Record; the `lifecycle` event for entering the background is already written, so check that the gap is visible in `inspect_log`. Open question D7a: remove `location` for all builds or only for the App Store (a separate configuration / Info.plist), so that test Record drives keep background operation. `bluetooth-central` without background sensors gives almost nothing; the recommendation is to remove it too. Delete `NSLocationAlwaysAndWhenInUseUsageDescription` (the code only asks for When In Use).
- [ ] `UIFileSharingEnabled`: keep (this is how Record logs reach Files), but make sure Documents holds nothing technical: packs move to Application Support.

### 2.4 App Review Guidelines: risky points
- **2.1 App Completeness.** The reviewer has no car with OBD. What to provide: the demo mode (Phase 1 item 5), a video of a real drive (link in the Review Notes) and instructions in 3–4 steps. This is the **main rejection risk**.
- **4.2 Minimum Functionality.** Without OBD the app must still do something useful (map + GPS) and explain clearly why the adapter is needed.
- **2.5.4 Background modes.** Use only for their intended purpose, otherwise rejection.
- **5.1.1 Data collection.** Privacy policy at a URL and in the app. Permissions are requested in context, without coercion.
- **1.4.1 Physical harm / driving.** A disclaimer, and no actions that demand attention while driving.
- **Wording in the description.** Write "navigation when GPS is absent or distorted"; do not present the app as a countermeasure against electronic warfare.

### 2.5 App Store Connect: legal and metadata
- [ ] **Privacy policy URL** (mandatory). Content: what is recorded on the device, that nothing is sent, the IP on pack download, how to delete data. Hosting: GitHub Pages etc. *(drafted: `site/public/privacy.html`, served from Cloudflare Pages)*
- [ ] **App Privacy (nutrition label)**: "Data Not Collected", if that is the case. If the pack server keeps logs with IPs, that must also be reflected in the questionnaire.
- [ ] **Age rating**: a new questionnaire, including questions about social media (mandatory from September 2026). Expected 4+.
- [ ] **DSA trader status** (if the EU is in the country list, D3).
- [ ] Category: Navigation (primary), Utilities (secondary).
- [ ] Support URL, copyright.

### 2.6 Licences
- [ ] **ODbL for packs.** Public distribution of a pack means it is offered under the ODbL (share-alike for a derived database). Needed: "© OpenStreetMap contributors" with a link on the map when packs are in use (currently attribution exists only in Settings → Diagnostics), a separate About/Licenses screen, and on the server next to the packs the licence text and a way to reproduce a pack (`build_roads` or a description). Check whether share-alike requires opening the tool itself; probably not, describing the method is enough.
- [ ] Do not remove or cover Apple Maps (MapKit) attribution with UI elements.
- [ ] Other dependencies in Core / tools: compile a list of licences for the About screen.

## Phase 3. Pack server (UX-8)
1. Pack build pipeline (`osm/`, `build_roads`) with regular updates (for example monthly): version, sha256, signed index.
2. Hosting + CDN, check of size and cellular policy (Wi-Fi by default).
3. The index signing key stays outside the repo (like the team ID). The public key is embedded in the app.
4. The ODbL licence page and the privacy policy next to it.
5. Failure scenarios: no network, interrupted download, pack failed verification, not enough space (`DiskSpace` already exists).

## Phase 4. Quality before the beta
- [ ] Full `swift test` + app tests + `/review-loop` on the release branch.
- [ ] Memory and battery over 1 hour of Navigate on a device (requirement of UX-1 / PLAN §6). Thermal.
- [ ] Clean install on a phone without dev packs: onboarding → download → drive.
- [ ] Denial of each permission separately: the app does not crash and explains what is lost.
- [ ] Accessibility: Dynamic Type, VoiceOver labels on key buttons, contrast.
- [ ] uk/en localisation, including permission texts.
- [ ] Find and remove every `print`/diagnostic that could reveal coordinates in the system log.

## Phase 5. TestFlight
1. Create the App ID and the app record in App Store Connect (with D1/D2 finalised).
2. Archive → Validate → Upload from Xcode (or `xcodebuild -exportArchive`).
3. **Internal testing** (up to 100 people with roles in the team, no review, a build is available within minutes): the developer and 1–2 other drivers.
4. **External testing** (up to 10,000 via a link): requires Beta App Review, so it is a dress rehearsal for the main review (demo mode, Review Notes).
5. 2–3 weeks: real drives by other people, other cars and adapters, feedback through TestFlight. This is where we find out whether the adapters users buy (cheap ELM327 clones) are compatible with `ELMSession`.

## Phase 6. App Store page
- [ ] iPhone 6.9" screenshots (1320×2868 or 1290×2796), 3–10 of them: map with the ellipse, route along roads, onboarding, OBD connection. No real user coordinates: demo mode or a neutral route.
- [ ] Description, keywords (100 characters), promotional text, uk + en.
- [ ] Optional: App Preview video (15–30 s).
- [ ] Review Notes: what the app is, how to test without a car (demo mode), the video link, an explanation of background modes and Bluetooth.

## Phase 7. Submission and release
1. Submit for Review with **Manual release** (you publish yourself after approval).
2. **Phased release** over 7 days: can be paused if crashes appear.
3. Monitoring: Xcode Organizer (crashes, energy, hangs), reviews.
4. 1.0.1 plan: a quick fix release usually passes review in about 1 day.

---

## The site (`site/`)

Cloudflare Pages. English pages in `site/public/` and a Ukrainian mirror in `site/public/uk/`.

- `index.html`: landing page (the App Store marketing URL).
- `support.html`: the Support URL that App Store Connect requires.
- `privacy.html`: the Privacy Policy URL (2.5, 5.1.1).
- `data.html`: map data: ODbL licence, "© OpenStreetMap contributors", how packs are built (2.6, Phase 3 item 4).
- `vehicles.html`: supported cars and adapters.
- `releases.html`: release notes.
- `404.html`.
- `site/functions/packs/` serves road-pack downloads (Phase 3; packs stored in R2, D6).
- `site/publish_packs.sh` publishes packs and their manifest; it asks before running.

## Order and dependencies (short)

```
D1–D7 decisions ─┬─> UX-1 Navigate ──────────────┐
                 ├─> UX-8/N3.4 packs + server ───┤
                 ├─> Icon, privacy manifest,     ├─> Phase 4 QA ─> TestFlight internal ─> external (Beta Review)
                 │   Info.plist, ITSApp…, About  │                 └─> page, screenshots ─> Submit ─> phased release
                 └─> Privacy policy, ODbL page ──┘
```

In parallel with UX-1, the "cheap" blockers that do not touch navigation can be done right now:
the icon, `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption`, the permission texts, the About/Licenses screen
and the bundle ID. This is one small prompt for ios-ui-engineer / sensors-logging-engineer.

## Open questions
- D1–D7 above.
- Is Record visible to an ordinary user at all (Settings → Developer behind a switch)?
- Should we collect user consent to hand over recordings for research (in the future)? If so, that is already "Data Collected" and a separate section of the privacy policy, so better not in 1.0.
