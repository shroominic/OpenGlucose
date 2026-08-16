# FlutterBluePlus WinRT dependency review

- Owner: `@shroominic`
- Risk: R2 (BLE, native platform integration, device bond state)
- Reviewed graph: `flutter_blue_plus` 2.2.1,
  `flutter_blue_plus_platform_interface` 8.2.1, and
  `flutter_blue_plus_winrt` 0.0.18
- Resolved evidence: `openhealth/pubspec.lock`

## Need and implementation

OpenGlucose already uses FlutterBluePlus on Android and iOS. The endorsed
Windows implementation uses Windows Runtime Bluetooth APIs for scanning,
connections, GATT operations, notifications, and pairing. Adding a second BLE
stack would duplicate protocol transport and increase privacy and maintenance
risk.

FlutterBluePlus 2.2.1 rejects its high-level bond methods outside Android even
though its federated Windows plugin implements bond operations. The Windows
adapter therefore calls the public federated platform interface directly and
verifies the final bond state. The platform-interface version is pinned to the
exact application lockfile version. No identifiers or native error text enter
support messages.

The reviewed WinRT plugin ignores its native log-level request and otherwise
writes Bluetooth names and addresses to `OutputDebugStringA`. The Windows
runner applies a target-specific forced include that compiles those native
debug calls to no-ops. The Windows CI compile and workflow contract are release
gates for this control. Remove the control only after a pinned upstream version
implements and verifies equivalent identifier-safe native logging.

## Permissions, data, and behavior

- Native access: Windows Bluetooth adapter, nearby BLE advertisements, GATT
  services and characteristics, and Windows device-pairing state.
- Network destinations and telemetry: none introduced by the WinRT plugin.
- Background services: none introduced by this change.
- Storage: no additional plugin storage; on Windows, OpenGlucose retains
  restricted state in per-user, non-roaming LocalAppData rather than the
  roaming application-support path.
- Failure: pairing, state-verification, timeout, or disconnection errors fail
  closed. Normal disconnect and retry do not remove a bond. Bond removal stays
  behind the shared, confirmed `CgmBondTransferSession` action and never calls
  the unsafe-admin API directly from application UI.

## Maintenance, provenance, and exit

`flutter_blue_plus_winrt` is a small federated implementation from an
unverified pub.dev publisher. Version 0.0.18 is already present in the committed
application graph and is MIT licensed. The direct platform-interface use is a
deliberate compatibility bridge; its tests make the coupling visible. The exit
path is to remove that bridge when FlutterBluePlus exposes supported Windows
bond APIs, or replace the WinRT adapter behind `BleTransport` without changing
the AiDEX protocol package.

The FlutterBluePlus 2.2.1 license permits personal, registered nonprofit, and
accredited educational use under its open-use terms, but requires a commercial
license for use by or for a for-profit organization. The portable preview must
not be used or distributed for commercial purposes until the accountable owner
confirms the intended distribution model and license. Flutter's generated
license inventory remains in the application assets and is exposed through the
in-app license page; the portable bundle also includes repository notices.

## Verification and remaining gates

Deterministic tests cover existing bond, new bond, rejection, state races,
explicit removal, and failed removal verification. macOS cannot compile or
exercise WinRT or prove the forced-include control. A clean `windows-latest`
build, inspection that the plugin target received the suppression option, and
redacted physical AiDEX evidence are required before support or
production-release claims. Rollback is to remove the Windows runner and
federated bond bridge while leaving mobile behavior unchanged.
