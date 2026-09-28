# Libre 2-family offline evidence boundary

This package independently implements public interoperability structure that
can be tested without a sensor, proprietary binary, certificate, or network
service. Its security-Gen1 Dart implementation is derived only from the pinned
MIT sources below. Their full notices are preserved in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md). No vendor binary, GPL
source, real identifier, or real health-data fixture is a build input.

The repository-level evidence source is
[`docs/testing/libre-family-protocol-capture.md`](../../../docs/testing/libre-family-protocol-capture.md).
The locally audited Supersapiens static-analysis notes corroborated only the
high-level login, session-information, authentication, and composite ordering.
No local binary is a build input, fixture, or dependency.

## Independently implemented now

| Component | Audited reference evidence | Core behavior |
| --- | --- | --- |
| SAS topology | FDE3 service with F001 login and F002 composite data | Normalize and classify; always label target-unverified |
| GKS topology boundary | Separate audited data/security services and ten characteristic UUIDs | Classify separately; never enter the SAS state machine |
| Security branch | Patch evidence selects Gen1 or Gen2; UUIDs are shared | Require an explicit generation; reject `unknown` |
| Gen1 ordering | F001 login write completes before F002 subscription | Keep the existing live planner externally gated; expose a separate pure login-value plan |
| Gen2 challenge | F001 subscription, external one-byte challenge request, 14-byte notification | Validate recorded lengths only; build no request bytes |
| Gen2 request/session | external 19-byte authenticated request; F001 session fragments 7+18 | Validate the recorded length and strictly assemble 25 opaque bytes |
| Composite stream | F002 fragments 20+18+8, total 46 | Strictly assemble opaque bytes in the classifier; the separate Gen1 core can decrypt but never interprets glucose |
| Composite timeout | incomplete value discarded after 10 seconds | Use caller-supplied monotonic timestamps; no wall timer or retry |
| Disconnect | authentication state clears; reconnect behavior is not target-verified | Clear partial state and require a new explicit connection observation |
| Live ordering | Same audited Gen1/Gen2 ordering above | Emit one typed action at a time; reject stale acknowledgements; never retry |
| Gen2 challenge request | F001 subscription completes before one-byte `0x20` write | Construct only this exact action; leave target BLE write mode unresolved |
| Security boundaries | Gen2 authentication and session verification depend on protected external behavior | Keep Gen2 bootstrap/session contexts opaque and require external provider interfaces |
| Gen1 typed inputs | LibreTools requires 8 UID bytes and 6 patch-information bytes before indexed access | Snapshot exact-length byte values; reject unknown model signatures and non-Gen1 markers |
| Gen1 primitive | [LibreTools `Libre2.swift` lines 104-163](https://github.com/ivalkou/LibreTools/blob/d54b0883959420e5941ed293ec6b9ef2474b7ed3/Sources/LibreTools/Sensor/Libre2.swift#L104-L163) and [DiaBLE lines 56-123](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre2.swift#L56-L123) | Pure four-byte derivation with unsigned 16-bit inputs |
| Gen1 FRAM | [LibreTools lines 19-57](https://github.com/ivalkou/LibreTools/blob/d54b0883959420e5941ed293ec6b9ef2474b7ed3/Sources/LibreTools/Sensor/Libre2.swift#L19-L57) | Decrypt exactly 43 eight-byte blocks |
| FRAM integrity | [LibreTools `SensorData.swift` lines 68-83](https://github.com/ivalkou/LibreTools/blob/d54b0883959420e5941ed293ec6b9ef2474b7ed3/Sources/LibreTools/Sensor/SensorData.swift#L68-L83) and [DiaBLE CRC regions](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre.swift#L247-L269) | Require header, body, and footer CRCs; fail closed on any mismatch |
| Gen1 lifecycle | [DiaBLE state values 1-6](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Sensor.swift#L77-L95) and [CRC-gated FRAM byte 4 use](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre.swift#L105-L118) | Accept only the all-three-CRC-verified decrypted FRAM type; map `0x01` through `0x06` to the closed lifecycle set and all other values to `unknown` |
| Private Gen1 artifact validation | Native capture schema, [LibreTools Example2](https://github.com/ivalkou/LibreTools/blob/d54b0883959420e5941ed293ec6b9ef2474b7ed3/Sources/LibreTools/Sensor/Libre2.swift#L542-L591), and the independently implemented Gen1 core above | Read one explicit owner-private artifact through a descriptor-bound `O_NOFOLLOW` open; bind the direct algorithm-order UID and six-byte patch information by SHA-256; derive `e007` from UID bytes 7 and 6; require the closed model, exact FRAM length, all three CRCs, and lifecycle parsing; emit only a closed neutral result |
| Gen1 BLE | [LibreTools lines 64-96](https://github.com/ivalkou/LibreTools/blob/d54b0883959420e5941ed293ec6b9ef2474b7ed3/Sources/LibreTools/Sensor/Libre2.swift#L64-L96) and [DiaBLE lines 295-332](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre2.swift#L295-L332) | Require exactly 46 encrypted bytes, return 44 opaque bytes only after CRC validation |
| Gen1 activation plan | [DiaBLE `NFC.swift` lines 39-45 and 110-122](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/NFC.swift#L39-L122) | Build five `0xA1` custom parameters; perform no I/O |
| Gen1 streaming plan | [DiaBLE `Libre2.swift` lines 176-227](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre2.swift#L176-L227) | Build nine enable parameters; treat a six-byte result only as an expected shape |
| Gen1 BLE login plan | [DiaBLE payload lines 238-292](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/Libre2.swift#L238-L292) and [with-response call site](https://github.com/gui-dos/DiaBLE/blob/e6a909c88faeada49f461d30834174cd95db4042/DiaBLE/BluetoothDelegate.swift#L533-L539) | Build an exact 12-byte F001 value for explicit base/counter inputs; record with-response and F002-after-ack ordering |

The Gen2 session-information reference did not establish a timeout. The
default is therefore no timeout. An owner can inject one only as an explicit
timing profile for evidence analysis.

## Pure-core exclusions

These exclusions apply to the classification, crypto, and handshake-planner
APIs. The separately reviewed explicit Gen1 driver below does not turn calling
those pure APIs into live sensor authorization.

- application-wide generation selection beyond the strict, closed Gen1
  patch-information model set;
- Gen2 target keys, key derivation, crypto, authenticated-command construction,
  integrity verification, decryption, counters, nonces, or replay behavior;
- NFC reads or writes, activation execution, enable-streaming execution, late
  join, sensor move, reset, termination, or ownership changes;
- concrete Bluetooth scan, connection, notification subscription, writes,
  bonding, bond deletion, live retry, or automatic reconnect;
- warmup/wear-duration assumptions, lifecycle-driven behavior, sensor failure
  detail, sensor result mapping, glucose decoding, or any retail
  model/firmware compatibility claim;
- all Libre 3/GKS authentication and data behavior. Its UUID classification
  exists only to prevent accidental reuse of the SAS path.

Live operations need separate evidence, review, deterministic fixtures, and the
applicable R3 approval before execution. Activation and enable-streaming plans
are deliberately inert state-changing inputs. The pure core supplies no
concrete platform transport, NFC provider, storage, or automatic runner.

## Explicit Gen1 driver

The package now also contains `LibreGen1Driver`, composed only in the private
Android receiver build. It requires protected NFC bootstrap state, a durable
counter store, and a single-attempt BLE transport. It waits for a fresh exact
target advertisement, confirms scan cancellation, connects once, checks
topology, reserves a login counter, writes F001 with response, and subscribes
to F002 only after acknowledgement. Partial failures do not authorize retries.
See [the integration contract](../README.md#live-gen1-integration).

This driver reports CRC-validated packet diagnostics only. It does not decode
calibrated glucose or validate a production model/firmware claim. The native
NFC executor and encrypted storage remain separate app-owned components;
neither is included in the pure package. Gen2 and Libre 3 live behavior remain
excluded.

## Fixture policy

Core tests use synthetic UID, patch metadata, FRAM, BLE, streaming-base, and
counter values. The validator also uses the pinned MIT-licensed LibreTools
Example2 interoperability vector to prove that direct Android `Tag.getId()`
order passes all FRAM CRCs and reversed order fails. No private capture is a
fixture, and no test asserts or exposes decrypted health values. Lifecycle
tests rebuild synthetic CRC-valid FRAM for every mapped byte and representative
unknown bytes. Corruption tests cover each FRAM CRC region and the BLE CRC.
Diagnostic tests require every UID, patch, plaintext, derived command, and
lifecycle source byte to stay redacted.

Validator tests create only temporary mode-`0600` artifacts from that pinned
vector. They cover the exact schema, direct and escaped duplicate keys,
missing/extra fields, `O_NOFOLLOW` symbolic-link refusal, a deterministic
pathname-swap race after descriptor open, permissions, the 16 KiB size
boundary, UID/manufacturer/patch bindings, closed model and generation values,
343/345-byte alternatives, direct-versus-reversed UID CRC behavior, each CRC
region, and output redaction. The validator reads no directory and writes no
artifact. Unsupported non-POSIX hosts fail closed.

A lifecycle classification is read-only evidence. It does not authorize an
activation, streaming-enablement, shutdown, retry, or another state-changing
operation, and it is not proof that such an operation succeeded.

## Failure policy

Malformed topology, unknown generation, invalid state transitions, unexpected
characteristics, and authentication/session length failures end the current
connection state. Composite fragment length and timeout failures discard only
the incomplete encrypted value and remain in the passive streaming classifier.
No failure causes a retry or I/O action.

Errors retain only closed enums and byte counts. Their string form excludes
payloads, identifiers, addresses, and native error text.

The validator narrows failures further to one closed output code. It catches
filesystem, JSON, and protocol exceptions without printing their message or
stack trace.
