# Privacy release-artifact audit

**Audited:** July 16, 2026  
**Status:** Manifest validated; public/legal artifacts blocked on product/legal authority

## Verified repository evidence

- `ios/Itinera/PrivacyInfo.xcprivacy` passes `plutil -lint` and is included by
  `ios/project.yml` in the app target.
- The manifest declares non-tracking collection of precise location, other user
  content, and user ID for app functionality (with personalization for user
  content).
- Settings can render policy and support links, but the production app supplies
  neither `privacyPolicyURL` nor `supportURL`; no public policy/support URL
  exists in the repository.

## Release decision required

Do not invent or point Settings at placeholder URLs. Product/legal must approve
and publish public privacy, support, and terms destinations; provider-specific
AI disclosure (including subprocessors, retention, deletion, and support) and
App Store privacy answers must agree with the deployed provider configuration.
After that decision, wire only the approved HTTPS destinations, generate an
Xcode privacy report, and validate the App Store Connect metadata against the
actual data flow.
