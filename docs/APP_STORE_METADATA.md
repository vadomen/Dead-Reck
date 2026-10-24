# App Store metadata — FuGPS (uk + en)

Draft for App Store Connect. Sources: `docs/RELEASE_PLAN.md` (Phase 2.4, 2.5, 6, decisions D1-D9), the pages under `site/public/` (en and `uk/`), and the approved UK terminology (`logs/UK_GLOSSARY.md` §9: «Записи», «карти доріг», «мобільний інтернет», ʼ apostrophe, «застосунок»; the OpenStreetMap credit stays English). Limits are checked by hand: characters for name, subtitle and promotional text; UTF-8 bytes for keywords (Cyrillic letter = 2 bytes, comma and space = 1). Recount in App Store Connect when pasting.

## App-level fields

| Field | Value |
|---|---|
| Name | FuGPS (5 characters; availability is checked when the app record is created, D1) |
| Bundle ID | `com.vadomen.fugps` (D2) |
| Primary category | Navigation |
| Secondary category | Utilities |
| Price | Free (D4) |
| Countries | Ukraine only at launch (D3), so no DSA trader status |
| Age rating | Expected 4+ (RELEASE_PLAN 2.5). New questionnaire, including the social-media questions mandatory from September 2026. Answer after the final feature list is known. |
| App Privacy label | "Data Not Collected" (RELEASE_PLAN 2.5). The pack server sees the IP address and requested region of a download; see Open points. |
| Marketing URL | https://fugps.pages.dev/ (uk: https://fugps.pages.dev/uk/) |
| Copyright | "2026 FuGPS" as on the site footer; the legal owner name is for the developer to fill in (Open points) |

Per-language URLs (App Store Connect takes one per localisation):

| | en | uk |
|---|---|---|
| Support URL | https://fugps.pages.dev/support | https://fugps.pages.dev/uk/support |
| Privacy Policy URL | https://fugps.pages.dev/privacy | https://fugps.pages.dev/uk/privacy |

## English (en)

**Subtitle** (25 of 30 characters)

```
Navigation when GPS fails
```

**Promotional text** (158 of 170 characters)

```
Keep your car on the map when GPS drops out or jumps. FuGPS uses your car's speed from an OBD-II adapter and your iPhone's sensors. Free, no accounts, no ads.
```

**Keywords** (91 of 100 bytes; ASCII, so bytes = characters)

```
dead reckoning,OBD-II,ELM327,offline maps,car,speed,BLE,no GPS,tunnel,OBD2,driving,position
```

**Description**

```
FuGPS shows where your car is when GPS is absent or distorted.

It works out the position from the car's own speed, read through an OBD-II Bluetooth LE adapter (ELM327-compatible), and from the motion sensors of your iPhone. When road maps are installed, the position is matched to the roads. A blue ellipse shows how sure the app is, and when GPS is reliable again the position is corrected.

WHAT YOU NEED
• iPhone with iOS 17 or later.
• An OBD-II adapter with Bluetooth LE (ELM327-compatible) plugged into the car. Classic Bluetooth and Wi-Fi ELM327 adapters do not work with iPhone.
• A car that reports its speed over OBD-II. Most petrol cars since 2001 and diesel cars since 2004 do; electric cars often do not.
• A rigid phone mount: the phone must stay in one position during the drive.

WHAT IT DOES AND DOES NOT DO
• It shows your estimated position on a map. It does not plan routes and does not give turn-by-turn directions.
• Without GPS the position is a calculation and can be wrong. Accuracy depends on the car, the mount and the route.
• It only reads data from the car, and cannot change anything in it or clear fault codes.
• Road maps are an optional free download (OpenStreetMap data). Without them the app still works, just without matching to roads. Once downloaded, they work without internet.
• Recording a drive is optional. Recordings stay on your iPhone.
• No accounts, no ads, no analytics.

SAFETY
Connect the adapter and fix the phone in its mount before you start driving. Do not use or hold the phone while driving. FuGPS is an aid, not your only means of navigation: watch the road and follow the traffic rules.

Road data © OpenStreetMap contributors, ODbL.
```

## Українська (uk)

**Підзаголовок** (26 з 30 символів)

```
Навігація, коли GPS зникає
```

**Рекламний текст** (164 з 170 символів)

```
Тримайте авто на карті, коли GPS зникає чи стрибає. FuGPS бере швидкість з авто через OBD-II адаптер і датчики iPhone. Безкоштовно, без облікових записів і реклами.
```

**Ключові слова** (97 зі 100 байтів UTF-8)

```
розрахунок,OBD2,ELM327,без GPS,швидкість,авто,тунель,дороги
```

**Опис**

```
FuGPS показує, де ваше авто, коли GPS зникає або дає неправильну позицію.

Позиція рахується зі швидкості самого авто, яку зчитує OBD-II адаптер з Bluetooth LE (сумісний з ELM327), і з датчиків руху iPhone. Коли встановлено карти доріг, позиція привʼязується до доріг. Синій еліпс показує, наскільки застосунок упевнений, а коли GPS знову надійний, позиція уточнюється.

ЩО ПОТРІБНО
• iPhone з iOS 17 або новішою.
• OBD-II адаптер з Bluetooth LE (сумісний з ELM327), вставлений в авто. Звичайні Bluetooth- і Wi-Fi-адаптери ELM327 з iPhone не працюють.
• Авто, яке передає швидкість через OBD-II. Більшість бензинових авто з 2001 року й дизельних з 2004 року передають; електромобілі часто ні.
• Жорсткий тримач: телефон має стояти нерухомо всю поїздку.

ЩО ВМІЄ І ЧОГО НЕ РОБИТЬ
• Показує розрахункову позицію на карті. Не прокладає маршрутів і не дає покрокових вказівок.
• Без GPS позиція — це розрахунок, він може помилятися. Точність залежить від авто, тримача й маршруту.
• Лише читає дані з авто: нічого в ньому змінити чи стерти коди помилок не може.
• Карти доріг — необовʼязкове безкоштовне завантаження (дані OpenStreetMap). Без них застосунок працює, але без привʼязки до доріг. Після завантаження вони працюють без інтернету.
• Запис поїздки — на вашу вимогу. Записи лишаються на вашому iPhone.
• Без облікових записів, реклами й аналітики.

БЕЗПЕКА
Підключіть адаптер і закріпіть телефон у тримачі до початку поїздки. Не користуйтеся телефоном і не тримайте його в руках за кермом. FuGPS — допоміжний засіб, а не єдиний спосіб орієнтуватися: стежте за дорогою й дотримуйтеся ПДР.

Дані доріг © OpenStreetMap contributors, ODbL.
```

## Review Notes

English (App Review reads English). Fill in the video link before submitting.

```
FuGPS estimates the car's position when GPS is absent or distorted. It uses the car's speed, read over OBD-II, and the phone's motion sensors, and can match the position to offline road maps.

Normal use needs an OBD-II Bluetooth LE adapter (ELM327-compatible) in the car, so you can test without a car using the built-in demo:
1. Open Settings (the gear on the map) -> Developer -> Demo drive (simulated car).
2. The map shows a simulated drive, marked with a DEMO badge.
3. After about a minute the simulated GPS is lost, and the position keeps moving along the roads.
4. Tap Stop demo to return to the normal map.
The demo works offline and stores nothing. A video of a real drive: <VIDEO LINK>

Bluetooth is used only to talk to the OBD-II adapter. Location (When In Use) gives the map position and GPS fixes. Navigate keeps a background location activity session so the position continues while the screen is locked during a drive. No personal data leaves the phone. The map uses Apple Maps (MapKit); road maps are downloaded from our website, which reveals the requested region and the IP address. There are no accounts or analytics. Road maps are optional OpenStreetMap data downloaded from our website.
```

Ukrainian translation, for reference only (App Review reads the English text above; do not paste this into App Store Connect).

```
FuGPS розраховує позицію авто, коли GPS зникає або спотворений. Він використовує швидкість авто, яку зчитує через OBD-II, і датчики руху телефона, а позицію може привʼязувати до карт доріг без інтернету.

Для звичайного користування потрібен OBD-II адаптер з Bluetooth LE (сумісний з ELM327) в авто, тож без авто перевірити можна на вбудованій демо-поїздці:
1. Відкрийте «Налаштування» (шестерня на карті) -> «Розробник» -> «Демо-поїздка (імітація авто)».
2. На карті зʼявляється імітована поїздка з позначкою DEMO.
3. Приблизно за хвилину імітований GPS зникає, а позиція далі рухається дорогами.
4. Торкніться «Зупинити демо», щоб повернутися до звичайної карти.
Демо працює без інтернету й нічого не зберігає. Відео реальної поїздки: <VIDEO LINK>

Bluetooth використовується лише для звʼязку з OBD-II адаптером. Геолокація (під час використання застосунку) дає позицію на карті та дані GPS. Під час навігації застосунок тримає фонову сесію геолокації, щоб позиція не переривалася із заблокованим екраном у поїздці. Особисті дані не залишають телефон. Карта використовує Apple Maps (MapKit); карти доріг завантажуються з нашого сайту, який бачить запитаний регіон та IP-адресу. Облікових записів і аналітики немає. Карти доріг — необовʼязкові дані OpenStreetMap, що завантажуються з нашого сайту.
```

## Open points

1. Routing: the description says the app does not plan routes or give turn-by-turn directions. RELEASE_PLAN and the site describe a position display only, but the draft Review Notes and D7 call background use "turn-by-turn-style navigation" (guideline 2.5.4). Confirm that the app has no routing and settle one wording for the background justification.
2. Demo path: the Review Notes steps (Settings -> Developer -> Demo drive, "Stop demo") are copied from the draft. Check them against the Release build: Developer must be reachable without the 7-tap gate, and the UK labels must match the final catalog. Same for «Зупинити демо» in the UK translation (the glossary has «Демо-поїздка (імітація авто)» only).
3. "Recording a drive is optional" is in the description because the task asked for it, but RELEASE_PLAN says Record is behind the 7-tap gate in Release. Drop that line if Record is not visible to App Review and users.
4. Site wording differs from this draft: the site (en and uk) says GPS is "jammed or spoofed" and the UK landing page uses place names. This draft follows RELEASE_PLAN 2.4 ("absent or distorted"; no electronic-warfare framing). Align the site (prompt 41 item 8).
5. Apostrophe: the UK text here uses ʼ (U+02BC) throughout, per the glossary. The UK site pages still use ASCII `'`.
6. App Privacy label "Data Not Collected" vs the pack server seeing the IP address and region (RELEASE_PLAN 2.5 asks to reflect server logs in the questionnaire). Check what Cloudflare Pages/R2 logs and answer accordingly.
7. Counts were made by hand. Subtitle 25/26, promotional text 158/164, keywords 91 chars (EN) and 97 bytes (UK). Recount before pasting.
8. Name availability (D1), legal copyright holder, video link, screenshots (no real coordinates) and the optional App Preview are not in this file.
9. The UK keywords "розрахунок" stands for dead reckoning (prose term in the glossary); consider whether users would search for it.

