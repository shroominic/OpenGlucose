# Windows preview

The Windows build is an unsigned, portable preview for controlled personal
testing. It is not a supported release and is not a medical device. Do not use
it for diagnosis, dosing, treatment, or emergency decisions.

## Requirements

- A 64-bit Windows 10 or Windows 11 computer with Bluetooth Low Energy.
- The complete `OpenGlucose` folder from the preview ZIP. The executable does
  not run by itself because it needs the adjacent DLL and `data` files.
- An AiDEX sensor that is not still connected or bonded to another device.

The Windows SmartScreen warning is expected because the preview is not signed.
Confirm the archive SHA-256 before you run it. In PowerShell:

```powershell
Get-FileHash .\openglucose-*-windows-x64-preview.zip -Algorithm SHA256
```

Compare the result with the adjacent `.sha256` file. Extract the full ZIP and
start `OpenGlucose\OpenGlucose.exe`.

## Move one sensor safely

An AiDEX transmitter can have one Bluetooth bond. If the sensor is bonded to a
phone or another computer, first use **Move sensor to another phone or
computer** in OpenGlucose on that device. Closing the app or using ordinary
**Disconnect** does not move the bond. Keep the previous device disconnected
and keep the new computer close to the sensor while Windows shows its pairing
prompt.

Do not reset or restart an active sensor as a generic recovery step. Cancel the
pairing attempt if you cannot safely complete the transfer on the previous
device.

## Preview limits

- The repository builds the preview on a Windows GitHub Actions runner from an
  explicit existing `vMAJOR.MINOR.PATCH` tag and records the source commit,
  exact tag ref, app version/build, and checksum. The workflow does not publish
  or change a GitHub Release. After verification, a maintainer can attach the
  exact ZIP and `.sha256` file to that same stable release as a **Windows
  Preview** asset.
- No physical Windows/AiDEX evidence is recorded yet. A successful compile or
  demo run is not proof of sensor compatibility.
- The preview is unsigned and has no installer, automatic update, or uninstall
  entry. Delete the extracted folder only after you no longer need the app;
  local application data is separate from that folder.
- Experimental AI settings are hidden in this preview because the current
  production SQLite backend is mobile-only. This prevents a user from entering
  credentials for a workflow that Windows cannot yet persist safely.
- Keep OpenGlucose running while you use the sensor. Windows background and
  closed-app monitoring are not implemented or claimed by this preview.
- The portable folder includes the redistributable Microsoft C++ runtime files
  selected by the pinned Windows build toolchain; keep them beside the app.
- OpenGlucose keeps sensor state, glucose history, and its optional health
  database in per-user, non-roaming Windows LocalAppData. Windows does not give
  this unpackaged preview the same verified backup-exclusion control as iOS;
  confirm the computer's backup policy before testing sensitive data. Do not
  send logs, screenshots, or exports that contain sensor identifiers or health
  data.
- The pinned WinRT dependency contains native identifier-bearing debug calls.
  The Windows build disables those calls at compile time. A successful
  `windows-latest` compile is mandatory because macOS cannot verify that native
  control.
- Commercial use requires an independent review of the FlutterBluePlus license
  and, where applicable, a commercial license. See the recorded
  [dependency review](dependency-reviews/flutter-blue-plus-winrt.md).

Windows support can be claimed only after the portable bundle builds from a
clean CI checkout and redacted physical evidence records scan, pairing, GATT
discovery, subscription, readings, reconnect, and explicit sensor transfer.
Windows uses the same durable `CgmBondTransferSession` controller and confirmed
UI flow as Android. The Windows app does not call the unsafe-admin API to move
a bond.
