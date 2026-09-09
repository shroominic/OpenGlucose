# Changelog

## 0.0.1

- Reserve the `cbio` driver contract for offline GS1 research.
- Add app-derived `FF30` discovery candidates and `FF31`/`FF32` UUID constants.
- Keep all capabilities false and fail scan/connect without transport access.
- Add strict offline plaintext ACK and packed-record inspection, with synthetic
  integrity, bounds, bit-field, and counter tests. Raw fields have no assigned units.
- Add synthetic contract tests. No live protocol or glucose support is claimed.
