# Third-party notices

OpenGlucose source is licensed under the [MIT License](LICENSE). That license
applies only to material owned by OpenGlucose contributors.

Exception: `packages/cgm_libre2_glucose` is a separately GPL-3.0-only package
derived from pinned xdripswift source. Its full license and third-party notices
are in that directory. The optional `libre_glucose_debug_main.dart` executable
links it and is not an MIT-only combined program. Existing MIT files retain
their licenses. See [ADR 0004](docs/architecture/adr/0004-private-libre-glucose-decoder.md)
for the private-bench scope and distribution gates.

The application and packages depend on Flutter, Dart packages, CocoaPods,
Android libraries, and operating-system frameworks that retain their own
copyrights, licenses, and notice requirements. The MIT License does not
relicense those components. A distributor is responsible for preserving every
applicable third-party notice in source and binary distributions.

Interoperability material: `packages/cgm_cbio` carries link material and a
stream masking constant derived from a shipped third-party sensor application.
The derivation record, including the artifact hash and the cross-check against
an independent open-source client, is in
[docs/testing/cbio-gs1-auth-material.md](docs/testing/cbio-gs1-auth-material.md);
the record references the artifact rather than restating the bytes. Because the
material is third-party derived, the same pre-publication inventory and review
steps below apply to it, and its redistribution terms are part of the pending
review logged in [docs/dependencies.md](docs/dependencies.md).

Before publishing an artifact:

1. resolve dependencies from the committed manifests and application
   lockfiles;
2. generate or inspect the license inventory for that exact resolved graph;
3. review packages whose license is missing, nonstandard, reciprocal, or
   incompatible with the intended distribution;
4. include required copyright and attribution text in the distributed app or
   accompanying material; and
5. retain the inventory with the source commit and release evidence.

See [docs/dependencies.md](docs/dependencies.md) for the repository's dependency
review and update policy.

OpenGlucose is independent community software. Product and company names may
be trademarks of their respective owners. References to sensor vendors or
platforms describe interoperability and do not imply endorsement, affiliation,
or a license to vendor branding or proprietary materials.
