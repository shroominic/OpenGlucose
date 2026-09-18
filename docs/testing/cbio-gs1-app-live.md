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

## Clock anchor

The counter stays epoch-less; what the app can offer instead is the one
reference it establishes itself. The session writes the sensor clock once per
session (`06 03 LE32(epoch)`), and the surface reads an index as a clock only
when the sensor's own newest record stamp agrees with the app's clock to within
`cbioAnchorTolerance` (3 minutes):

- the anchor is the newest stored position plus that position's own stamp, and
  every older position steps back 60 s per index, as the vendor layout reports
  the counter (`base + 60 * i`);
- the range the anchor speaks for stops at the first hole or counter jump, so a
  position the archive cannot support keeps no timestamp;
- the anchor is published in the snapshot metadata
  (`cgm.cbio.clock.anchorIndex`, `…anchorEpochSeconds`,
  `…anchorCoveredFrom`, `…referenceEpochSeconds`), and the hero states the
  provenance: `Sensor clock set by this app · latest 09:05 (±1 min)`;
- when the clock was never written, or the sensor's stamps disagree with the
  app's clock (the +7 h 28 m counter of #146), no anchor is published and the
  hero says `Sensor clock unsynced · ordered by sensor index, not by clock`
  instead of a placeholder time.

The stored-history caption uses the same anchor:

- `10067 readings stored · sensor minutes 1–10067 · 02:34–19:02` when the
  anchor covers the range, with the window in the device's local zone;
- `… · 3 positions not received` appended whenever the stored positions have
  holes, counted from the range they span;
- without an anchor the caption stays exactly as captured above: count and
  sensor minutes only, with the unsynced line beside it.

Ingest also answers one question only: `inProgress` is true while the sensor is
still pushing and false once the fetch has caught up with the front it offered -
a close on the settle (idle) timer is that evidence, so a hole in the middle no
longer pins a finished fetch to "Fetching sensor history" for the rest of the
session. The hole stays visible in the positions and the caption.

The timestamps therefore inherit the clock this app set on the sensor and its
drift, which the surface states as the ±1 minute of one stored record. The
capture above predates the anchor and shows the unsynced copy; a device
re-capture of the anchored copy is still pending.

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
