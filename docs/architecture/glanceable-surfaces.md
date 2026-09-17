# Glanceable surface contract

`openhealth/lib/src/glanceable_surface.dart` defines the adapter-neutral
contract for compact surfaces such as Android notifications, iOS Live
Activities, lock-screen widgets, and future watch complications. This slice is
deliberately Dart-only: it does not change an existing native payload or claim
that a platform adapter is implemented.

## Model and lifecycle

`GlanceableSurfaceSnapshot.fromSession` derives one deterministic snapshot from
the same `CgmSessionSnapshot` and warmup primitives used by the foreground UI.
It carries:

- a coarse phase (`noSession`, `connecting`, `warming`, `waiting`, `live`,
  `stale`, or `error`);
- a freshness bucket with five- and ten-minute boundaries;
- a warmup countdown when the sensor is initializing;
- a timestamped glucose value only after warmup; and
- aggregate activity/sleep context and a low/high/stale alert state.

Advertisement-only or provisional warmup values are never treated as current
glucose. A platform surface can therefore show “Warming up” and the remaining
minutes without displaying a misleading initial value.

## Privacy boundary

`serializeGlanceableSurface` is redacted by default. Redacted payloads expose
phase, freshness, countdown, a generic surface string, whether context exists,
and whether any alert needs attention. They do not expose glucose, exact
timestamps, sensor labels, context measurements, or alert type.

The caller must explicitly pass `includeSensitive: true` to include those
fields. That opt-in is a policy gate, not a promise that a native surface may
publish them: callers still need to honor the user's per-surface setting and
the platform's privacy rules. Native adapters must not log or persist raw
payloads, and must clear their surface when consent is withdrawn.

## Native adapter contract

Platform code implements only:

```dart
abstract interface class GlanceableSurfaceAdapter {
  Future<void> publish(GlanceableSurfacePayload payload);
  Future<void> clear();
}
```

Adapters consume `GlanceableSurfacePayload` and never a domain snapshot or raw
health sample. They should treat `schemaVersion` as a compatibility boundary,
preserve the phase/freshness/warmup semantics, and fail closed when a payload
is malformed or a sensitive-content gate is unavailable. `NoopGlanceableSurfaceAdapter`
is the safe implementation for unsupported platforms and tests.

Future native work can add one adapter at a time (for example, Android live
notifications or an iOS Live Activity) with platform contract tests that prove
the exact mapping. Existing native payloads remain unchanged until such a
platform-specific change is reviewed separately.
