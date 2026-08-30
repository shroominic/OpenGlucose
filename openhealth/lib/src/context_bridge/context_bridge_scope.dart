import 'package:flutter/widgets.dart';

import 'context_bridge.dart';

/// Provides the app-owned, cached context bridge to descendant presentation.
///
/// Widgets read [ContextBridge.snapshot] from this scope and ask the bridge to
/// reload after a completed local write. They never receive a repository from
/// this scope, so platform/import storage remains outside the widget layer.
class ContextBridgeScope extends InheritedNotifier<ContextBridge> {
  const ContextBridgeScope({
    super.key,
    ContextBridge? bridge,
    required super.child,
  }) : super(notifier: bridge);

  static ContextBridge? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ContextBridgeScope>()
      ?.notifier;
}
