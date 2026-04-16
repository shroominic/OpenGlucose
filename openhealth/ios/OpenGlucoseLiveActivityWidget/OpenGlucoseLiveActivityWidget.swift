import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OpenGlucoseLiveActivityWidgetBundle: WidgetBundle {
  var body: some Widget {
    OpenGlucoseLiveActivityWidget()
  }
}

struct OpenGlucoseLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: GlucoseLiveActivityAttributes.self) { context in
      GlucoseLiveActivityLockScreenView(context: context)
        .activityBackgroundTint(Color(red: 17 / 255, green: 52 / 255, blue: 55 / 255))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VStack(alignment: .leading, spacing: 6) {
            Text(context.attributes.sensorName)
              .font(.headline.weight(.semibold))
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            if let updatedText = updatedText(for: context.state) {
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
          if let trendText = trendText(for: context.state) {
            GlucoseLiveTrendBadge(text: trendText)
              .padding(.trailing, 8)
              .padding(.top, 6)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(alignment: .bottom, spacing: 14) {
            HStack(alignment: .bottom, spacing: 8) {
              Text(context.state.valueText)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
              VStack(alignment: .leading, spacing: 3) {
                Text(context.state.unitText)
                  .font(.headline.weight(.semibold))
                if let trendText = trendText(for: context.state) {
                  Text(trendText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
              }
            }
            Spacer(minLength: 0)
            if let updatedText = updatedText(for: context.state) {
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
        Text(context.state.valueText)
          .font(.headline.weight(.bold))
          .monospacedDigit()
          .minimumScaleFactor(0.7)
      } compactTrailing: {
        Text(compactTrailingText(for: context.state))
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
      } minimal: {
        Text(context.state.valueText)
          .font(.caption2.weight(.bold))
          .monospacedDigit()
      }
      .keylineTint(stageColor(for: context.state))
    }
  }

  private func compactTrailingText(
    for state: GlucoseLiveActivityAttributes.ContentState
  ) -> String {
    if !state.trendSymbol.isEmpty {
      return state.trendSymbol
    }
    return state.unitText
  }
}

private struct GlucoseLiveActivityLockScreenView: View {
  let context: ActivityViewContext<GlucoseLiveActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 12) {
        Text(context.attributes.sensorName)
          .font(.headline.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Spacer(minLength: 0)
        if let updatedText = updatedText(for: context.state) {
          Text(updatedText)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.12), in: Capsule())
            .lineLimit(1)
        }
      }

      HStack(alignment: .bottom, spacing: 12) {
        Text(context.state.valueText)
          .font(.system(size: 52, weight: .bold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.72)
        VStack(alignment: .leading, spacing: 4) {
          Text(context.state.unitText)
            .font(.title3.weight(.semibold))
          if let trendText = trendText(for: context.state) {
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

private func updatedText(for state: GlucoseLiveActivityAttributes.ContentState) -> String? {
  guard state.lastReadingText != "--" else {
    return nil
  }
  return "Updated \(state.lastReadingText)"
}

private func trendText(for state: GlucoseLiveActivityAttributes.ContentState) -> String? {
  let parts = [state.trendSymbol, state.deltaText].filter { !$0.isEmpty }
  guard !parts.isEmpty else {
    return nil
  }
  return parts.joined(separator: " ")
}

private func stageColor(for state: GlucoseLiveActivityAttributes.ContentState) -> Color {
  if state.isStale && state.stageCode == "live" {
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
