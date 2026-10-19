# Competitor: Orientyr (Орієнтир)

Analysis of 2026-10-18: app screenshots (Orientyr 1.0.2, build 14) and the site
https://orientyr.app/. **Why** we would change things. **What** we change lives
as rows in [`BACKLOG_UX.md`](BACKLOG_UX.md) (UX-19 … UX-31, SITE-1); each
recommendation below names its row, and each row links back here.

Facts about Orientyr are as shown in its app and on its site on 2026-10-18, not
verified further.

## 1. What Orientyr is

- "Навігатор без GPS": a full navigator (search, routes, voice) that keeps the
  arrow on the road when GPS is lost or spoofed. iPhone (iOS 15+), live in the
  App Store (id6817061432), public TestFlight; Android "coming soon".
- **No OBD, no hardware.** Position from phone sensors plus the stored road map.
- Free, no account, no ads. Trip and search history on the phone; traffic
  reports and markers go anonymously without separate consent; full trip
  recordings only with consent (opt-in toggle, auto-record only with it).
- Their FAQ: dead reckoning "works best where many drivers have already
  travelled, currently Kyiv and its surroundings".

## 2. Strategic conclusions

1. **Our moat is OBD speed; our barrier is also OBD.** Orientyr needs nothing
   but a phone. "Works without an adapter, more accurate with one" is the
   position to aim for, which raises NAV-NOOBD → UX-7 in priority
   (see BACKLOG_UX "Order").
2. **They have a network effect.** Learned speeds, junctions and road heights
   from many drivers improve their DR where people drive. Over time that
   narrows our accuracy edge → [UX-27](BACKLOG_UX.md) (on-device learning first).
3. **Their headline promise is our UX-9:** "if GPS jumps elsewhere, the app
   stays on your road". We have it manual and open; they lead with it.
4. **Job to be done is "get there", not "see a dot".** Without destination
   search and guidance the app is opened only by enthusiasts → UX-19.

## 3. App: what they have, ranked by value to the driver

| # | Feature in Orientyr | Our state (2026-10-18) | Row |
|---|---|---|---|
| 1 | Search ("Куди їдемо?"), home/work, recents, offline routing and address search (OSM + Visicom for villages, Photon online), voice turn prompts, online route via TomTom outside offline maps | none | [UX-19](BACKLOG_UX.md) |
| 2 | Works with no hardware | NAV-NOOBD / UX-7 open | NAV-NOOBD, UX-7 (existing) |
| 3 | "відновлено стан (<1 хв тому)": estimate restored after a relaunch | lost on relaunch | [UX-20](BACKLOG_UX.md) |
| 4 | Speed cameras (751, National Police on data.gov.ua, CC BY 4.0); one short overspeed beep + red speedometer; vibration near cameras when voice is off | none | [UX-21](BACKLOG_UX.md) |
| 5 | GPS state chip ("GPS гаразд"); optional voice "GPS lost / back", at most once per 5 min | speed + source chip only (UX-5) | [UX-22](BACKLOG_UX.md) |
| 6 | Terrain elevation in district packs (Terrain Tiles: SRTM, GMTED2010, ETOPO1) "to check the GPS signal" | none | [UX-23](BACKLOG_UX.md) → UX-9 (b) |
| 7 | Manual correction: "faster / slower" buttons move the car; "shift along route" ±100 m (configurable) | double-tap pin | [UX-24](BACKLOG_UX.md) |
| 8 | Offline vector basemap (MapLibre GL, OpenFreeMap/OpenMapTiles) in the same region packs | MapKit basemap (online) | [UX-25](BACKLOG_UX.md) |
| 9 | Packs by oblast and raion (sizes, km of roads), "Ви зараз у: Київ", auto-download raions along the route (≤ 300 MB/day) | UX-8 by region | [UX-26](BACKLOG_UX.md) |
| 10 | "My learned data": speeds, junctions and road heights from your drives, on the phone, resettable | none | [UX-27](BACKLOG_UX.md) |
| 11 | Traffic: typical speeds, known wait at 1573 junctions, anonymous crowd data, KMDA closures/repairs (data.gov.ua) | none | [UX-28](BACKLOG_UX.md) |
| 12 | Polish: map theme auto by sunrise/sunset; 3D buildings, translucent where they hide the road and arrow; voice choice incl. a recorded voice (2 MB), ducking music / pausing podcasts, lock-screen voice test | none | [UX-29](BACKLOG_UX.md) |
| 13 | Driver reports (camera, crash, hazard, jam, closure, repair, pothole, weather, "no way through") with lifetimes and confirmation rules; driver-contributed map (house numbers, streets, POIs) separate from OSM | none | [UX-30](BACKLOG_UX.md) |
| 14 | Paid parking zones in Kyiv (Kyiv open data) | none | not taken (low value) |

**Release hygiene, not ranked:** an About screen with version/build, install ID
(copyable), privacy policy and support links, a "Data and services" list with
every source and licence (OSM ODbL with "machine-readable copy on request"),
software licences, and a driver-attention disclaimer. We show the OSM credit
only in Maps → [UX-31](BACKLOG_UX.md).

**Do not copy:** the "Wi-Fi only" toggle whose own footnote says auto-download
will not work with it on; long explanatory text on every screen.

## 4. Site: orientyr.app vs fugps.pages.dev

What they do well: hero about the driver's pain ("arrow on Khreshchatyk, not at
the airport"), five captioned screenshots, a nine-question FAQ, repeated
App Store button, TestFlight for early builds, Instagram/Threads, "navigation
aid, watch the road" disclaimer, uk + en.

What we did well and keep: the compatible-vehicles page (protocols, tested
car, "read-only, fixed list of commands"), "no servers, no analytics",
release notes.

Applied on 2026-10-18 to `site/public/uk/index.html` (+ `style.css`):

1. Hero about the driver's problem; technology moved to "How it works".
2. "Why more accurate with the adapter", with 15–20 m after ~2 km without GPS
   (clean and clean-long acceptance runs with roads, docs/NAVIGATION.md
   "N3.3: roads live"), test conditions stated.
3. "What you need" as steps, with the tested adapter and the BLE warning.
4. Three screenshot slots, commented out, captions ready.
5. FAQ, eight questions, only what the app does today.
6. CTA "Become a tester" (mailto); an App Store button commented in.
7. Disclaimer rewritten as "navigation aid".

Open → [SITE-1](BACKLOG_UX.md): adapter price and shop link, screenshots, App
Store / TestFlight links, EN page, social accounts.
