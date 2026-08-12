# Maintainers and ownership

OpenGlucose currently has one accountable maintainer. Ownership should expand
as regular contributors demonstrate sustained responsibility for a component.

| Area                                                | Accountable owner                              | Review concerns                                                       |
| --------------------------------------------------- | ---------------------------------------------- | --------------------------------------------------------------------- |
| Repository and product direction                    | [`@shroominic`](https://github.com/shroominic) | Scope, roadmap, licensing, governance                                 |
| `openhealth/` app and native platforms              | `@shroominic`                                  | UX, accessibility, health-data handling, permissions, releases        |
| `packages/cgm_core/`                                | `@shroominic`                                  | Sensor-neutral contracts, units, time, compatibility                  |
| `packages/cgm_ble/` and `packages/cgm_ble_flutter/` | `@shroominic`                                  | BLE lifecycle, permissions, identifiers, native compatibility         |
| `packages/cgm_aidex/`                               | `@shroominic`                                  | Protocol correctness, destructive operations, vendor interoperability |
| CI, release, security, and dependencies             | `@shroominic`                                  | Least privilege, provenance, supply chain, recovery                   |

## Maintainer responsibilities

Maintainers are expected to:

- triage issues and private vulnerability reports;
- protect package boundaries and public compatibility;
- require evidence proportionate to health, privacy, security, and release risk;
- keep required checks and branch controls functional when externally enabled;
- review dependencies, licenses, release provenance, and sensitive-data paths;
- document decisions, releases, deprecations, and time-bounded exceptions; and
- avoid merging their own high-risk work without independent review whenever a
  qualified reviewer is available.

## Review and merge policy

Meaningful changes require independent review and passing required checks.
High-risk changes should be reviewed by the owner of the affected control and
must include recovery or rollback evidence. CODEOWNERS records requested review
coverage, but enforcement depends on GitHub repository settings and remains
unverified until an administrator enables and verifies it.

Maintainers may merge low-risk documentation or mechanical changes after
appropriate checks. Failed checks or unresolved critical findings require a
documented waiver with scope, owner, reason, compensating evidence, and expiry;
silently bypassing them is not acceptable.

## Adding or removing maintainers

A maintainer change should be proposed in a pull request updating this file and
`.github/CODEOWNERS`. The review should consider contribution history,
component expertise, security and privacy judgment, availability, conflicts of
interest, and acceptance by the candidate. Remove inactive or unavailable
owners promptly so review requests and private escalations have a real path.
