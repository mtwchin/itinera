# Itinera — App Store Readiness Plan

> **Update (2026-07-11):** direction changed to a **native Swift/SwiftUI iOS
> app** (in `ios/`) instead of a Capacitor wrapper, iOS-only for v1. Phase 1
> (backend hardening) is implemented; Phases 2–3 are superseded by the native
> app; Phase 4–5 items still apply — see `ios/README.md` for the live
> submission checklist.

Goal: take the current MVP (React/Vite web frontend + Flask API, with a
partially built FastAPI backend) to an iOS App Store–submittable app, with
Android/Play Store as a fast follow.

## Where the code stands today

- **Frontend** (`frontend/`): single-screen React 19 app. Web-only, no
  routing, no persistence, errors surfaced via `alert()`. Calls the API with
  relative paths (`/api/generate-itinerary`, `/reverse_geocode`), which only
  works when the same origin serves both — this breaks inside a native shell.
  Uses the legacy `google.maps.places.Autocomplete` widget (deprecated for
  new Google Maps customers).
- **Working backend** (`app.py`): Flask, synchronous. Real generation logic
  (TikTok trends → geocode → GPT-4o-mini). No auth, no rate limiting, no
  persistence; `/api/config` returns the Google Maps API key to any caller;
  `/api/expand-maps-url` fetches arbitrary URLs (SSRF); error handlers return
  raw exception strings.
- **New backend** (`backend/`): FastAPI + Celery + Postgres + Redis + OTel
  scaffold with async job endpoints and SSE streaming. The actual pipeline is
  a stub (`backend/workers/tasks.py` returns "agent pipeline not yet
  implemented"); `agents/` and `tools/` are empty; Clerk auth is configured
  but not enforced anywhere.
- **Leftovers**: a second static frontend in `public/` served by Flask;
  CI/CD was recently removed; tests cover only two trivial Flask endpoints.

## Strategy decisions (recommended)

1. **Native shell: Capacitor.** The frontend is already React; Capacitor
   wraps it into real iOS/Android projects with native plugin access
   (geolocation, share sheet, status bar, splash). A React Native rewrite is
   not justified for an MVP.
2. **Ship one backend: harden Flask now, migrate to FastAPI later.** The
   FastAPI stack is the right destination but its pipeline is a stub and it
   drags in Postgres/Redis/Celery/Jaeger — too much surface to productionize
   for a first store release. Freeze `backend/` (keep on the branch, exclude
   from deploy), harden and deploy `app.py`, and migrate post-launch when the
   agent pipeline is actually implemented.
3. **Beat App Store Guideline 4.2 (minimum functionality).** Thin web
   wrappers get rejected. The app needs native-feeling capabilities: locally
   saved itineraries with offline viewing, native share sheet, use-my-location,
   proper touch/safe-area behavior.

## Phase 1 — Backend hardening & deployment (blocker for everything)

- [ ] **Kill the API-key leak**: remove `GET /api/config` (or return only
      non-secret config). The Maps JS key moves to a build-time env var and
      gets **key restrictions** in Google Cloud console (HTTP referrer for
      web; separate keys restricted by iOS bundle ID / Android package +
      SHA-1 for the apps). Server-side geocoding uses a separate,
      IP-restricted key.
- [ ] **Fix SSRF in `/api/expand-maps-url`**: allowlist
      `maps.app.goo.gl` / `goo.gl` / `google.com/maps` hosts before
      following redirects, and cap redirect count. (Or drop the endpoint —
      the current frontend never calls it.)
- [ ] **Input validation**: validate/bound all request fields (trip length
      ≤ 14 days, string lengths, date sanity) with pydantic or marshmallow;
      reject early instead of interpolating raw user input into the LLM
      prompt.
- [ ] **Stop leaking internals**: replace `str(e)` in JSON error responses
      with generic messages + server-side logging.
- [ ] **Rate limiting & abuse control**: every request to
      `/api/generate-itinerary` costs real OpenAI/Maps money and is currently
      anonymous. Add `flask-limiter` (per-IP), plus a per-device quota once
      device identity exists. Set `debug=False` behind gunicorn.
- [ ] **Minimal identity**: issue an anonymous device token on first launch
      (UUID stored on device, registered with the API) and require it on
      generation endpoints. Full accounts (Clerk/Sign in with Apple) can wait
      — avoiding accounts also avoids Apple's account-deletion requirement
      for v1.
- [ ] **Timeout/retry hygiene**: explicit timeouts on OpenAI and Maps calls;
      return 503 with a friendly message on upstream failure instead of the
      simulated-TikTok silent fallback (or label simulated data honestly).
- [ ] **Deploy**: containerize Flask behind gunicorn, deploy to a managed
      host (Fly.io / Render / Railway) with HTTPS at a stable domain
      (e.g. `api.itinera.app`). Secrets via host env, never in the repo.
      Add basic uptime monitoring + Sentry for the backend.
- [ ] **Cleanup**: delete the stale `public/` static site and Flask's
      static-file routes; the Vite app is the only frontend.

## Phase 2 — Frontend productionization

- [ ] **Configurable API base URL** (`VITE_API_BASE_URL`) and a small API
      client module; relative fetches don't work under `capacitor://`.
- [ ] **Replace `alert()`** with `react-hot-toast` (already a dependency)
      and inline error states; add retry affordances.
- [ ] **Migrate off deprecated Places Autocomplete** to
      `PlaceAutocompleteElement` (or server-proxied Places API) before
      Google turns it off for the project's key.
- [ ] **Loading experience**: generation takes ~15–40 s; replace the button
      spinner with a progress screen (staged messages: "finding trending
      spots…", "building your days…") so the app doesn't feel hung.
- [ ] **Local persistence (4.2 requirement + core UX)**: save generated
      itineraries with zustand + Capacitor Preferences/filesystem; add a
      "My Trips" list screen; itineraries viewable offline.
- [ ] **Refine flow**: the backend's `/api/refine-itinerary` is unused —
      expose "tweak this itinerary" in the results screen (cheap win,
      differentiates from a static wrapper).
- [ ] **Mobile-first polish**: safe-area insets (notch), 100dvh viewport,
      44 pt touch targets, `datetime-local`/time inputs replaced with
      mobile-friendly pickers, keyboard-avoidance on the form, dark mode.
- [ ] **Fix map init bugs**: marker/instance state is captured in stale
      closures (`mapMarker` inside listeners); move to refs. Type the Google
      Maps globals instead of `any`.

## Phase 3 — Capacitor packaging

- [ ] Add Capacitor to `frontend/` (`@capacitor/core`, `ios`, `android`);
      set app ID (e.g. `com.itinera.app`), name, and deep-link scheme.
- [ ] Plugins: Geolocation ("use my location" → reverse geocode),
      Share (share itinerary text/link), StatusBar, SplashScreen,
      Preferences, App (back-button handling on Android).
- [ ] Generate icons + splash screens via `@capacitor/assets` from a master
      1024×1024 icon.
- [ ] iOS project config: `NSLocationWhenInUseUsageDescription` string,
      ATS (HTTPS-only API), orientation lock (portrait), minimum iOS 15.
- [ ] Native smoke tests on real devices: cold start, offline launch,
      airplane-mode mid-generation, backgrounding during generation.

## Phase 4 — App Store compliance & content

- [ ] **Apple Developer Program** enrollment ($99/yr) if not done.
- [ ] **Privacy policy** page at a public URL (required) covering: location
      use, trip inputs sent to OpenAI/Google, no sale of data. Add an
      in-app link (Settings/About screen — also needed for support contact).
- [ ] **App Privacy "nutrition label"** in App Store Connect: location
      (coarse, app functionality), identifiers (device ID), user content
      (trip details). Not "tracking" → no ATT prompt needed.
- [ ] **AI-generated content**: label itineraries as AI-generated with a
      "verify hours/availability" disclaimer; Apple increasingly expects
      disclosure, and it manages user expectations for wrong addresses.
- [ ] **TikTok trademark risk (Guideline 5.2)**: don't use "TikTok" in the
      app name, subtitle, or screenshots. In-app copy like "trending on
      social media" is safer; using the TikTok Research API doesn't grant
      trademark usage. Rename the tagline currently shown in the UI.
- [ ] **Age rating** questionnaire (likely 4+/12+), support URL, marketing
      URL.
- [ ] **Metadata & assets**: app name, subtitle, keywords, description,
      6.7" + 6.5" + 5.5" iPhone screenshots (and iPad if targeted — or set
      iPhone-only).
- [ ] **Review notes**: reviewers must be able to generate an itinerary —
      ensure the API has no login wall for them, and note that generation
      takes ~30 s.

## Phase 5 — Quality gate & release

- [ ] **Restore CI** (GitHub Actions): frontend `tsc`+`eslint`+`vite build`;
      backend pytest + ruff; runs on PRs.
- [ ] **Tests that matter**: request-validation tests, rate-limit test, a
      mocked end-to-end generation test, and a couple of frontend component
      tests for the form → results flow.
- [ ] **Crash/analytics**: Sentry (frontend + backend); optional lightweight
      product analytics (screen views, generation success rate).
- [ ] **TestFlight beta**: internal build → 5–10 external testers → fix the
      top issues (expect: slow generation, bad addresses, map quirks).
- [ ] **Submit**, expect one rejection round (commonly 4.2 or privacy
      label mismatches) and budget time to respond.
- [ ] **Android follow-up**: the Capacitor Android project comes nearly free;
      Play Store needs its own data-safety form and store listing.

## Sequencing & rough effort

| Phase | Work | Est. |
|---|---|---|
| 1 | Backend hardening + deploy | ~1 week |
| 2 | Frontend productionization | ~1–1.5 weeks |
| 3 | Capacitor packaging | ~0.5 week |
| 4 | Compliance, policy, metadata | ~0.5 week (parallel with 3) |
| 5 | CI, TestFlight beta, submission | ~1 week + review latency |

Total: roughly **4–5 weeks** to a submitted build for a single developer,
with Apple review adding 1–7 days per round.

## Explicitly deferred (post-v1)

- FastAPI/Celery/Postgres migration and the multi-agent pipeline
  (`backend/`) — resume once the store app is live.
- User accounts (Clerk / Sign in with Apple) and cross-device sync — note
  that adding third-party login later triggers Apple's Sign in with Apple
  and account-deletion requirements.
- Live TikTok Research API integration (currently falls back to simulated
  data; v1 should label recommendations honestly instead).
- In-app purchases / subscriptions; if generation costs need recouping
  later, paywalled generations must use Apple IAP, not external payments.
