/// Source from which a health sample or event originated.
///
/// Keeping this sensor- and platform-agnostic lets the same models back data
/// imported from Apple Health, Android Health Connect, or entered by hand.
enum DataSource {
  /// Imported from Apple HealthKit.
  appleHealth,

  /// Imported from Android Health Connect.
  healthConnect,

  /// Entered manually by the user (e.g. journal entries).
  manual;

  /// Stable string key used for serialization.
  String get key => name;

  /// Parses a [DataSource] from its [key], falling back to [manual] for
  /// unknown or missing values so deserialization never throws.
  static DataSource fromKey(String? key) {
    if (key == null) return DataSource.manual;
    for (final value in DataSource.values) {
      if (value.name == key) return value;
    }
    return DataSource.manual;
  }
}

/// The kind of data a [TimelineEntry] carries.
///
/// Used to discriminate entries when they are merged onto a single timeline
/// for correlation features (e.g. "what was my glucose during this workout?").
enum TimelineEntryKind {
  /// A continuous glucose monitor reading (`CgmReading`).
  cgmReading,

  /// A user-authored or imported event (`HealthEvent`).
  event,

  /// An activity sample such as steps or a workout (`ActivitySample`).
  activity,

  /// A sleep stage sample (`SleepSample`).
  sleep,

  /// A heart-rate sample (`HeartRateSample`).
  heartRate,

  /// An AI-generated insight (`AiInsight`).
  aiInsight,
}

/// A common interface that lets heterogeneous health data — CGM readings,
/// journal events, and imported activity/sleep/heart-rate samples — sit
/// together on a single chronological timeline.
///
/// Anything that can be placed on the timeline exposes a [timelineTimestamp]
/// (the instant it should be sorted by) and a [timelineKind] discriminator.
/// This is intentionally minimal so existing models can adopt it without
/// breaking changes.
abstract interface class TimelineEntry {
  /// The instant this entry is positioned at on the timeline.
  ///
  /// For interval samples (activity, sleep) this is the start instant.
  DateTime get timelineTimestamp;

  /// Discriminator describing what concrete kind of entry this is.
  TimelineEntryKind get timelineKind;
}

/// Helpers for assembling and querying a mixed health-data timeline.
extension TimelineSorting<T extends TimelineEntry> on Iterable<T> {
  /// Returns a new list sorted chronologically by [TimelineEntry.timelineTimestamp]
  /// (ascending). Ties preserve their original relative order (stable sort).
  List<T> sortedByTime() {
    final indexed = toList(growable: false).asMap().entries.toList();
    indexed.sort((a, b) {
      final byTime = a.value.timelineTimestamp.compareTo(
        b.value.timelineTimestamp,
      );
      if (byTime != 0) return byTime;
      return a.key.compareTo(b.key);
    });
    return indexed.map((entry) => entry.value).toList(growable: false);
  }

  /// Returns the entries whose [TimelineEntry.timelineTimestamp] falls within
  /// the inclusive `[start, end]` window, sorted chronologically.
  List<T> inWindow(DateTime start, DateTime end) {
    return where((entry) {
      final t = entry.timelineTimestamp;
      return !t.isBefore(start) && !t.isAfter(end);
    }).sortedByTime();
  }
}

/// Merges several already-sorted (or unsorted) timeline streams into a single
/// chronologically ordered list.
///
/// Accepts entries of any [TimelineEntry] subtype, so CGM readings, events,
/// and imported samples can be interleaved for correlation features.
List<TimelineEntry> mergeTimelines(Iterable<Iterable<TimelineEntry>> streams) {
  return streams.expand((stream) => stream).sortedByTime();
}
