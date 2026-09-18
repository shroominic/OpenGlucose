# Why the GS1 sensor looks invisible on Android

A GS1 sensor that streams for hours can still be undiscoverable to the next
scan. On 2026-09-18 the same phone, the same harness and the same sensor went
from repeated `aborted_no_target` to a completed session with one variable
changed: **the state of the phone's display**. This record pins that down,
because "the sensor is sometimes invisible" is a field condition onboarding has
to survive, and the wrong fix (retrying harder, or blaming the sensor) costs a
user their pairing flow.

## The finding

The sensor was advertising the whole time. What failed was the receiver's scan
policy:

- **Screen on** — the FF30-filtered pass finds the sensor in about 20 s and the
  harness reports `CBIO-A scan-source=filtered`, then `CBIO-A target-found`.
- **Screen off** — the same app, still the foreground activity, burns the full
  80 s acquisition budget and reports `CBIO-A abort=no-target`. Android refuses
  the unfiltered fallback outright, three times in one budget:

  ```
  W BtScan.ScanManager: Cannot start unfiltered scan in screen-off.
    This scan will be resumed later for
    ScanClient(com.openglucose.app.debugid=1,
    mode[LOW_LATENCY, used=LOW_LATENCY])
  ```

That warning names only the unfiltered pass, and the unfiltered pass is exactly
the fallback this sensor needs when its advertisement does not carry the service
UUID in the field Android filters on (see the note in
`_acquireTargetId`). So a screen-off phone is not "a scan that found nothing" —
it is a scan the platform declined to run.

## The A/B, in order

| time (UTC+7) | display | app state | result | evidence |
|---|---|---|---|---|
| 17:16:39–17:18:08 | off (`mWakefulness=Dozing`) | foreground | `aborted_no_target` after 88 s | `target_missing` |
| 17:40:55–17:47:25 | on (kept awake) | foreground | **`completed`** | 719 notifications, raw 1..10969 |
| 17:49:32–17:50:17 | off (`KEYCODE_SLEEP`) | foreground | `aborted_no_target` after 80 s | 3× screen-off refusal |
| 17:50:34–17:51:06 | on | foreground | target acquired, `auth-ok source=serial-2a25` | ~32 s to authenticated |
| 17:53:42 | on | foreground | `scan-source=filtered` then `target-found` | ~20 s |

Everything else was held constant: one phone, one app package, one harness, one
sensor in the same place.

## What this rules out

- **Not a sensor duty cycle.** The sensor advertised immediately before and
  after every screen-off failure, and streamed continuously for 6.5 minutes
  during the completed run.
- **Not a state our own session leaves behind.** The completed run released its
  GATT link (`gattReleased: true`), and the next probe re-acquired **and
  re-authenticated** the same sensor 3 minutes later. If a session left the
  sensor quiet, that probe would have failed with the screen on.
- **Not "no glucose on this firmware".** The same window is what produced the
  payload-word evidence in `cbio-gs1-glucose-live.md`.
- **Not the sensor being switched off or out of range.** The raw archive had
  grown from index 9981 (2026-09-17) to index 10969 in this run — 988 new
  minutes — so the sensor was logging and reachable throughout.

## What the completed window carried

`evidence/gs1-session-20260918T104803-cbio_glucose_authenticated_test.json`,
harness revision `ec0334e`:

| field | value |
|---|---|
| `outcome` | `completed` |
| `writes` | authentication 1, clock_set 1, glucose_read 1, raw_history_read 1 |
| `notifications` | 719 |
| `records.raw` | 10969, index 1..10969 |
| `records.rawPayload` | 39..97, non-zero in **10969 / 10969** |
| `records.processedGlucose` | 0..0, non-zero in 0 / 12751 |
| `gattReleased` | `true` |
| `errors` | none |
| `unitStatus` | `unverified` |

`processedGlucose` counts 12751 samples because it is decoded from both the
`0A` batches (1782) and the `08` records (10969); it is zero in all of them.

## What this means for the product

1. Onboarding must not treat an empty scan as "no sensor nearby" while the
   display is off. The app should keep the screen awake (or hold a foreground
   service with the scan rights the platform requires) for the length of a
   discovery attempt, and say so in the UI if it cannot.
2. A scan that the platform declined must not be reported as a scan that found
   nothing. The harness already distinguishes this in its own log; the app
   surface should keep that distinction too.
3. Discovery must be able to survive the filtered pass missing this
   advertisement, which is why the unfiltered fallback exists. Any future
   change that makes the fallback optional quietly removes the only path that
   works for this sensor class.

## How to reproduce

```sh
adb shell input keyevent KEYCODE_WAKEUP          # screen on
adb shell am start -n <app>/<activity>          # the harness APK entrypoint
adb logcat | grep -E 'CBIO-A (scan-source|target-found|abort)|BtScan.ScanManager'

adb shell input keyevent KEYCODE_SLEEP          # screen off, same harness
```

No sensor write is involved in either direction: this is a scan-policy
observation, not a protocol one.
