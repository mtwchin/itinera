# P23 — API privacy and browser-security headers

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

Every normal API response now defaults to:

- `Cache-Control: no-store`, preventing intermediary/browser persistence of
  authenticated itinerary and token responses;
- `Referrer-Policy: no-referrer`;
- `X-Content-Type-Options: nosniff`;
- `X-Frame-Options: DENY`.

Existing route-specific values are preserved rather than overwritten. The
headers are applied with the server-generated request-correlation middleware,
so ordinary failures and successful responses get the same privacy posture.

## Boundary

This API-only control is not a replacement for website Content Security Policy,
HSTS/domain policy, or the pending hosting-proxy trust decision. Render’s
documented client-IP forwarding must be validated against the deployed edge
before changing its proxy configuration.
