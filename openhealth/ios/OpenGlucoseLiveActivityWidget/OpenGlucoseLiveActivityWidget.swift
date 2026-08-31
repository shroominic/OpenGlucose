import ActivityKit
import SwiftUI
import WidgetKit

private let openGlucoseBrandName = "OpenGlucose"

@main
struct OpenGlucoseLiveActivityWidgetBundle: WidgetBundle {
  var body: some Widget {
    OpenGlucoseLiveActivityWidget()
  }
}

struct OpenGlucoseLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: GlucoseLiveActivityAttributes.self) { context in
      GlucoseLiveActivityLockScreenView(
        context: context,
        isStale: liveActivityIsStale(context)
      )
        .activityBackgroundTint(Color(red: 17 / 255, green: 52 / 255, blue: 55 / 255))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VStack(alignment: .leading, spacing: 6) {
            Text(openGlucoseBrandName)
              .font(.headline.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            if let updatedText = updatedText(
              for: context.state,
              isStale: liveActivityIsStale(context)
            ) {
              Text(updatedText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          .padding(.leading, 8)
          .padding(.top, 6)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if let trendText = trendText(
            for: context.state,
            isStale: liveActivityIsStale(context)
          ) {
            GlucoseLiveTrendBadge(text: trendText)
              .padding(.trailing, 8)
              .padding(.top, 6)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(alignment: .bottom, spacing: 14) {
            HStack(alignment: .bottom, spacing: 8) {
              Text(
                visibleValueText(
                  for: context.state,
                  isStale: liveActivityIsStale(context)
                )
              )
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
              VStack(alignment: .leading, spacing: 3) {
                Text(
                  visibleUnitText(
                    for: context.state,
                    isStale: liveActivityIsStale(context)
                  )
                )
                  .font(.headline.weight(.semibold))
                if let trendText = trendText(
                  for: context.state,
                  isStale: liveActivityIsStale(context)
                ) {
                  Text(trendText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
              }
            }
            Spacer(minLength: 0)
            if let updatedText = updatedText(
              for: context.state,
              isStale: liveActivityIsStale(context)
            ) {
              Text(updatedText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
          }
          .padding(.horizontal, 8)
          .padding(.top, 8)
          .padding(.bottom, 8)
        }
      } compactLeading: {
        GlucoseLiveCompactLeadingView(
          state: context.state,
          isStale: liveActivityIsStale(context)
        )
      } compactTrailing: {
        GlucoseLiveCompactTrailingView(
          state: context.state,
          isStale: liveActivityIsStale(context)
        )
      } minimal: {
        GlucoseLiveCompactLeadingView(
          state: context.state,
          isStale: liveActivityIsStale(context),
          isMinimal: true
        )
      }
      .keylineTint(
        stageColor(
          for: context.state,
          isStale: liveActivityIsStale(context)
        )
      )
    }
  }
}

/// iOS 18 and watchOS 11 automatically compose these compact presentations
/// into the Apple Watch Smart Stack. Keeping them available from iOS 16.1
/// preserves the existing Live Activity on older supported iPhones.
private struct GlucoseLiveCompactLeadingView: View {
  let state: GlucoseLiveActivityAttributes.ContentState
  let isStale: Bool
  var isMinimal = false

  @Environment(\.isLuminanceReduced) private var isLuminanceReduced

  var body: some View {
    Text(compactLeadingText(for: state, isStale: isStale))
      .font(isMinimal ? .caption2.weight(.bold) : .headline.weight(.bold))
      .monospacedDigit()
      .lineLimit(1)
      .minimumScaleFactor(0.65)
      .foregroundStyle(.primary.opacity(isLuminanceReduced ? 0.72 : 1))
      .privacySensitive(hasVisibleGlucoseValue(state, isStale: isStale))
      .accessibilityLabel(
        compactLeadingAccessibilityLabel(for: state, isStale: isStale)
      )
  }
}

private struct GlucoseLiveCompactTrailingView: View {
  let state: GlucoseLiveActivityAttributes.ContentState
  let isStale: Bool

  @Environment(\.isLuminanceReduced) private var isLuminanceReduced

  var body: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Text(compactStatusText(for: state, isStale: isStale))
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
      if let recordedAt = state.recordedAt {
        Text(recordedAt, style: .relative)
          .font(.system(size: 8, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .opacity(isLuminanceReduced ? 0.72 : 1)
    .privacySensitive(hasVisibleGlucoseValue(state, isStale: isStale))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      compactTrailingAccessibilityLabel(for: state, isStale: isStale)
    )
  }
}

private struct GlucoseLiveActivityLockScreenView: View {
  let context: ActivityViewContext<GlucoseLiveActivityAttributes>
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 12) {
        Text(openGlucoseBrandName)
          .font(.headline.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Spacer(minLength: 0)
        if let updatedText = updatedText(
          for: context.state,
          isStale: isStale
        ) {
          Text(updatedText)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.12), in: Capsule())
            .lineLimit(1)
        }
      }

      HStack(alignment: .bottom, spacing: 12) {
        Text(visibleValueText(for: context.state, isStale: isStale))
          .font(.system(size: 52, weight: .bold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.72)
        VStack(alignment: .leading, spacing: 4) {
          Text(visibleUnitText(for: context.state, isStale: isStale))
            .font(.title3.weight(.semibold))
          if let trendText = trendText(
            for: context.state,
            isStale: isStale
          ) {
            Text(trendText)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.white.opacity(0.8))
          }
        }
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .foregroundStyle(.white)
  }
}

private struct GlucoseLiveTrendBadge: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption.weight(.bold))
      .padding(.horizontal, 11)
      .padding(.vertical, 7)
      .background(Color.white.opacity(0.12), in: Capsule())
      .foregroundStyle(.white.opacity(0.92))
      .lineLimit(1)
  }
}

private func liveActivityIsStale(
  _ context: ActivityViewContext<GlucoseLiveActivityAttributes>
) -> Bool {
  if context.state.isStale {
    return true
  }
  if #available(iOS 16.2, *) {
    return context.isStale
  }
  return false
}

private func updatedText(
  for state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> String? {
  guard state.lastReadingText != "--" else {
    return nil
  }
  if isStale {
    return LiveActivityText.stale(for: liveActivityLanguage(for: state))
  }
  return LiveActivityText.updated(
    state.lastReadingText,
    for: liveActivityLanguage(for: state)
  )
}

private func trendText(
  for state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> String? {
  guard !isStale else {
    return nil
  }
  let parts = [state.trendSymbol, state.deltaText].filter { !$0.isEmpty }
  guard !parts.isEmpty else {
    return nil
  }
  return parts.joined(separator: " ")
}

private func hasVisibleGlucoseValue(
  _ state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> Bool {
  !isStale && hasGlucoseValue(state)
}

private func visibleValueText(
  for state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> String {
  if let minutes = warmupMinutes(for: state) {
    return String(minutes)
  }
  return hasVisibleGlucoseValue(state, isStale: isStale) ? state.valueText : "--"
}

private func visibleUnitText(
  for state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> String {
  if warmupMinutes(for: state) != nil {
    return LiveActivityText.minuteUnit(for: liveActivityLanguage(for: state))
  }
  return hasVisibleGlucoseValue(state, isStale: isStale) ? state.unitText : ""
}

private func hasGlucoseValue(
  _ state: GlucoseLiveActivityAttributes.ContentState
) -> Bool {
  guard !state.isWarmup else {
    return false
  }
  guard state.valueText != "--", state.valueText != "…" else {
    return false
  }
  return state.unitText == "mg/dL" || state.unitText == "mmol/L"
}

private func warmupMinutes(
  for state: GlucoseLiveActivityAttributes.ContentState
) -> Int? {
  guard state.isWarmup,
        let minutes = Int(state.valueText),
        (1...180).contains(minutes) else {
    return nil
  }
  return minutes
}

private func liveActivityLanguage(
  for state: GlucoseLiveActivityAttributes.ContentState
) -> LiveActivityLanguage {
  LiveActivityLanguage(payloadLanguageCode: state.languageCode)
}

private func compactLeadingText(
  for state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> String {
  if hasVisibleGlucoseValue(state, isStale: isStale) {
    return state.valueText
  }
  if let minutes = warmupMinutes(for: state) {
    return "\(minutes)\(LiveActivityText.compactMinuteSuffix(for: liveActivityLanguage(for: state)))"
  }
  return "--"
}

private func compactStatusText(
  for state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> String {
  let language = liveActivityLanguage(for: state)
  if isStale, hasGlucoseValue(state) {
    return LiveActivityText.stale(for: language)
  }
  if state.stageCode == "error" {
    return LiveActivityText.error(for: language)
  }
  if state.isWarmup {
    return LiveActivityText.sensorWarmingUp(for: language)
  }
  if state.stageCode == "progress" {
    return LiveActivityText.connecting(for: language)
  }
  if let trend = trendText(for: state, isStale: isStale) {
    return trend
  }
  if !state.unitText.isEmpty {
    return state.unitText
  }
  return LiveActivityText.stageLabel(
    stageCode: state.stageCode,
    isWarmup: false,
    for: language
  )
}

private func compactLeadingAccessibilityLabel(
  for state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> String {
  let language = liveActivityLanguage(for: state)
  if isStale, hasGlucoseValue(state) {
    return LiveActivityText.staleGlucoseUnavailable(for: language)
  }
  if hasVisibleGlucoseValue(state, isStale: isStale) {
    return LiveActivityText.glucoseValue(
      state.valueText,
      unit: state.unitText,
      for: language
    )
  }
  if let minutes = warmupMinutes(for: state) {
    return LiveActivityText.warmupRemaining(minutes, for: language)
  }
  return LiveActivityText.glucoseUnavailable(for: language)
}

private func compactTrailingAccessibilityLabel(
  for state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> String {
  let language = liveActivityLanguage(for: state)
  var parts = [compactStatusText(for: state, isStale: isStale)]
  if state.lastReadingText != "--" {
    parts.append(LiveActivityText.readingAt(state.lastReadingText, for: language))
  }
  return parts.joined(separator: ", ")
}

private func stageColor(
  for state: GlucoseLiveActivityAttributes.ContentState,
  isStale: Bool
) -> Color {
  if isStale && state.stageCode == "live" {
    return Color(red: 242 / 255, green: 166 / 255, blue: 90 / 255)
  }

  if state.isWarmup {
    return Color(red: 242 / 255, green: 166 / 255, blue: 90 / 255)
  }

  switch state.stageCode {
  case "live":
    return Color(red: 42 / 255, green: 182 / 255, blue: 125 / 255)
  case "error":
    return Color(red: 242 / 255, green: 109 / 255, blue: 91 / 255)
  case "progress":
    return Color(red: 242 / 255, green: 166 / 255, blue: 90 / 255)
  default:
    return Color(red: 120 / 255, green: 165 / 255, blue: 163 / 255)
  }
}
