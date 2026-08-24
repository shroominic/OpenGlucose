import 'package:flutter/widgets.dart';

import 'health_repository_lifecycle.dart';

/// Makes the app-owned health-repository lifetime available to feature routes.
///
/// The nullable value keeps preview and narrow widget-test compositions
/// fail-closed: they do not create a second database when this scope is absent.
class HealthRepositoryLifecycleScope extends InheritedWidget {
  const HealthRepositoryLifecycleScope({
    super.key,
    required this.lifecycle,
    required super.child,
  });

  final AppHealthRepositoryLifecycle? lifecycle;

  static AppHealthRepositoryLifecycle? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<HealthRepositoryLifecycleScope>()
      ?.lifecycle;

  @override
  bool updateShouldNotify(HealthRepositoryLifecycleScope oldWidget) =>
      lifecycle != oldWidget.lifecycle;
}
