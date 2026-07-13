# Itinera campaign site

The public feature showcase for Itinera, built as a standalone Vinext site so
the campaign surface can be released independently from the native iOS app and
FastAPI service.

## Local development

Requires Node.js `>=22.13.0`.

```bash
npm ci
npm run dev
```

The local site is served at `http://localhost:3000` by default.

## Verification

```bash
npm run lint
npm test
```

`npm test` produces the Cloudflare Worker-compatible build and verifies the
server-rendered campaign content and social metadata.

## Structure

- `app/page.tsx` contains the one-page campaign story and product mockups.
- `app/globals.css` contains the responsive Atlas Field Notes visual system.
- `public/app-icon.png` reuses the native Itinera app icon.
- `public/og.png` is the campaign-specific social preview card.
- `.openai/hosting.json` contains Sites deployment metadata.

This surface is marketing-only. It does not add another product client, access
private trip data, or connect to the authenticated Itinera API.
