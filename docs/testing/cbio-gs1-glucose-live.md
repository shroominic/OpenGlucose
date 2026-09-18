# GS1 live glucose and history: the authenticated link streams to the present

The live SIBIONICS / CBio GS1 sensor answers the vendor's own read queries once
the link is authenticated, and the answers are the sensor's record stream. Four
bounded sessions on 2026-09-18 produced a complete raw history: **9981 records,
index 1..9981, one per minute, contiguous, from `2026-09-10T19:57:00Z` to
`2026-09-17T18:17:00Z`** — the last record lands in the same minute the read
ran, so the archive is live rather than historical.

Everything below is read from the sensor or computed from its frames. The
masking key and the link credential are documented by derivation in
`docs/testing/cbio-gs1-auth-material.md` (sibling branch
`docs/cbio-gs1-auth-material`, PR #138) and are deliberately not restated here.

## The five-byte prompt is a masked control frame

Against the plaintext-only attempt the sensor replied `23 F7 6F D9 F4` to every
read. Removing the vendor's per-frame stream mask from those five bytes yields
`04 00 00 00 FC`: five bytes declared, opcode `00`, `result = 0`, `status = 0`,
additive checksum zero. That is a well-formed control frame, not a refusal, and
the same five bytes are what the sensor sends as an authentication prompt. The
reads were never the problem; the masked encoding was the missing piece.

## Authentication

The vendor sequence is device information, then a masked authentication frame
`19 01 00 <6 address octets> <16 credential bytes> C`, then the reads.

| Run | Candidate | Address octets | Reply | Result |
| --- | --- | --- | --- | --- |
| 1, 2, 3 | 2A25 read, reversed a second time | `CC CB BC 64 38 AF` | `04 01 00 02 F9` | rejected: `result=0 status=2` |
| 1, 2, 3 | sensor address in vendor order | `AF 38 64 BC CB CC` | `04 01 01 00 FA` | accepted: `result=1 status=0` |
| 4 | 2A25 read, used as read | `AF 38 64 BC CB CC` | `04 01 01 00 FA` | accepted: `result=1 status=0` |

The 2A25 characteristic already returns the address in the vendor's reversed
order, so runs 1-3 spent one rejected attempt on the same six bytes in the wrong
order before falling back to the address taken from the advertised identifier.
Run 4 used the 2A25 octets unmodified and authenticated on the first attempt
with four writes in total.

## Reads sent

| # | Label | Plaintext | Masked (as logged) |
| --- | --- | --- | --- |
| 1 | authentication | `19 01 00 <6 address octets> <16 credential bytes> C` | `3E F6 6F 76 30 17 E4 17 71 …11` |
| 2 | vendor clock | `06 03 LE32(epoch) C` | `21 F4 37 F4 A4 19 04` |
| 3 | glucose read | `06 0A 00 00 00 00 F0` | `21 FD 6F D9 08 73 A8` |
| 4 | raw history read | `06 08 01 00 00 00 F1` | `21 FF 6E D9 08 73 A9` |

Frame 2 is the only non-read write in any session and was sent once per session
so stored timestamps can be read against a known clock. Frames 3 and 4 are the
vendor's `v120_glouse(index)` and raw-data reads. The credential bytes are
elided; nothing about them changed from the derivation record.

## What the sensor returned

Every notification unmasks to a plaintext frame whose additive checksum is
zero. Two batch shapes matter:

| Path | Records | Layout | Content |
| --- | --- | --- | --- |
| `0A` | 1782, index 1..1782 | packed 10-bit field, `11 + 2n` bytes | **every field zero** |
| `08` | 9981, index 1..9981 | `temp, dump, payload, processed`, `12 + 8n` bytes | one record per minute, values below |

The two paths do not agree, and only `08` carries usable content on this sensor:

- `0A` ends at index 1782, `2026-09-12T01:38:00Z`, and is zero throughout.
- `08` continues to index 9981, `2026-09-17T18:17:00Z`, with no gaps.

The `08` record is eight bytes and holds **two** candidate reading words. The
one the app renders is `payload`, the little-endian word at record offset 4.
The firmware's `processed` word at offset 6 — the same 10-bit packed field the
`0A` batch carries — is zero in **every record of every captured session**, and
that is the field the evidence path used to read. The "every raw glucose field
reads 0" verdict was a wrong-field bug in the evidence decoder, not a sensor
that reports nothing: the packed word is empty because the sensor is logging but
not activated, while the payload word is live and current.

### The arithmetic, on a real captured record

First `08` record of the 13:02 session (`plaintext 08 01 6a 0b 40 00 00 00`),
after the batch header:

| Offset | Bytes | LE16 | Field | Meaning |
| --- | --- | --- | --- | --- |
| 0 | `3a 01` | 314 | `temp` | 31.4 °C on the same unverified `/10` scale — the control that the stride is right |
| 2 | `6a 0b` | 2922 | `dump` | no established meaning |
| 4 | `40 00` | **64** | `payload` | the reading-bearing word: `raw / 10` → 6.4 |
| 6 | `00 00` | 0 | `processed` | packed `(b >> 6) \| (b1 << 2)` → 0 |

A zero here is zero *bytes*, not a shifted offset or a wrong width: the
temperature word decodes to a plausible value at offset 0, so the record stride
and the offsets are confirmed independently of the glucose question.

### The same window through both decoders

`make cbio-gs1-decode-comparison CBIO_EVIDENCE_LOG=<captured log>` replays one
captured session through the frame parser and through `CbioHistoryArchive`, the
decoder behind the app's live readings, and writes
`evidence/gs1-decode-comparison-<utc>.json`. For the 1520-record window
(index 1..1520, 2026-09-10T19:57Z to 2026-09-11T21:16Z, 25.3 h):

| Field | Range | Non-zero records | Hourly median |
| --- | --- | --- | --- |
| `payload` (offset 4) | 51..95 | 1520 / 1520 | 5.3 at 05:00Z to 8.6 at 12:00Z — dips overnight, rises through the day |
| `processed` (offset 6) | 0..0 | 0 / 1520 | 0 |

The two decoders agree on all 1520 payload indices (`agreeing` 1520,
`missing` 0, `disagreeing` 0), which is what gate G1 asks for: one field, one
scale, no unexplained disagreement between the app path and the evidence path.
A physiologically-shaped series is still not a calibrated one — it is one more
reason the `/10` scale is plausible, and nothing more.

### Which path reads which word

Audited end to end on the consolidation tip, so that no surface can quietly keep
reading the empty field:

| Path | Reads | Produces a glucose number |
| --- | --- | --- |
| `parseCbioRawDataFrame` | offset 4 → `rawPayload`; offset 6 → `processed.rawWord` | no — owns the layout only |
| `CbioHistoryArchive` (the app's live decode) | `rawPayload` | yes: `derivedMillimolesPerLitre` and the record's scaled value |
| App reading (`CbioGlucoseSession`) | `record.rawPayload` | yes: `rawValue: record.rawPayload`, `valueMgdl: record.rawPayloadScaled`, `isDisplayProvisional: true` |
| `CbioRawGlucoseRecord.rawProcessed` | offset 6 | **no** — exposed as the firmware's processed word, read by tests only |
| `compareCbioDecode` (the harness path) | both, side by side | no — reporting only |
| `parseCbioGlucoseBatch` (`0A` frame) | the `0A` layout's own packed 10-bit field | that frame only, and it is zero on this sensor |

The provisional marker survives the change: the CBIO reading is built with
`isDisplayProvisional: true`, the surfaces render
`provisionalReadingNoticeForSnapshot` — "Includes provisional readings. Not
validated for body glucose." — `isUnitVerified` stays `false`, and every
artifact and comparison still carries `unitStatus: unverified`.

## Derived values, and why they stay unverified

`CbioRawGlucoseRecord` divides `rawPayload` by 10 and `rawTemperature` by 10 because two
independent implementations of this protocol read the fields that way, and
because the result is plausible:

| Field | Raw range | Derived | Distribution |
| --- | --- | --- | --- |
| `payload` | 39..97 | 3.9..9.7 mmol/L | p05 5.2, p50 6.4, p95 8.0 mmol/L |
| `rawTemperature` | 274..460 | 27.4..46.0 °C | 9961 of 9981 records in 20.0..42.0 °C |

Agreement between two independent clients, and a glucose range that looks like
interstitial glucose, is not proof of scale. `isUnitVerified` stays `false` and
the raw integer is exposed alongside any converted number; a reference
measurement against a known index is what would settle it.

The newest record at the time of the run was index 9981,
`2026-09-17T18:17:00Z`, raw `payload` 50 and raw `rawTemperature` 315 — 5.0 mmol/L and
31.5 °C on the unverified scale.

## Reading timeline

| Run | Raw read from | Raw index captured | `payload` range | Writes | Notifications |
| --- | --- | --- | --- | --- | --- |
| 1 | 0 | 1..1520 (20 s window) | 51..95 | 5 | 127 |
| 2 | 0 | 1..1520 (20 s window) | 51..95 | 5 | 127 |
| 3 | 1521 | 1521..3040 (20 s window) | 49..89 | 5 | 127 |
| 4 | 1 | 1..9981 (300 s window, until the sensor stopped) | 39..97 | 4 | 657 |

Run 3's first record is exactly one minute after run 1's last, and run 4
returned the whole 1..9981 range including run 1 and run 3's windows. Runs 1 and
2 reproduced each other exactly, and run 4's stream ended with short batches
(`11`, then `1`, then `1` records) — the sensor had delivered everything it had,
not a truncated window. Replaying each session's logged frames through
`CbioHistoryArchive` gives 9981 records, indexes contiguous, no gap, no overlap.

## Prior attempt

On 2026-09-17 the same read queries were sent in plaintext, without
authentication: a storage-state read, a time read, and glucose reads at index 0
and index 1. All four returned the identical `23 F7 6F D9 F4`. The record
concluded that the sensor refused the reads. It did not: it was answering in the
masked encoding, and the missing piece was the vendor's stream mask.

## Safety record

Four or five writes per session, all listed above, all logged byte-for-byte in
masked and plaintext form. No activation (`07`), reset, threshold, calibration,
key-registration, or firmware frame was sent. No pairing or bond was requested,
the GATT link was released at the end of each run, and the longest read window
was 300 s of read-only notifications.

## Still open

1. A reference glucose measurement against a known index, to promote
   `isUnitVerified` from `false`.
2. Why `0A` is zero and frozen at `2026-09-12T01:38:00Z` while `08` streams to
   the present; only `08` has usable content on this sensor.
3. Whether the `0A` field starts carrying values once the owner activates the
   sensor, and whether the archive continues past index 9981 without a break.
