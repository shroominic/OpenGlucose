import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  group('AiInsight', () {
    test('exposes timeline contract via createdAt', () {
      final insight = AiInsight(
        id: 'i1',
        createdAt: DateTime.utc(2026, 1, 1, 9),
        category: AiInsightCategory.recommendation,
        title: 'Try a walk after dinner',
      );
      expect(insight.timelineTimestamp, DateTime.utc(2026, 1, 1, 9));
      expect(insight.timelineKind, TimelineEntryKind.aiInsight);
      expect(insight.body, '');
      expect(insight.tags, isEmpty);
    });

    test('round-trips through JSON', () {
      final insight = AiInsight(
        id: 'i2',
        createdAt: DateTime.utc(2026, 2, 3, 12, 30),
        category: AiInsightCategory.pattern,
        title: 'High-carb dinners spike you',
        body: 'On 4 of 5 days a >60g dinner preceded a >180 mg/dL peak.',
        windowStart: DateTime.utc(2026, 2, 1),
        windowEnd: DateTime.utc(2026, 2, 3),
        confidence: 0.82,
        model: 'on-device-v1',
        tags: const ['carbs', 'dinner'],
      );
      final restored = AiInsight.fromJson(insight.toJson());
      expect(restored.id, insight.id);
      expect(restored.createdAt, insight.createdAt);
      expect(restored.category, AiInsightCategory.pattern);
      expect(restored.title, insight.title);
      expect(restored.body, insight.body);
      expect(restored.windowStart, insight.windowStart);
      expect(restored.windowEnd, insight.windowEnd);
      expect(restored.confidence, 0.82);
      expect(restored.model, 'on-device-v1');
      expect(restored.tags, insight.tags);
    });

    test('unknown category falls back to custom', () {
      expect(AiInsightCategory.fromKey('nope'), AiInsightCategory.custom);
      expect(AiInsightCategory.fromKey(null), AiInsightCategory.custom);
    });

    test('copyWith can clear optional fields', () {
      final insight = AiInsight(
        id: 'i3',
        createdAt: DateTime.utc(2026, 1, 1),
        category: AiInsightCategory.summary,
        title: 'Weekly recap',
        windowStart: DateTime.utc(2025, 12, 25),
        windowEnd: DateTime.utc(2026, 1, 1),
        confidence: 0.5,
        model: 'm',
      );
      final cleared = insight.copyWith(
        clearWindow: true,
        clearConfidence: true,
        clearModel: true,
      );
      expect(cleared.windowStart, isNull);
      expect(cleared.windowEnd, isNull);
      expect(cleared.confidence, isNull);
      expect(cleared.model, isNull);
      expect(cleared.title, 'Weekly recap');
    });
  });
}
