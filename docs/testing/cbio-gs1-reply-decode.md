# Cbio GS1 FF31 reply: what the five bytes are not

This record closes the question "what is the FF31 reply?" as far as the bytes
themselves can take it. The answer is negative and exact: the payload is not a
complete plaintext V120 frame under any plaintext reading tested here, and the
only surviving explanation that the repository already has evidence for is a
keyed stream-cipher mask that cannot be removed without the vendor's registered
key. No glucose value, unit, or timestamp is claimed anywhere in this file.

## Observed payload

The driver's single bounded read `06 08 01 00 00 00 F1` (opcode `08`, index 1)
on `FF32` produced exactly one notification on `FF31`, five bytes long, and
`parseCbioPlaintextFrame` refused it with reason `length`.

| Field | Value |
| --- | --- |
| Notification bytes | `23 F7 6F D9 F4` |
| Length | 5 |
| Additive sum modulo 256 | `0x56` (contract requires `0x00`) |
| Byte zero read as the vendor length `L`, total `L + 1` | `0x24` = 36 |
| Bytes outstanding under that reading | 31 |
| Byte one read as an opcode | `0xF7`, outside the mapped opcode set |
| Five-byte acknowledgement marker `0x04` at byte zero | absent |

The payload is identifier-free: it contains no address, name, key, nonce, or
time. It was byte-identical in every recorded session of 2026-09-17, including
the four sessions pulled from the device under `/tmp/cbio_pull*` and the
confirmation capture recorded from this lane.

Timing from the capture segments is part of the evidence. In the session
pulled at 20:27 the write-with-response completed at `13:27:39.060929Z` and the
notification arrived at `13:27:39.078912Z`, 18 ms later. In the confirmation
capture recorded for this lane the write completed at `14:40:52.657538Z` and
the notification arrived at `14:40:52.666907Z`, 9 ms later, and the notification
stream then stayed silent until it was cancelled 6.7 s afterwards. Passive
windows of 12 s (plugin) and 20 s (bench) also observed nothing on `FF31`. The
payload is therefore a response to the read, not a periodic or unsolicited
broadcast.

## Plaintext contract used for every test

`packages/cgm_cbio/lib/src/cbio_frames.dart` accepts a complete frame when the
length is 5 to 256 bytes, byte zero is `length - 1`, the additive sum of all
bytes is zero modulo 256, and byte one is a mapped opcode. Five-byte control
replies are additionally restricted to the observed set `00/01/02/0A/F0`.

`packages/cgm_cbio/lib/src/cbio_reply_inspection.dart` applies that contract to
a raw notification and reports the findings without transforming the bytes. It
never returns a decoded value for an unresolved payload.

## Hypotheses and outcomes

| # | Hypothesis | Outcome | Evidence |
| --- | --- | --- | --- |
| 1 | Complete plaintext frame | Refuted | Byte zero declares 36 bytes, not 5; sum is `0x56`, not 0 |
| 2 | Plaintext five-byte ACK `04 opcode result status C` | Refuted | Byte zero is `0x23`, not the `0x04` marker |
| 3 | Frame at another offset, rotation, or reversed order | Refuted | No rotation and neither orientation satisfies length, checksum, and opcode together |
| 4 | Constant single-byte XOR or additive mask | Refuted | All 512 candidate transforms were searched; none exposes a valid frame |
| 5 | CRC-8 trailer over the first four bytes | Refuted | Polynomials `07/31/9B/1D/8F/39/D5` with init `00` and `FF` reproduce `0xF4` in no case |
| 6 | CRC-16 or longer trailer | Refuted by length | A trailer cannot fit in a five-byte payload that also carries a frame header |
| 7 | Length-prefixed frame whose remainder is still in flight | Not sustained | 31 bytes are outstanding if byte zero is `L`, and byte one would be the unmapped opcode `0xF7`; the 6 s settle window after the first packet and the passive windows produced no further `FF31` notifications. The vendor's `V120SpiltData` entry point keeps split handling an open possibility, so this is the only plaintext reading left standing, and it is unevidenced |
| 8 | Wrong characteristic | Refuted | The payload arrived on `FF31` of service `FF30`, the sensor-to-app side of the vendor mapping; `FF32` is the write side |
| 9 | Spontaneous or periodic sensor broadcast | Refuted by timing | 18 ms after the read completed, and nothing at all in 12 s and 20 s passive windows |
| 10 | Unmasked undocumented vendor opcode | Refuted | Any unmasked reading still has to balance the additive checksum, which `0x23 F7 6F D9 F4` does not |
| 11 | Keyed stream-cipher mask (RC4 with the vendor key) | Plausible, not decidable here | See below |

## Why hypothesis 11 is the surviving one

The earlier bench on this same sensor model sent plaintext `F0` and `0A`
queries and received one five-byte notification per query. Those notifications
were not valid plaintext frames either; they became length-valid and
sum-to-zero only after the native RC4 transform with the vendor's 16-byte
stream key at stream offset zero. The reply bytes now captured have the same
shape: five bytes, deterministic across sessions, and refused by every
plaintext invariant.

Decoding by that route needs material this repository does not have. The key is
not a static constant: the native `register_key` path hex-decodes a token,
applies RC4, checks the package binding, and copies the clear bytes into a BSS
slot that the request and reply paths then use. The token, key, and the
decompiled vendor artifacts lived in a private scratch directory that no longer
exists, the vendor application is not installed on the paired phone, and no
vendor APK remains on this host. A five-byte constant-mask search cannot stand
in for the key: RC4 produces a per-byte keystream, so the payload stays
unresolved rather than "probably" a status code.

If the key were recovered, the test would be exact: a correct keystream must
turn `23 F7 6F D9 F4` into a frame whose byte zero is 4, whose sum is zero, and
whose opcode is a mapped one - for example the `08` acknowledgement
`04 08 result status C`. That result is a hypothesis about the plaintext, not a
decode, and must not be published as a reading.

## Proven here

- The reply is a deterministic response to the bounded `08` read, not a
  broadcast, and it is byte-identical across every recorded session.
- It is not a complete plaintext V120 frame, in any orientation, under any
  constant mask, and its trailer is not a CRC-8 of its prefix.
- No decoding exists for it in this repository, and none was fabricated. The
  inspection added by this lane returns `unresolved` with no frame for these
  bytes.

## Not proven

- What the five bytes mean, whether they carry a result code, and whether the
  sensor considers the read authenticated, authorized, or malformed.
- Whether the sensor expects more traffic (a fragmented remainder, an
  authentication write, or a different command) before it answers in plaintext.
- Any glucose value, unit, epoch, or sensor state.
- Firmware or model coverage: one sensor, one firmware revision, one app build.

## Update: the payload is not command-specific

The vendor's own read queries were then sent to the same live sensor from the
phone: the storage read `03 F0 04 09`, the time/last-index read `03 F0 03 0A`,
and the glucose reads `06 0A 00 00 00 00 F0` and `06 0A 01 00 00 00 EF`. All
four returned the identical five bytes `23 F7 6F D9 F4`, one notification each,
with nothing further arriving across 19 s.

That result strengthens two of the conclusions above and retires a third. The
payload is not a per-command reply, since a storage read, a time read, and two
different glucose reads produce the same bytes; it is not the first fragment of
a longer plaintext frame; and hypothesis 7 above, a length-prefixed remainder
still in flight, is now refuted for this path rather than merely unsustained.
The surviving explanation is unchanged: one fixed response, almost certainly
keyed, that the sensor emits until the vendor's authentication material is
present. See `cbio-gs1-glucose-live.md` for the full query, reply, and timing
record.

## Exact next evidence needed

1. The vendor's 16-byte stream key, recovered the same way the earlier bench
   obtained it (`register_key` token for `com.sisensing.sijoy`, followed by the
   package-binding check), or an HCI snoop of the vendor application completing
   its own `08` read. Either gives a keystream/plaintext pair and turns the
   analysis into a bounded offline test.
2. A second sensor, ideally a different production lot, to show whether the
   payload is firmware-wide or unit-specific.
3. The vendor's own response to an authenticated session, which requires an
   authentication write. That write is out of scope for this lane and was not
   attempted.

## Safety record

Every session in this lane sent exactly one write, the bounded `06 08 01 00 00 00 F1`
read, and nothing else. No activation (`07`), clock (`03`), reset, interval,
threshold, key, or calibration write was sent. Radio time stayed inside the
bounded capture windows, and no sensor state change was requested.
