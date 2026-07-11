# Itinera iOS

Native SwiftUI app (iOS 17+). Talks to the Flask API (`app.py` at the repo
root); destination search and maps are Apple MapKit, so **no Google Maps key
ships in the app**.

## Structure

```
ios/
├── Itinera.xcodeproj        Xcode 16 project (synchronized folder format)
├── Support/Info.plist       Extra Info.plist keys (merged into the generated plist)
└── Itinera/
    ├── ItineraApp.swift     Entry point, tab bar (Plan / My Trips / About)
    ├── Models/              API + persistence models (tolerant of missing LLM fields)
    ├── Networking/          APIClient (async/await, envelope decoding)
    ├── Stores/              TripStore — saved trips as JSON in Documents (offline)
    ├── Search/              MKLocalSearchCompleter wrapper for destination picking
    ├── Views/               PlanView, DestinationSearchView, GeneratingView,
    │                        ItineraryView, TripsView, AboutView
    └── Assets.xcassets      AppIcon (placeholder), AccentColor
```

## Run locally

1. Start the backend from the repo root (needs `OPENAI_API_KEY` and
   `GOOGLE_MAPS_API_KEY` in `.env`):

   ```bash
   pip install -r requirements.txt
   python app.py        # http://localhost:5000
   ```

2. Open `ios/Itinera.xcodeproj` in **Xcode 16 or newer**, pick an iPhone
   simulator, and run. The app defaults to `http://localhost:5000` when no
   production URL is reachable (ATS allows local networking).

3. On a physical device, set the API URL in **About → Developer** to your
   Mac's LAN address (e.g. `http://192.168.1.20:5000`).

## Point at production

Edit `ItineraAPIBaseURL` in `Support/Info.plist` to the deployed API's HTTPS
URL. The About → Developer override (stored in UserDefaults) takes precedence
at runtime and is meant for testing only.

## Before submitting — checklist

Config in this repo (placeholders to replace):

- [ ] `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.itinera.app`) — set to a
      bundle ID you own, and select your team in Signing & Capabilities.
- [ ] `ItineraAPIBaseURL` in `Support/Info.plist` — real HTTPS API URL.
- [ ] Privacy Policy + support links in `AboutView.swift` — real hosted URLs.
- [ ] `AppIcon.png` — replace the generated placeholder with a designed icon.
- [ ] Consider removing the Developer section in `AboutView` (or wrapping it
      in `#if DEBUG`) for the release build.

App Store Connect:

- [ ] Create the app record with the bundle ID; version 1.0.
- [ ] **App Privacy labels**: data collected = user content (trip inputs,
      sent to the server for generation; not linked to identity, not used
      for tracking). Saved trips are on-device only. No ATT prompt needed.
- [ ] Age rating questionnaire (expect 4+).
- [ ] Screenshots: 6.9" and 6.5" iPhone sets (Plan form, generating,
      itinerary with map, My Trips).
- [ ] Description/keywords — do **not** use "TikTok" in the app name,
      subtitle, or screenshots (trademark, Guideline 5.2).
- [ ] Review notes: mention generation takes ~30–60 s and no account is
      required.
- [ ] TestFlight an internal build first; verify on a real device over the
      production API.

Backend prerequisites (see `docs/APP_STORE_READINESS_PLAN.md`):

- [ ] API deployed behind HTTPS with rate limiting enabled.
- [ ] `GOOGLE_MAPS_API_KEY` restricted server-side (IP allowlist) in Google
      Cloud console.

## Notes

- Export compliance: `ITSAppUsesNonExemptEncryption = NO` is set (standard
  HTTPS only), so uploads skip the encryption questionnaire.
- Guideline 4.2 (minimum functionality) is addressed by native UX: MapKit
  destination search and day maps, offline saved trips, share sheet export.
- No login and no third-party sign-in in v1, so Sign in with Apple and
  account-deletion requirements don't apply yet.
