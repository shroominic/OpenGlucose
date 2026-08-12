# Historical OpenHealth inspiration roadmap

> [!IMPORTANT]
> This is a legacy planning artifact preserved for context. It uses the former
> OpenHealth name and is not the current OpenGlucose backlog, controls register,
> release plan, or statement of implemented capability. P0-P3 in this document
> means historical product priority; it is unrelated to the P0-P3 review-finding
> severity defined in `docs/engineering/standards.md`.

## Purpose

This document compiled reverse-engineering notes from the ignored local
`other-apps-to-take-inspiration/` directory into a proposed product backlog for
the project then named OpenHealth. Those source files are not committed, so the
app names below are descriptive references rather than repository links.

It is not a copy-the-competition list. It filters those apps through OpenHealth's current shape:

- privacy-first
- local-data-first
- open-source
- sensor-centric today
- built on a reusable CGM driver stack rather than a single closed ecosystem

## Current OpenHealth Baseline

OpenHealth today looks closest to a solid CGM reference app, not yet a full metabolic-health product. The current app already has:

- sensor scanning and connection
- snapshot/history sync
- persisted sensor selection and reading history
- a live dashboard with charting
- display preferences
- iOS/Android live activity style surfaces

What it does not yet have, compared with the inspiration set:

- rich sensor onboarding and failure recovery UX
- event logging for meals, exercise, sleep, medication, and notes
- alerting, reminders, and target ranges
- explainable analytics beyond the raw graph
- export/report workflows
- multi-source health integrations
- widgets, follower sharing, and program layers
- athlete, coaching, or biomarker workflows

## Product Principles For OpenHealth

These should shape what gets built and what gets ignored.

1. Local-first before cloud-first.
   Features should work on-device with local persistence and local analytics before introducing backend dependence.

2. Explainable metrics over opaque scores.
   If OpenHealth introduces scores, the app should show what drives them: time in range, excursion size, variability, meal response, and event context.

3. Vendor-agnostic data model.
   The workspace already separates CGM protocol logic from transport. New product features should preserve that by working on normalized readings and events, not vendor-specific hacks.

4. User-owned data.
   Import, export, backup, and report generation are core differentiators for an open app and should land earlier than commerce or growth tooling.

5. Safety and reliability before lifestyle theatrics.
   OpenHealth should ship durable pairing, reconnection, alerts, and data integrity before challenges, badges, or AI chat.

6. Optional intelligence, not mandatory lock-in.
   AI features can help with meal parsing and summarization, but the app should remain useful without them.

## Source Coverage

This roadmap originally pulled from analyses in the ignored local
`other-apps-to-take-inspiration/docs/` directory.

| App           | Best ideas worth extracting                                                        | OpenHealth fit                                          |
| ------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Lingo         | Lingo Count, weekly snapshots, dynamic targets, challenges, mood/energy check-ins  | High for snapshots/targets, medium for gamification     |
| GlucoSense    | multi-provider ingestion, AI summaries, diabetes metrics, caregiver/follower flows | High for ingestion/insights, medium for caregiver/admin |
| Stelo         | pairing recovery, target ranges, event logging, safety education, provider sharing | Very high for onboarding, alerts, reliability           |
| Veri          | meal-response scoring, food quality guidance, repeated sensor programs             | High for explainable meal scoring                       |
| Levels        | explainable glucose scoring, habit loops, health-data sync, voice logging          | High for analytics and low-friction logging             |
| Nutrisense    | coaching/chat, labs, reports, macros, weight programs                              | Medium for reports/macros, low for telehealth           |
| SIBIONICS GS3 | structured logbook, medication taxonomy, reminders, widgets, remote monitoring     | High for logbook/reminders/widgets                      |
| SIBIONICS GS1 | lighter version of logbook/reminders/follower model                                | High for minimum viable versions                        |
| Supersapiens  | athlete event model, fueling zones, Garmin/Wahoo, performance analytics            | High for optional athlete mode                          |
| Ultrahuman    | AI meal capture, widgets, mode-based programs, multi-signal expansion              | Medium for meal capture and mode framing                |
| Vively        | local journaling tables, AI advisor, challenges, community, biomarker framing      | High for local journaling, medium for AI/challenges     |

## Strategic Themes

### 1. Make OpenHealth a dependable daily driver

The strongest common denominator across Stelo, GS3, GS1, Lingo, and Supersapiens is not fancy AI. It is reliable device lifecycle handling:

- pairing guidance
- manual and assisted pairing fallback
- reconnect states
- sensor-expiry handling
- incompatible-device guidance
- background freshness
- explicit alert surfaces

This is the first major gap between OpenHealth and the production apps in the inspiration set.

### 2. Build a real context layer around glucose

Almost every app adds context on top of the glucose trace:

- meals
- exercise
- sleep
- notes
- medication or supplements
- mood / stress / energy

Without this layer, OpenHealth stays a chart viewer. With it, OpenHealth becomes an analysis tool.

### 3. Add explainable analytics, not just more charts

The most compelling products do not stop at:

- current glucose
- average glucose
- raw line chart

They provide interpretable constructs:

- time in range
- target range adherence
- stability / variability
- spike count and spike duration
- meal-response scoring
- event windows
- daily exposure or area-under-curve style summaries
- weekly recap language

This is the best place for OpenHealth to differentiate without needing a large service backend.

### 4. Win on interoperability and user control

OpenHealth should lean harder into open-source strengths than closed commercial apps can:

- easy exports
- local backups
- self-hosted or file-based sharing
- transparent metrics definitions
- sensor compatibility matrix
- optional integrations rather than forced account linking

### 5. Keep advanced programs modular

The inspiration set contains three product directions beyond generic CGM tracking:

- diabetes support
- metabolic wellness / weight / habits
- athlete fueling and recovery

OpenHealth should not mix these into one vague blob. The better approach is a shared foundation with optional modes or modules on top.

## Opportunity Map

| Theme                            | Why it matters                            | Best source apps                  | Recommended priority |
| -------------------------------- | ----------------------------------------- | --------------------------------- | -------------------- |
| Sensor lifecycle UX              | Daily usability depends on it             | Stelo, Lingo, GS3, Supersapiens   | P0                   |
| Alerts and reminders             | Makes the app operational, not passive    | Stelo, GS3, GS1                   | P0                   |
| Event timeline and journaling    | Enables useful insight generation         | GS3, Levels, Vively, Supersapiens | P0                   |
| Explainable metrics              | Core differentiator for OpenHealth        | Levels, Lingo, Veri, Stelo        | P0                   |
| Reports and export               | Strong open-source advantage              | Nutrisense, Stelo, GS3            | P1                   |
| Health platform integrations     | Adds sleep/activity context               | Levels, GlucoSense, Stelo, Vively | P1                   |
| Food logging and macros          | High value once event model exists        | Levels, Nutrisense, Ultrahuman    | P1                   |
| Weekly recap and habits          | Good retention loop after analytics exist | Lingo, Levels, Vively             | P1                   |
| Widgets and quick-glance UI      | Useful, visible, not too invasive         | GS3, GS1, Ultrahuman              | P1                   |
| Follower and caregiver sharing   | Valuable but higher privacy complexity    | GlucoSense, Stelo, GS3            | P2                   |
| Athlete mode                     | Strong niche differentiator               | Supersapiens                      | P2                   |
| AI meal capture / summarization  | Nice accelerator, not foundation          | Ultrahuman, Vively, GlucoSense    | P2                   |
| Labs / biomarkers                | Interesting, but broadens scope fast      | Nutrisense, Vively, Ultrahuman    | P3                   |
| Coaching / telehealth / commerce | Expensive and off-mission for now         | Nutrisense, Ultrahuman, Veri      | P3                   |

## Task Board

### P0: Build the minimum serious product

| ID    | Task                                      | Outcome                                                                              | Notes and inspiration                                  |
| ----- | ----------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------ |
| P0-1  | Sensor setup wizard                       | Clear onboarding for scan, select, pair, activate, sync, ready                       | Stelo and Lingo show how much failure recovery matters |
| P0-2  | Pairing fallback paths                    | Manual code entry, retry guidance, close-phone guidance, unsupported-state messaging | Mostly Stelo; also GS3 QR/NFC guidance                 |
| P0-3  | Sensor lifecycle center                   | Explicit states for warming up, ready, reconnecting, expiring, expired, failed       | Stelo, Lingo, Supersapiens                             |
| P0-4  | High/low/custom alerts                    | User-defined glucose thresholds, stale-data alerts, disconnect alerts                | Stelo, GS3, GS1                                        |
| P0-5  | Event timeline foundation                 | Normalized event model for meal, exercise, sleep, medication, note, mood             | GS3, Levels, Vively, Supersapiens                      |
| P0-6  | Annotated chart overlays                  | Show event markers directly on glucose graph                                         | Nearly universal across the better apps                |
| P0-7  | Core metrics pack                         | Time in range, average, variability, excursion count, spike count, daily summary     | Levels, Lingo, Stelo, Veri                             |
| P0-8  | Local persistence for events and insights | Keep journaling and summaries available offline                                      | Vively's local-table style is the right direction      |
| P0-9  | Daily summary screen                      | A usable "today" view with current glucose plus context and metrics                  | Stelo, Supersapiens, Ultrahuman                        |
| P0-10 | Exportable raw data                       | CSV/JSON export for readings and events                                              | Strong open-source differentiator                      |

### P1: Make the product meaningfully smarter

| ID    | Task                                        | Outcome                                                                  | Notes and inspiration                     |
| ----- | ------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------- |
| P1-1  | Health Connect and HealthKit context import | Bring in sleep, workouts, steps, heart rate, calories                    | Levels, Stelo, GlucoSense, Vively         |
| P1-2  | Meal logging v1                             | Search-free manual meal entry with time, carbs, notes, tags              | Start simple before AI food recognition   |
| P1-3  | Macro and nutrition details                 | Optional calories/protein/carbs/fat/fiber fields                         | Levels, Nutrisense, Ultrahuman            |
| P1-4  | Meal-response analytics                     | Show two-hour or configurable post-meal response cards                   | Veri, Lingo, GlucoSense                   |
| P1-5  | Explainable score system                    | Derive one or more scores from visible sub-metrics, not black-box output | Levels and Lingo are the best models here |
| P1-6  | Weekly recap and trends                     | Auto-generated weekly summary of top spikes, best windows, trend shifts  | Lingo, Stelo, Vively                      |
| P1-7  | Habit and target loops                      | Custom targets for meals, steps, sleep, or glucose exposure              | Levels and Lingo show good patterns       |
| P1-8  | Widget and lock-screen surfaces             | Home widgets plus richer live activities                                 | GS3, GS1, Ultrahuman                      |
| P1-9  | PDF report generation                       | Shareable report for personal review or clinician visits                 | Nutrisense, GS3, Stelo                    |
| P1-10 | Import/export bundles                       | Full app backup including settings, events, and history                  | Fits OpenHealth's open-data positioning   |

### P2: Add differentiated product modes

| ID   | Task                           | Outcome                                                                             | Notes and inspiration                             |
| ---- | ------------------------------ | ----------------------------------------------------------------------------------- | ------------------------------------------------- |
| P2-1 | Athlete mode                   | Event-centric analytics for fueling, training, and recovery                         | Supersapiens is the blueprint                     |
| P2-2 | Read-only share/follower mode  | Share current glucose and recent trend with selected followers                      | GlucoSense, Stelo, GS3                            |
| P2-3 | Voice capture                  | Fast meal/note logging by voice with structured extraction                          | Levels, GS3, Vively                               |
| P2-4 | Camera-assisted meal capture   | Photo intake that suggests meal components and macros                               | Ultrahuman, Vively, GlucoSense                    |
| P2-5 | AI summary assistant           | Summarize day/week patterns from local data and journal context                     | GlucoSense, Nutrisense, Vively                    |
| P2-6 | Sensor compatibility center    | Show supported devices, caveats, capability gaps, and setup guides                  | Important if OpenHealth expands beyond one driver |
| P2-7 | Advanced comparison views      | Compare day vs day, meal vs meal, event vs event                                    | Levels and Supersapiens both make this valuable   |
| P2-8 | Community-safe sharing exports | Generate branded or plain-language insight cards without exposing full account data | Supersapiens and Vively hint at this value        |

### P3: Optional expansion bets

| ID   | Task                                 | Outcome                                              | Notes and inspiration                                                     |
| ---- | ------------------------------------ | ---------------------------------------------------- | ------------------------------------------------------------------------- |
| P3-1 | Biomarker and lab layer              | Add labs, bloodwork, biomarker trends                | Nutrisense, Vively, Ultrahuman                                            |
| P3-2 | Weight and metabolic program mode    | Goal planning around weight change and macro targets | Nutrisense, Vively, Ultrahuman                                            |
| P3-3 | Structured medication knowledge base | Medication classes, reminders, insulin taxonomies    | GS3 and GS1 provide the reference shape                                   |
| P3-4 | Coach or clinician collaboration     | Notes, review workflow, report comments              | Nutrisense and Stelo show the direction, but this adds legal/process load |
| P3-5 | Commerce and subscriptions           | Premium plans, hardware reorder, billing flows       | Not recommended until the product mission is clearer                      |

## Roadmap

### Phase 1: From reference app to reliable daily app

Goal: make OpenHealth trustworthy enough to use every day.

Ship:

- P0-1 through P0-4
- P0-9
- basic export from P0-10

Success criteria:

- pairing failures are recoverable in-app
- users can understand sensor state at all times
- stale data and disconnects are visible
- the app feels operational, not demo-like

### Phase 2: Add context and interpretable insight

Goal: turn glucose readings into something a user can reason about.

Ship:

- P0-5 through P0-8
- P1-2 through P1-6

Success criteria:

- users can annotate the graph with their real day
- OpenHealth can explain spikes and stable periods
- weekly review becomes possible without cloud dependence

### Phase 3: Become the open interoperability option

Goal: make OpenHealth the easiest tool for user-owned metabolic data.

Ship:

- P1-1
- P1-8 through P1-10
- P2-6

Success criteria:

- import from platform health data
- export full history and reports
- support multiple sensors cleanly
- provide practical quick-glance surfaces

### Phase 4: Add opinionated modes

Goal: layer specialized experiences on top of the same data foundation.

Ship one of:

- athlete mode from P2-1
- share/follower mode from P2-2
- AI-assisted capture from P2-3 through P2-5

Success criteria:

- mode adds real user value without forcing complexity on everyone else
- the core app still works for plain CGM tracking

## Detailed Feature Ideas By Area

### Core CGM UX

- sensor warmup countdown
- sensor age and remaining-life card
- last successful sync time
- explicit reconnect button and auto-retry policy
- troubleshooting decision tree
- device compatibility notes per sensor
- background freshness indicator
- alert history

### Events and Journaling

- fast-add meal
- fast-add workout
- fast-add sleep quality note
- medication or supplement entry
- tags for caffeine, alcohol, stress, illness, fasting
- event templates
- duplicate previous meal/event
- event photos as optional attachments

### Insight and Analysis

- spike detector with start, peak, end, duration
- overnight summary
- part-of-day analysis
- meal-response score
- stability score
- daily exposure metric
- compare this week vs last week
- compare two meals
- compare two workout sessions

### Open Data and Power-User Features

- raw export with timestamps and metadata
- clean import/export format for backups
- public metric definitions in-app
- optional local network sync or self-hosted sync later
- developer mode with sensor diagnostics
- advanced log view and event correlation view

### Athlete-Specific Ideas

- event-first workflow instead of meal-first workflow
- fueling windows and carb timing overlays
- custom sport-specific target zones
- recovery score after workout
- Garmin/TrainingPeaks style export path
- workout comparison by glucose pattern

### AI-Optional Features

- meal photo parsing into draft entries
- voice-to-structured meal/note entry
- day and week summaries
- suggested tags for spikes
- natural-language search over local journal history

## Suggested Build Order Inside This Repository

The existing workspace already points toward a clean separation of concerns. New work should follow that shape.

1. Extend the shared domain layer first.
   Add normalized models for events, alerts, scores, and reports in the reusable packages rather than directly in Flutter UI code.

2. Keep analytics pure Dart.
   Spike detection, time-in-range, meal-response windows, and weekly summaries should live outside platform-specific code.

3. Keep sensor support modular.
   New hardware support should continue to arrive as new drivers rather than special cases embedded in the app layer.

4. Treat UI surfaces as views over local state.
   Widgets, live activities, reports, and charts should render from the same local data model.

5. Add cloud only when a feature truly requires it.
   Follower mode, clinician collaboration, and community features are the first areas that may need a service backend.

## Things OpenHealth Should Probably Not Copy Early

- subscription-first gating
- telehealth and insurance workflows
- admin consoles and organization workflows
- heavy marketing gamification before the analytics are good
- opaque AI chat that cannot cite its own evidence
- large multi-product expansion before multi-sensor support is stable

## Recommended First Cut

If the goal is to move OpenHealth from "impressive demo" to "product people can actually live in", the best first sequence is:

1. sensor lifecycle UX
2. alerts and reminders
3. event timeline
4. explainable daily metrics
5. weekly recap
6. export/report generation

That path takes the strongest recurring ideas from Stelo, Levels, Lingo, GS3, and Vively while staying aligned with OpenHealth's current architecture and open-data position.
