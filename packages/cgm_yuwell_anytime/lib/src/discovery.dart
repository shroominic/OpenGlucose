/// The conservative result of classifying a BLE local name.
enum YuwellAnytimeNameKind {
  /// Reserved legacy value. The reference `ZY_WATCH` symbol resolves to the
  /// literal advertised prefix `Anytime`; a literal `ZY_WATCH` name is not
  /// accepted.
  zyWatch,

  /// The documented `Anytime` family naming form.
  anytimeFamily,

  /// The name is not an accepted candidate.
  none,
}

final _anytimePattern = RegExp(r'^Anytime[0-9]{10}$');

/// Classifies only anchored, case-sensitive candidate names.
///
/// This is a discovery hint, not a compatibility claim. Short generic words,
/// arbitrary substrings, whitespace, punctuation, and case variants are
/// rejected. A CT5 candidate is exactly `Anytime` followed by the ten-character
/// transmitter suffix derived from a 12-character box code.
YuwellAnytimeNameKind classifyYuwellAnytimeDeviceName(String? localName) {
  if (localName == null || localName.isEmpty) {
    return YuwellAnytimeNameKind.none;
  }
  if (_anytimePattern.hasMatch(localName)) {
    return YuwellAnytimeNameKind.anytimeFamily;
  }
  return YuwellAnytimeNameKind.none;
}
