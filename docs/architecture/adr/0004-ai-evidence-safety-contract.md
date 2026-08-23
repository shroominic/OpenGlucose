# ADR 0004: evidence-bound AI observation contract

- Status: Proposed, pending independent R2 review
- Date: 2026-08-24
- Owners: OpenGlucose maintainers and assigned privacy/safety owner
- Related: issue #39

## Context

AI output can be plausible but incorrect, unsafe, or based on health data that
the user did not expect to share. The previous foundation stored arbitrary
provider prose. It also described an Anthropic-compatible provider while always
serializing an OpenAI-style chat-completions request.

## Decision

OpenGlucose uses a fail-closed, versioned observation boundary:

1. Deterministic local analytics produce a MetabolicContextSnapshot of
   aggregate-only EvidenceRef values. It contains no raw readings, journal
   note text, identifiers, or API keys.
2. A generated observation is valid only when it is structured JSON matching
   ObservationDraft version 1. Each statement must cite known evidence. Each
   numeric literal must have a matching numeric claim tied to the same evidence
   value and unit.
3. Unsupported evidence, inconsistent numbers, malformed output, and output
   matching defined medical/dosing/treatment/emergency or prompt-injection
   safety patterns are rejected before persistence or display. Pattern checks
   are only one defense and do not prove that every unsafe statement is caught.
4. The shipped remote serializer is named OpenAI-compatible. Native Anthropic
   Messages is not claimed or accepted until it has a separate serializer and
   contract tests.
5. Provider metadata declares execution location, structured-output support,
   availability reason, locale, model/version, runtime version, and resource
   limits. The host must not represent unavailable on-device inference as
   available.
6. A connection test uses a fixed synthetic request and never reads health
   data or persists an insight. Real remote generation first shows the endpoint
   hostname and the exact aggregate data categories, then needs user consent.
7. A valid insight persists cited evidence plus prompt, provider, model, and
   runtime provenance. It keeps the wellness disclaimer.

## Threat model and controls

| Threat | Control in this decision | Residual risk |
| --- | --- | --- |
| Remote provider receives more data than expected | Aggregate-only snapshot, recipient/category disclosure, no redirects, explicit real-generation consent | Provider retention and legal basis need owner review |
| Prompt injection from journal content | The AI snapshot excludes free-text notes; output injection phrases fail closed | New context sources need the same review |
| Hallucinated statistics or citations | Typed evidence IDs and exact numeric/unit validation | A correctly cited statement can still be a weak interpretation |
| Medical, dosing, treatment, or emergency guidance | Prompt guardrail and output rejection fixtures | Pattern matching is not a substitute for human R2 safety review |
| API-key disclosure | Platform secure storage, no preference serialization, no logging in the contract | Platform/device compromise is outside this contract |
| Misleading provider claims | Explicit OpenAI-compatible name and capability metadata | Native provider adapters require independent tests |

## Rollback

Set AI disabled, remove the stored API key, and stop calling the provider. New
insights are local records and can be deleted through the repository contract.
The complete product delete/export UI, retention policy, and device-level
verification remain separate work. No remote automatic fallback exists.

## Consequences and follow-up

This decision intentionally adds validation friction and can reject a provider
response that was otherwise readable. That is preferred to persisting an
unsupported health claim.

This partial implementation does not close issue #39. Remaining acceptance
work includes an approved data receipt, verified full export/delete behavior,
exact OS-runtime capture in the host, an assigned privacy/safety owner,
expanded adversarial evaluation, and independent R2 review.
