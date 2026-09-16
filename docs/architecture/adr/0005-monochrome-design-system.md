# ADR 0005: Express glucose state through a monochrome design system

- Status: Proposed
- Date: 2026-09-16
- Owners: `@shroominic`

## Context

OpenGlucose grew a palette of teal, cream, amber, and coral accents that each
screen redefined locally. Roughly 200 literal colour values were spread across
the app, so a single visual change had to be repeated in every widget and the
result drifted between surfaces.

The palette also carried meaning. A reading was in range because it was teal
and out of range because it was amber or coral. Glucose is health information
that people read quickly, often outdoors, sometimes on a dimmed or greyscale
screen, and about one in twelve men has a colour-vision difference. Hue alone
is a fragile carrier for that state.

The product already has a distinctive mark: a black disc with a white
rounded-square cutout. Nothing in the interface referenced it.

## Decision

The app uses one ink (`#0A0A0A`), one paper (`#FFFFFF`), and a four-step grey
ramp between them. All tokens live in `openhealth/lib/src/theme/og_theme.dart`
and are the only source of colour, radius, and component shape. Feature code
references tokens and does not declare literal colours.

State is carried by contrast, weight, and shape rather than hue:

1. **Filled means present.** A solid mark means live, in range, or improved.
2. **Hollow means attention.** An outlined mark means warming up, waiting,
   out of range, or worse than the previous period.
3. **Inversion means importance.** A claim the reader must not miss, such as
   demo or sample data, becomes white on an ink bar rather than a colour.

The logo's cutout square is the app's single status glyph. It appears in the
session stage pill, the sensor lifecycle pill, weekly-recap deltas, and notice
bars. The mark itself is drawn in code so it stays crisp at any size and
inverts on ink surfaces.

The glucose chart follows the same rule. The trace is an ink line, the target
band is a light grey block, in-range readings are solid dots, and out-of-range
readings are hollow rings.

This is presentation only. It does not change sensor behaviour, Bluetooth
pairing, stored readings, exports, Health integration, or any privacy control.

## Alternatives considered

- **Keep the accent palette and only unify the tokens:** removes the drift but
  keeps hue as the sole carrier of range state.
- **Monochrome surfaces with colour reserved for range state:** reads well for
  most people, but still fails on a greyscale or dimmed screen and re-teaches
  the reader that colour is a clinical signal.
- **Add a dark theme in the same change:** doubles the review surface. The
  token layer is a prerequisite and is introduced here first.
- **Adopt an off-the-shelf design system:** supplies components but not a
  visual identity, and would not connect the interface to the product mark.

## Consequences

- New UI must take colour, radius, and component shape from the theme. A
  literal colour in feature code is a review finding.
- Any new state indicator needs a non-colour encoding, normally the filled or
  hollow mark, so it survives greyscale rendering.
- Screenshot evidence is stronger here than a colour description, so the
  reviewed surfaces are captured in `docs/design/monochrome/`.
- A dark theme becomes a token-level change instead of an app-wide rewrite.
- Platform launch screens and app icons keep their current assets and are out
  of scope for this record.

## Follow-up controls

- Review new UI for token use and for a non-colour encoding of any new state.
- Re-capture the reference screenshots when a reviewed surface changes shape.
- Verify contrast for secondary text on ink and on paper when the grey ramp
  changes.
