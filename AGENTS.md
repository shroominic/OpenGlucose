# Repository instructions for coding agents

Human-facing engineering standards are authoritative. Read these before
planning or changing the repository:

1. [`CONTRIBUTING.md`](CONTRIBUTING.md) for setup and contribution flow, plus
   [`docs/engineering/standards.md`](docs/engineering/standards.md) for the
   authoritative risk classes, controls register, and Definition of Done.
2. [`docs/architecture/README.md`](docs/architecture/README.md) and accepted
   [ADRs](docs/architecture/adr/README.md) for dependency direction and durable
   decisions.
3. [`docs/compatibility.md`](docs/compatibility.md) before changing a public
   package, platform floor, serialized data, or sensor claim.
4. [`docs/dependencies.md`](docs/dependencies.md) before changing manifests,
   lockfiles, plugins, native pods, or Gradle dependencies.
5. [`SECURITY.md`](SECURITY.md) for sensitive findings and
   [`MAINTAINERS.md`](MAINTAINERS.md) for ownership.

Use the repository's native command contract and preserve existing tools. Work
in an isolated branch/worktree for meaningful changes, keep unrelated user work
untouched, use `apply_patch` for edits, and report exact verification evidence.

Never commit or expose health data, sensor identifiers, device addresses,
credentials, signing material, or private diagnostic artifacts. OpenGlucose is
wellness/reference software: do not create diagnosis, dosing, treatment, or
emergency-decision behavior.
