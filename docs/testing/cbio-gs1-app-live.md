# Cbio GS1 app-live evidence

What the installed debug app does with a real GS1 sensor, on a Pixel 6, with the
driver in this branch. Every number below was read off the device screen after
the capture; nothing is inferred from unit tests.

## Screen evidence

Captured from the running app (`/tmp/og-cbio-live-raw-800.png` after
`sips -Z 800`; full-resolution source `/tmp/og-cbio-live-raw.png`):

| Surface | What it rendered |
| --- | --- |
| Hero card | `5.3` with no unit suffix, stage pill `Live` |
| Hero subtitle | `Sensor raw value · index 10067` |
| Stored-history line | `10067 readings stored · sensor minutes 1–10067` |
| Provisional marker | `Provisional reading. Sensor raw / 10, scale unverified.` |
| History card | `10067 readings`, the same provisional marker, `Sensor history complete. 1 records.` |
| History chart | full ~7 day curve, ranges `3h / 12h / 1d / 3d / ALL` |

An earlier capture of the same session (`/tmp/og-cbio-live-800.png`) is the
before-fix screen: it rendered `101 mg/dL`, which claimed a glucose unit the
protocol does not establish.

## Discovery, link, and stream evidence

- The app's own nearby-sensor scan lists the sensor (`1 sensor found`,
  `Supported sensor · Bluetooth · good signal`); before the transport fix in the
  stacked scan-stream change the same scan hung on "Looking for supported
  sensors nearby…" forever.
- `adb logcat` shows the live characteristic delivering continuously while the
  screen above is up: `[FBP] onCharacteristicChanged: chr: ff31`, roughly every
  500 ms.
- The stored count grows while the screen is open (5680 → 6128 → 10067), and the
  history card ends on `Sensor history complete.`, so the backfill reached the
  sensor's live edge rather than stopping at the first batch.

## Scale and time provenance

- The value shown is the `0x08` record's raw counter divided by ten. The capture
  harness read raw `47..53` from the same field at index `9940..9992`; those are
  `4.7..5.3` on this scale, which is the `5.3` the app renders. App and harness
  therefore agree on the field and the scale; only the unit label differed.
- The unit stays unverified: no reference measurement exists for this sensor, so
  no surface may present the number as mg/dL or mmol/L.
- Reading positions are the protocol's own `index` counter, which advances one
  per stored minute. It carries no epoch, so the app does not invent a
  wall-clock time from it.

## How to reproduce

```bash
export PATH=/Users/fungus/dev/openhealth/.toolchains/flutter/bin:$PATH
cd openhealth
flutter build apk --debug
adb -s <device> install -r -t build/app/outputs/flutter-apk/app-debug.apk
adb -s <device> shell pm grant com.openglucose.app.debug android.permission.BLUETOOTH_SCAN
adb -s <device> shell pm grant com.openglucose.app.debug android.permission.BLUETOOTH_CONNECT
adb -s <device> shell pm grant com.openglucose.app.debug android.permission.ACCESS_FINE_LOCATION
adb -s <device> shell am start -n com.openglucose.app.debug/com.aidex.aidex_flutter.MainActivity
# dashboard -> Connect a sensor -> Connect, then wait for the history window
adb -s <device> shell screencap -p /sdcard/screen.png && adb -s <device> pull /sdcard/screen.png /tmp/screen.png
sips -Z 800 /tmp/screen.png --out /tmp/screen-800.png
```

The device address is never committed; it is passed at run time when a harness
needs discovery bypassed.
