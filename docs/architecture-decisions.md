# Sprint 1 architecture decisions

These decisions are the production guardrails for the native Itinera app. They
are intentionally small enough to revisit through later architecture decision
records, but concrete enough to keep the current sprint aligned.

## ADR-001: Native Apple maps stack

**Status:** Accepted

The iOS client uses SwiftUI and MapKit. Production server-side place search,
geocoding, directions, and ETA data will use Apple Maps Server API so that the
place data, identifiers, routes, and rendered maps share one provider contract.

The existing Google Maps integration is transitional development code. It must
not be used to persist Google geocoding content and render it on Apple Maps.
Production startup will require Apple Maps credentials once the server adapter
is enabled.

## ADR-002: No synthetic trends in production

**Status:** Accepted

TikTok Research API is not a commercial production dependency. Itinera will
integrate a licensed commercial trends or place-discovery provider before
making source-specific marketing claims.

Synthetic destinations may be used only in tests and local development. Every
place set must carry source and freshness metadata. Production generation must
return an explicit provider-unavailable error rather than silently labeling
random data as trending.

## ADR-003: Backend-issued identity

**Status:** Accepted

An arbitrary device header is not an identity. New installations obtain a
server-issued anonymous session, store its refresh credential in Keychain, and
use short-lived bearer access tokens. Sign in with Apple will later link the
anonymous principal to an Apple subject without losing its saved trips.

Every itinerary read, stream, mutation, and deletion is owner-scoped. App
Attest will be layered onto costly generation calls later; it does not replace
authentication or authorization.

## ADR-004: Durable asynchronous generation

**Status:** Accepted

Postgres is the source of truth for jobs and itinerary revisions. Creating a
job and recording its outbox event happen in one transaction. A dispatcher
publishes durable outbox events to the work queue, and workers tolerate
at-least-once delivery through idempotent state transitions.

Redis remains a rebuildable cache and rate-limit tier. Mobile progress is
recoverable from the status endpoint; foreground streaming is an enhancement,
not the only copy of job state.

## ADR-005: Modular monolith before services

**Status:** Accepted

The API, worker, and outbox dispatcher remain in one repository and one
versioned domain model. They deploy as separate processes and scale
independently. Service decomposition and multi-region writes require measured
bottlenecks and are not Sprint 1 work.

## ADR-006: Curated public catalog and private saved snapshots

**Status:** Accepted

Popular itineraries live in a separate, trusted catalog. User-generated trips
are private by default and are never promoted, ranked, or exposed as public
content implicitly; their requests may contain exact accommodation details,
dates, group information, and free-form preferences.

Popularity is based on aggregate unique saves, with an editorial rank used only
as a deterministic cold-start tie-breaker. Saving a catalog entry creates an
owner-scoped, completed snapshot in the existing trip library. This keeps saved
content stable if the catalog entry changes or is retired and reuses the same
authorization boundary as generated trips.

## ADR-007: Google Maps export is outbound interoperability

**Status:** Accepted

The app may open a user-selected itinerary route through the documented Google
Maps universal HTTPS URL format. It does not use Google place search or
geocoding, persist Google provider content, or render Google data on an Apple
map, so this does not change ADR-001's provider boundary.

Exports preserve itinerary order and split long routes into browser-safe
segments. Universal links require no API key and fall back to the browser when
Google Maps is not installed.
