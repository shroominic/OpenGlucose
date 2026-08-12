# OpenGlucose

OpenGlucose is an open-source, local-first Flutter workspace for exploring
continuous glucose monitor (CGM) data. It includes a reference mobile app, a
sensor-agnostic domain API, reusable Bluetooth Low Energy (BLE) contracts, and
an AiDEX/LinX protocol driver.

> [!CAUTION]
> OpenGlucose is early-stage wellness and reference software. It is not a
> medical device and must not be used for diagnosis, medication or insulin
> dosing, treatment decisions, or emergency monitoring. Confirm important
> readings with the sensor manufacturer's supported product and seek qualified
> medical help when appropriate.

## Workspace

| Path                                                     | Responsibility                                                          | Runtime |
| -------------------------------------------------------- | ----------------------------------------------------------------------- | ------- |
| [`openhealth/`](openhealth/)                             | OpenGlucose reference app and demo experience                           | Flutter |
| [`packages/cgm_core/`](packages/cgm_core/)               | Sensor-neutral readings, capabilities, snapshots, and session contracts | Dart    |
| [`packages/cgm_ble/`](packages/cgm_ble/)                 | Platform-neutral BLE transport interfaces                               | Dart    |
| [`packages/cgm_aidex/`](packages/cgm_aidex/)             | AiDEX/LinX protocol, session, history, calibration, and diagnostics     | Dart    |
| [`packages/cgm_ble_flutter/`](packages/cgm_ble_flutter/) | `flutter_blue_plus` adapter for the BLE contracts                       | Flutter |

The package dependency direction and extension rules are documented in the
[architecture overview](docs/architecture/README.md). Mobile builds use the
real BLE-backed driver. Web and widget tests use a deterministic demo driver;
the web build is not evidence of hardware compatibility.

## Development

The approved toolchain is Flutter 3.41.6, Dart 3.11.4, and Java 17. From a
clean checkout:

```sh
make bootstrap
make hooks
make check
```

`make hooks` installs the pinned repository hooks in the current worktree.
Hooks are fast local feedback; `make check` and CI remain authoritative.

Useful focused commands include:

```sh
make format
make format-check
make lint
make typecheck
make test-unit
make test-integration
make test-e2e
make test
make build
```

The device end-to-end lane is explicitly deferred and currently reports that
status instead of claiming hardware coverage. `make check` runs tooling,
formatting, analysis, Dart/Flutter tests, Android and web builds, the negative
Android release-signing gate, and—on macOS—the unsigned iOS build plus native
Runner tests. Focused build targets remain available for iteration. The controls
register assigns the physical-device gap to `@shroominic`; the baseline-default
approval records a time-bounded exception through 2026-11-30, with redacted
manual device evidence still required for affected R2/R3 changes.

Run the demo UI without BLE hardware:

```sh
cd openhealth
flutter run -d chrome
```

Mobile development requires the platform Bluetooth permissions and a supported
sensor. See the [app README](openhealth/README.md) and
[compatibility policy](docs/compatibility.md) before interpreting hardware
results.

## Product boundaries

OpenGlucose is designed around these constraints:

- core use remains available without an account or mandatory cloud service;
- normalized domain models do not depend on a particular sensor vendor;
- protocol logic stays separate from the native BLE plugin boundary;
- portable file/data export and complete deletion are required product goals,
  but neither is a verified complete capability in the current app (the Apple
  Health integration is a separate opt-in write-only path);
- analytics must remain explainable, and optional AI must not become a dosing
  or emergency-decision path.

On native platforms, the baseline moves restricted sensor state to a dedicated
application-support file. The web demo continues to persist its
`shared_preferences` values in the browser's origin-scoped `localStorage`; it is
not a private, encrypted, backup-excluded, or supported health-data store.

The current implementation is not yet a production-readiness claim. Consult
the [architecture decisions](docs/architecture/adr/README.md) for accepted
direction and explicit implementation gaps.

## Contributing and support

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Use the
[issue tracker](https://github.com/shroominic/OpenGlucose/issues) for
reproducible bugs and feature proposals, but never attach glucose history,
sensor identifiers, credentials, or other private health information.

The project-wide risk classes, Definition of Done, and controls register are in
[the engineering standards](docs/engineering/standards.md).

Security vulnerabilities should follow [SECURITY.md](SECURITY.md). General
support expectations are in [SUPPORT.md](SUPPORT.md). This community project
cannot provide medical, emergency, or sensor-manufacturer support.

## License

OpenGlucose source is available under the [MIT License](LICENSE). Dependencies
and platform components retain their own licenses; see [NOTICE.md](NOTICE.md)
and the [dependency policy](docs/dependencies.md).
