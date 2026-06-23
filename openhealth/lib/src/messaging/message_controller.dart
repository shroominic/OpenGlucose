import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_message.dart';
import 'message_context.dart';

/// The contextual-messaging engine.
///
/// Given a catalog of [AppMessage]s and the current [MessageContext], it
/// decides which messages should currently be visible, honouring each
/// message's [AppMessage.trigger], [AppMessage.priority], and
/// [AppMessage.persistence] / dismissal state. Dismissals persist across
/// launches via `shared_preferences`.
///
/// It is a [ChangeNotifier] to match the app's [CgmAppController] style; the
/// UI host listens to it. Selection logic is pure (see [_select]) so it is
/// directly unit-testable without a context.
///
/// This is the shared foundation: TIPS (TASK-005) and INFO BOXES (TASK-006)
/// plug in purely as additional [AppMessage]s — no changes here are needed to
/// add content.
class MessageController extends ChangeNotifier {
  MessageController({
    required SharedPreferences preferences,
    required List<AppMessage> messages,
  }) : _preferences = preferences,
       _messages = List<AppMessage>.unmodifiable(messages) {
    _dismissed = _loadDismissed();
  }

  static const _dismissedKey = 'openHealth.messaging.dismissed';

  final SharedPreferences _preferences;
  final List<AppMessage> _messages;

  /// IDs the user has permanently dismissed (showOnce / showUntilDismissed).
  late Set<String> _dismissed;

  /// IDs hidden only for the current surfacing (recurring messages). Lives in
  /// memory; reset on restart so a recurring message can reappear.
  final Set<String> _sessionDismissed = <String>{};

  MessageContext? _context;

  /// All messages currently eligible to show, highest priority first.
  List<AppMessage> get visibleMessages {
    final context = _context;
    if (context == null) {
      return const <AppMessage>[];
    }
    return _select(context);
  }

  /// The single top message to surface, or null if none. The host renders one
  /// message at a time to keep the dashboard calm; lower-priority eligible
  /// messages wait their turn.
  AppMessage? get topMessage {
    final visible = visibleMessages;
    return visible.isEmpty ? null : visible.first;
  }

  /// Feeds the latest app state in. Recomputes selection and notifies only when
  /// the visible set actually changes, to avoid spurious rebuilds.
  void updateContext(MessageContext context) {
    final before = _context == null
        ? const <AppMessage>[]
        : _select(_context!);
    _context = context;
    final after = _select(context);
    if (!_sameMessages(before, after)) {
      notifyListeners();
    }
  }

  /// Dismisses [message]. For persistent kinds this is written to
  /// `shared_preferences` so it stays dismissed across launches; recurring
  /// messages are only hidden for the current run.
  Future<void> dismiss(AppMessage message) async {
    if (!message.dismissible) {
      return;
    }
    switch (message.persistence) {
      case AppMessagePersistence.recurring:
        _sessionDismissed.add(message.id);
      case AppMessagePersistence.showOnce:
      case AppMessagePersistence.showUntilDismissed:
        if (_dismissed.add(message.id)) {
          await _persistDismissed();
        }
    }
    notifyListeners();
  }

  /// Whether [message] has been dismissed in a way that currently hides it.
  bool isDismissed(AppMessage message) {
    return _dismissed.contains(message.id) ||
        _sessionDismissed.contains(message.id);
  }

  /// Clears all persisted dismissals (used by tests / a future "reset tips"
  /// affordance).
  @visibleForTesting
  Future<void> resetDismissals() async {
    _dismissed = <String>{};
    _sessionDismissed.clear();
    await _preferences.remove(_dismissedKey);
    notifyListeners();
  }

  List<AppMessage> _select(MessageContext context) {
    final eligible = _messages
        .where((message) => !isDismissed(message) && message.matches(context))
        .toList(growable: false);
    eligible.sort(_byPriority);
    return List<AppMessage>.unmodifiable(eligible);
  }

  static int _byPriority(AppMessage a, AppMessage b) {
    final byPriority = b.priority.compareTo(a.priority);
    if (byPriority != 0) {
      return byPriority;
    }
    final byKind = _kindRank(b.kind).compareTo(_kindRank(a.kind));
    if (byKind != 0) {
      return byKind;
    }
    return a.id.compareTo(b.id);
  }

  /// alert > info > tip when priority and (so the order is deterministic).
  static int _kindRank(AppMessageKind kind) => switch (kind) {
    AppMessageKind.alert => 2,
    AppMessageKind.info => 1,
    AppMessageKind.tip => 0,
  };

  static bool _sameMessages(List<AppMessage> a, List<AppMessage> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i += 1) {
      if (a[i].id != b[i].id) {
        return false;
      }
    }
    return true;
  }

  Set<String> _loadDismissed() {
    final raw = _preferences.getStringList(_dismissedKey);
    return raw == null ? <String>{} : raw.toSet();
  }

  Future<void> _persistDismissed() async {
    await _preferences.setStringList(
      _dismissedKey,
      _dismissed.toList(growable: false),
    );
  }
}
