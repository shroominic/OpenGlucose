# Release rollback and revocation

Owner: release owner. Escalate privacy/security events to the security and
privacy owners immediately.

1. Stop the release job and record source commit, version, artifact digest,
   signing identity, target, timestamps, and observed impact.
2. Stop distribution: expire or stop testing the exact affected TestFlight
   build and remove only that build's approved-group association where the
   provider supports it, or halt the staged store rollout. Do not delete the
   tester group or evidence needed for investigation.
3. If a credential may be exposed, revoke/rotate it at the provider first, then
   invalidate cached copies and audit its use.
4. Decide whether the safest recovery is withdrawal, a previous known-good
   version, or a forward fix. Mobile-store rollback may be limited; document the
   actual store action and user communication.
5. Build the remedy from a clean reviewed commit using `docs/releases.md`.
   Never relabel or reuse an existing artifact.
6. Verify signatures, identifiers, entitlements, version, digest, critical
   journeys, and the original failure regression before staged redistribution.
7. Record closure, affected users/versions, notification decision, follow-up
   owner, and due date. Add a regression control without weakening the gate.
