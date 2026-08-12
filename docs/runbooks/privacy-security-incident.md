# Privacy and security incident response

Owners: security incident lead and privacy owner. Keep reports need-to-know and
never paste health data, BLE payloads, API keys, or signing keys into tickets or
chat.

1. Triage severity and affected data, users, versions, platforms, providers,
   credentials, and time window. Preserve redacted evidence and a decision log.
2. Contain without destroying evidence: halt distribution/integration, disable
   the affected feature/provider, revoke exposed credentials, and stop further
   collection or sharing.
3. Determine entry point and propagation across app storage, backup, lock
   screen, export, logs, AI provider, build system, and store services.
4. Engage legal/privacy ownership to determine contractual or regulatory
   notification duties and deadlines; do not speculate publicly.
5. Remediate with a reviewed regression test, migration/deletion path where
   needed, and the release process in `docs/releases.md`.
6. Verify containment, rotate secrets, inspect audit records, stage recovery,
   and monitor only redacted operational signals.
7. Close with impact, timeline, notification decision, durable actions, owners,
   and deadlines. Update the controls register and threat/data-flow model.

For a release incident also follow `release-rollback.md`; for corrupted or
unexpectedly restored health data follow `data-recovery.md`.
