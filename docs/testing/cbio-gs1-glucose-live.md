# GS1 live glucose and history: the sensor answers every read with one fixed frame

This record documents the first attempt to obtain live glucose and stored
history from the live SIBIONICS / CBio GS1 sensor with the vendor's own V120
read queries. The outcome is exact and negative: four different read queries,
including two documented vendor commands, each returned the same five bytes.
No glucose value, unit, epoch, or history range was obtained, and none is
claimed here.

## Queries sent

Every frame below is a plaintext vendor read built to the recovered
`libdata-handle-lib.so` templates and sent as a write-with-response on `FF32`.
The additive checksum of each frame is zero modulo 256.

| # | Label | Query bytes | Source |
| --- | --- | --- | --- |
| 1 | storage state | `03 F0 04 09` | `v120_device_information(4)`, `C = 0x0D - x` |
| 2 | device time / last index | `03 F0 03 0A` | `v120_device_information(3)` |
| 3 | glucose index 0 | `06 0A 00 00 00 00 F0` | `v120_glouse(0)`, `06 0A LE16(index) 00 00 C` |
| 4 | glucose index 1 | `06 0A 01 00 00 00 EF` | `v120_glouse(1)` |

Link state: one connection, MTU 247 negotiated, `FF31` notify enabled,
`FF32` write-with-response, four writes and four notifications, then a clean
disconnect. No pairing or bond was created.

## Observed replies

| Query | Reply bytes | Elapsed after write |
| --- | --- | --- |
| storage state | `23 F7 6F D9 F4` | 2.0 s window, notification at t=2058 ms |
| device time | `23 F7 6F D9 F4` | notification at t=7732 ms |
| glucose index 0 | `23 F7 6F D9 F4` | notification at t=13165 ms |
| glucose index 1 | `23 F7 6F D9 F4` | notification at t=18655 ms |

All four replies are the same five bytes recorded in every earlier session of
2026-09-17, and the harness reports `failure=length` for each: the payload
declares 36 bytes through byte zero and carries 5, its additive sum is `0x56`
rather than 0, and byte one `0xF7` is not a mapped opcode. The `0A` glucose
layout therefore does not decode it, and neither does any other plaintext
reading; see `cbio-gs1-reply-decode.md` for the full hypothesis table.

## What the identical replies establish

- The payload is **not a per-command answer**. A storage-status read, a
  time/last-index read, and two glucose reads with different indices all
  returned the identical frame. A decoded vendor ACK would echo its opcode and
  carry command-specific status; this does not.
- The payload is **not the first fragment of a longer plaintext frame**. Four
  queries spread over 19 s produced one five-byte notification each and nothing
  more, so there is no in-flight remainder on this path.
- The payload **is a response to a write**. Passive windows of 12 s and 20 s on
  `FF31` observed nothing, and each notification arrived 9-18 ms after its
  write completed.
- The sensor therefore refuses or cannot serve these reads in its current
  state. The vendor application does not send them cold either: its recovered
  sequence performs device information, then `V120ApplyAuthentication` with a
  six-byte reversed Bluetooth address and 16 bytes of registered material, and
  only then the data queries. The 16-byte key is registered into native BSS
  from an application token; it is not present in this repository or on this
  host. The earlier bench on the same sensor model also saw five-byte replies
  to plaintext queries that became valid frames only after the native RC4
  transform with that key, and the owner has confirmed this sensor is not
  activated.

Decoding is therefore blocked on vendor material, not on the query framing.
Sending an authentication or activation write is explicitly out of scope for
this lane and was not attempted.

## Capability added by this lane

`packages/cgm_cbio` now carries the paging and polling logic the product needs
once the sensor will answer, with no transport of its own:

- `buildCbioGlucoseQuery(index)` / `buildCbioInformationQuery(selector)` build
  the vendor read frames and reject out-of-range arguments.
- `parseCbioGlucoseBatch(bytes)` decodes only the `0A` layout, strictly
  checking length, count, checksum, and counter bounds, and refuses the `08`
  raw-data layout.
- `CbioGlucoseRecord` exposes raw fields only. `isUnitVerified` is always
  false, so a caller cannot present the 10-bit field as mg/dL or mmol/L.
- `CbioGlucoseSyncSession.pollLive()` polls at the newest index with a 60 s
  interval, matching the sensor's own record spacing, and reports
  `noRecords`, `decodeFailed`, `queryFailed`, or `budgetReached` without
  advancing its high-water mark.
- `CbioGlucoseSyncSession.backfillHistory()` pages upward from the oldest
  record under a hard page budget, requires each page to begin exactly where
  the previous ended, cross-checks the vendor reindex counter, and returns
  `historyNotFullyAvailable` or `budgetReached` instead of a guessed range.

With the sensor in its current state every one of those paths terminates in
`decodeFailed` on the fixed five-byte reply, which is the fail-closed behavior
the capability was designed for.

## Exact next evidence needed

1. The vendor's 16-byte stream key and the 6-byte sensor address material, so
   the same four reads can be sent in the transformed form the application
   uses. That is the only way this lane can test the data path without writing
   an activation or authentication frame.
2. Or explicit authorization to run `V120ApplyAuthentication` on this sensor,
   plus the registered token for `com.sisensing.sijoy`. The authentication
   builder itself is fully documented; only the material is missing.
3. Or activation of the sensor by its owner in the vendor application, after
   which the read-only queries above can be repeated and are expected either to
   answer in plaintext or to answer with a keyed frame whose keystream can then
   be recovered from a vendor-application HCI capture.

## Safety record

Exactly four writes were sent in this attempt, all listed in the query table:
two information reads and two glucose reads. No activation (`07`), clock
update, reset, threshold, calibration, key, or authentication write was sent,
no bond was created, and the GATT link was released at the end of the run. The
run's radio time was under 25 s of writes and notifications.
