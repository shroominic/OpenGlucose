# Issue 38 review evidence

The screenshots in this folder use synthetic, redacted fixtures. They contain
no real sensor identifier, connection metadata, or glucose value.

- `compact-375.png` shows the 375 x 812 compact Trends layout after the
  timestamp freshness boundary. The live-pattern metrics are absent.
- `wide-900.png` shows the 900 x 900 rail layout after the 15-day sensor-life
  boundary. The Timeline has no live glucose list.

`openhealth/test/today_navigation_test.dart` verifies the same two transitions
with a controlled clock and no session snapshot event. It also enables Flutter
semantics and verifies a labelled live region for both stale and inactive
states, as well as the named navigation destinations. Flutter exposes this
semantics tree to VoiceOver and TalkBack.

No physical VoiceOver or TalkBack session was run for this synthetic review
capture. The controls register has no established device accessibility lane;
this is not a waiver. The accountable owner must perform and record device
screen-reader verification before a production-readiness claim.
