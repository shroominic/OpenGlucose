# Security policy

OpenGlucose handles health-adjacent data, Bluetooth devices, platform
permissions, and release credentials. Avoid exposing users or devices while
investigating and verify that a private intake is available before sending
vulnerability details.

## Report a vulnerability

The intended channel is GitHub
[private vulnerability reporting](https://github.com/shroominic/OpenGlucose/security/advisories/new).
This depends on an external repository setting and has not been verified as
enabled. Before sending details, confirm that GitHub presents a private report
form for this repository.

There is currently no second verified private reporting address. If the GitHub
form is unavailable, do not send vulnerability details through a public issue,
discussion, unsolicited direct message, or guessed address. Retain the details
privately until the repository publishes and verifies a secure fallback. The
repository owner must enable and verify private reporting before an external
release or production-readiness claim.

Do not open a public issue for an undisclosed vulnerability. Do not attach:

- real glucose readings or exports;
- sensor serials, Bluetooth addresses, or pairing material;
- API keys, signing credentials, provisioning profiles, or tokens; or
- identifiers, screenshots, or logs that expose another person.

A useful report contains the affected commit or version, component and
platform, impact, minimal redacted reproduction, preconditions, and a suggested
mitigation if known. Stop testing if it could alter a sensor, expose another
person's data, disrupt a service, or require access you do not own.

## What to expect

A maintainer will acknowledge and triage reports on a best-effort basis. We aim
to agree on severity, affected versions, disclosure timing, and credit with the
reporter. Response and remediation times depend on maintainer availability and
impact; this volunteer project does not promise an emergency-response SLA.

After a fix is available, maintainers should publish an advisory describing
affected versions, mitigations, and upgrade guidance without exposing personal
data or enabling avoidable exploitation.

## Supported versions

Security fixes target the latest tagged release and the current `main` branch.
Older development snapshots are not maintained unless an advisory explicitly
says otherwise.

| Version                         | Security updates         |
| ------------------------------- | ------------------------ |
| Latest tagged release           | Best effort              |
| `main`                          | Fixes are developed here |
| Older tags and feature branches | Not supported            |

## In scope

Examples include unauthorized health-data exposure, insecure backup or export,
credential leakage, unsafe release artifacts, permission bypass, malicious BLE
input causing code execution or persistent corruption, destructive sensor
operations without authorization, and dependency supply-chain compromise.

Incorrect glucose values, stale-data presentation, unit conversion, or unsafe
health guidance may be product-safety defects rather than conventional security
vulnerabilities. When public disclosure could create harm, use only a verified
private channel; otherwise withhold technical details until one exists.

## Safety boundary

This repository cannot provide medical or emergency response. If someone may
be in immediate danger, contact local emergency services and follow guidance
from qualified clinicians and the sensor manufacturer's supported product.
