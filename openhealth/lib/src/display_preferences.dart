import 'package:cgm_core/cgm_core.dart';

enum ChartStyle { line, dots, candles }

class DisplayPreferences {
  const DisplayPreferences({
    this.unit = GlucoseUnit.mgdl,
    this.chartStyle = ChartStyle.line,
    this.calibrationScale = 1.0,
    this.calibrationOffset = 0.0,
    this.cropFirstSamples = 0,
    this.targetLowMgdl = 70,
    this.targetHighMgdl = 180,
  }) : assert(targetLowMgdl > 0, 'Target low must be positive.'),
       assert(
         targetHighMgdl > targetLowMgdl,
         'Target high must be greater than target low.',
       );

  final GlucoseUnit unit;
  final ChartStyle chartStyle;
  final double calibrationScale;
  final double calibrationOffset;
  final int cropFirstSamples;
  final double targetLowMgdl;
  final double targetHighMgdl;

  GlucoseRangeBounds get targetRange => GlucoseRangeBounds(
    lowMgdl: targetLowMgdl,
    highMgdl: targetHighMgdl,
  );

  double calibrate(double valueMgdl) {
    return (valueMgdl * calibrationScale) + calibrationOffset;
  }

  DisplayPreferences copyWith({
    GlucoseUnit? unit,
    ChartStyle? chartStyle,
    double? calibrationScale,
    double? calibrationOffset,
    int? cropFirstSamples,
    double? targetLowMgdl,
    double? targetHighMgdl,
  }) {
    return DisplayPreferences(
      unit: unit ?? this.unit,
      chartStyle: chartStyle ?? this.chartStyle,
      calibrationScale: calibrationScale ?? this.calibrationScale,
      calibrationOffset: calibrationOffset ?? this.calibrationOffset,
      cropFirstSamples: cropFirstSamples ?? this.cropFirstSamples,
      targetLowMgdl: targetLowMgdl ?? this.targetLowMgdl,
      targetHighMgdl: targetHighMgdl ?? this.targetHighMgdl,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'unit': unit.name,
    'chartStyle': chartStyle.name,
    'calibrationScale': calibrationScale,
    'calibrationOffset': calibrationOffset,
    'cropFirstSamples': cropFirstSamples,
    'targetLowMgdl': targetLowMgdl,
    'targetHighMgdl': targetHighMgdl,
  };

  factory DisplayPreferences.fromJson(Map<String, Object?> json) {
    final candidateLow = (json['targetLowMgdl'] as num?)?.toDouble() ?? 70;
    final candidateHigh = (json['targetHighMgdl'] as num?)?.toDouble() ?? 180;
    final validRange =
        candidateLow.isFinite &&
        candidateHigh.isFinite &&
        candidateLow > 0 &&
        candidateHigh > candidateLow;
    return DisplayPreferences(
      unit: switch (json['unit']) {
        final String value when value.isNotEmpty => GlucoseUnit.values.byName(
          value,
        ),
        _ => GlucoseUnit.mgdl,
      },
      chartStyle: switch (json['chartStyle']) {
        final String value when value.isNotEmpty => ChartStyle.values.byName(
          value,
        ),
        _ => ChartStyle.line,
      },
      calibrationScale: (json['calibrationScale'] as num?)?.toDouble() ?? 1.0,
      calibrationOffset: (json['calibrationOffset'] as num?)?.toDouble() ?? 0.0,
      cropFirstSamples: (json['cropFirstSamples'] as num?)?.toInt() ?? 0,
      targetLowMgdl: validRange ? candidateLow : 70,
      targetHighMgdl: validRange ? candidateHigh : 180,
    );
  }
}

extension CgmReadingPresentation on CgmReading {
  double displayValue(DisplayPreferences preferences) {
    return preferences.unit.convertFromMgdl(preferences.calibrate(valueMgdl));
  }
}
