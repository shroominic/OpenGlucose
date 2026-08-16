# Apple Watch Smart Stack

OpenGlucose can show its iPhone Live Activity in the Apple Watch Smart Stack.
This first Apple Watch feature does not install a separate Watch app. The
iPhone remains the only device that connects to the sensor.

## Requirements

- An iPhone with iOS 18 or newer
- A paired Apple Watch with watchOS 11 or newer
- Live Activities enabled for OpenGlucose
- The OpenGlucose sensor session active on the iPhone

Apple sends the iPhone Live Activity to the paired Watch. Delivery is subject
to the system update budget and the connection between the devices. A Watch
update can arrive later than the iPhone update.

## Information shown

The Smart Stack presentation can show:

- the latest glucose value and unit;
- trend and delta;
- a relative reading age;
- a stale state that hides the glucose value, unit, trend, and delta after 10
  minutes;
- and a warmup countdown.

ActivityKit is scheduled to mark a reading stale 10 minutes after its recorded
time. The presentation then shows **Stale** instead of glucose. OpenGlucose
stops publishing a reading that is more than 15 minutes old when the iPhone can
update the activity. iOS controls when it removes the stale activity itself.
The Watch presentation includes text labels and accessibility labels, and it
reduces bright content for Always-On display.

## Privacy

Glucose is hidden by default. To show it, enable **Show glucose in live
notification** in the active sensor settings on the iPhone. This setting also
controls the Apple Watch Live Activity because the same private payload is
used on both devices.

When the setting is off, OpenGlucose sends a redacted Live Activity. It does
not send the sensor name, glucose value, unit, trend, delta, or reading time to
the visible Watch presentation. Disabling the setting ends an activity that
might contain a value before the redacted activity can start.

## Limits

- This is a display surface, not a sensor connection.
- It is not a complication or a native Watch app.
- It does not provide continuous or guaranteed monitoring.
- iOS can keep a stale activity visible, but the stale activity does not show
  glucose.
- Do not use it for diagnosis, medication or insulin dosing, treatment
  decisions, or emergency monitoring.

A future native companion app must keep sensor Bluetooth ownership on the
iPhone. It also needs separate signing, TestFlight verification, retention,
and physical-device work.
