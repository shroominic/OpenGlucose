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

    test('round-trips validated evidence and provenance', () {
      final start = DateTime.utc(2026, 2, 1);
      final end = DateTime.utc(2026, 2, 2);
      final insight = AiInsight(
        id: 'i-evidence',
        createdAt: end,
        category: AiInsightCategory.summary,
        title: 'Evidence-bound summary',
        evidence: <EvidenceRef>[
          EvidenceRef(
            id: 'glucose.average',
            kind: AiEvidenceKind.glucoseAggregate,
            label: 'Average glucose',
            value: 111,
            unit: 'mg/dL',
            windowStart: start,
            windowEnd: end,
            sampleCount: 288,
          ),
        ],
        statements: <AiInsightStatement>[
          AiInsightStatement(
            text: 'Recorded average glucose: 111 mg/dL in this window.',
            evidence: <EvidenceRef>[
              EvidenceRef(
                id: 'glucose.average',
                kind: AiEvidenceKind.glucoseAggregate,
                label: 'Average glucose',
                value: 111,
                unit: 'mg/dL',
                windowStart: start,
                windowEnd: end,
                sampleCount: 288,
              ),
            ],
            numericClaims: const <AiNumericClaim>[
              AiNumericClaim(
                evidenceId: 'glucose.average',
                value: 111,
                unit: 'mg/dL',
              ),
            ],
          ),
        ],
        provenance: const AiGenerationProvenance(
          contractVersion: aiObservationContractVersion,
          promptTemplateVersion: aiPromptTemplateVersion,
          providerKind: AiProviderKind.openAiCompatibleRemote,
          executionLocation: AiExecutionLocation.remote,
          locale: 'en',
          model: 'test-model',
          modelVersion: 'test-model-2026-01',
          runtimeVersion: 'Android 16',
          endpointHostname: 'api.example.com',
        ),
      );

      final restored = AiInsight.fromJson(insight.toJson());

      expect(restored.evidence.single.id, 'glucose.average');
      expect(restored.evidence.single.value, 111);
      expect(restored.statements, hasLength(1));
      expect(restored.statements.single.evidence.single.id, 'glucose.average');
      expect(restored.statements.single.numericClaims.single.unit, 'mg/dL');
      expect(
        restored.provenance!.promptTemplateVersion,
        aiPromptTemplateVersion,
      );
      expect(restored.provenance!.runtimeVersion, 'Android 16');
      expect(
        restored.body,
        'Recorded average glucose: 111 mg/dL in this window.\n\n'
        '${AiDisclaimer.short}',
      );
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

    test(
      'drops a stored statement that is not the canonical local rendering',
      () {
        final start = DateTime.utc(2026, 2, 1);
        final end = DateTime.utc(2026, 2, 2);
        final restored = AiInsight.fromJson(<String, Object?>{
          'id': 'i-untrusted-statement',
          'createdAt': end.toIso8601String(),
          'category': 'summary',
          'title': 'Summary',
          'body': 'Take insulin now.',
          'statements': <Object?>[
            <String, Object?>{
              'text': 'Take insulin now.',
              'evidence': <Object?>[
                EvidenceRef(
                  id: 'glucose.average',
                  kind: AiEvidenceKind.glucoseAggregate,
                  label: 'Average glucose',
                  value: 111,
                  unit: 'mg/dL',
                  windowStart: start,
                  windowEnd: end,
                  sampleCount: 288,
                ).toJson(),
              ],
              'numericClaims': const <Object?>[
                <String, Object?>{
                  'evidenceId': 'glucose.average',
                  'value': 111,
                  'unit': 'mg/dL',
                },
              ],
            },
          ],
          'provenance': AiGenerationProvenance(
            contractVersion: aiObservationContractVersion,
            promptTemplateVersion: aiPromptTemplateVersion,
            providerKind: AiProviderKind.openAiCompatibleRemote,
            executionLocation: AiExecutionLocation.remote,
            locale: 'en',
            model: 'test-model',
            modelVersion: 'test-model',
            runtimeVersion: 'test-os',
          ).toJson(),
        });

        expect(restored.statements, isEmpty);
        expect(restored.evidence, isEmpty);
        expect(restored.body, isNot(contains('Take insulin now.')));
        expect(restored.body, contains('not displayed'));
      },
    );

    test('suppresses an arbitrary legacy v1 AI body before display', () {
      final restored = AiInsight.fromJson(<String, Object?>{
        'id': 'legacy-ai',
        'createdAt': DateTime.utc(2026, 2, 2).toIso8601String(),
        'category': 'recommendation',
        'title': 'Provider title',
        'body': 'Take insulin now and change your treatment.',
        'provenance': AiGenerationProvenance(
          contractVersion: 1,
          promptTemplateVersion: 'observation-evidence-v1',
          providerKind: AiProviderKind.openAiCompatibleRemote,
          executionLocation: AiExecutionLocation.remote,
          locale: 'en',
          model: 'legacy-model',
          modelVersion: 'legacy-model',
          runtimeVersion: 'legacy-os',
        ).toJson(),
      });

      expect(restored.statements, isEmpty);
      expect(restored.evidence, isEmpty);
      expect(restored.body, isNot(contains('Take insulin now')));
      expect(restored.body, isNot(contains('treatment')));
      expect(restored.body, contains('no verified evidence mapping'));
      expect(restored.body, contains(AiDisclaimer.short));
    });
  });
}
