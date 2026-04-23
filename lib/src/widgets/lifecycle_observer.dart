import 'package:flutter/widgets.dart';

import '../internal/widget_coordinator.dart';

/// Observes app lifecycle state changes and flushes queued events when the app
/// is backgrounded or minimized.
///
/// The observer treats [AppLifecycleState.inactive] as still foreground.
/// Only transitions into [AppLifecycleState.hidden], [AppLifecycleState.paused]
/// or [AppLifecycleState.detached] are reported as backgrounding, which
/// prevents transient inactive states (e.g. presenting a native full-screen
/// component, pulling down the notification shade, incoming call overlay)
/// from terminating the current replay session.
///
/// When the app becomes non-visible, all queued session replay events are
/// flushed so data isn't lost.
class LifecycleObserver extends StatefulWidget {
  const LifecycleObserver({
    super.key,
    required this.coordinator,
    required this.child,
  });

  /// The session replay coordinator that manages event flushing
  final WidgetCoordinator coordinator;

  /// The child widget to wrap
  final Widget child;

  @override
  State<LifecycleObserver> createState() => _LifecycleObserverState();
}

class _LifecycleObserverState extends State<LifecycleObserver>
    with WidgetsBindingObserver {
  AppLifecycleState? _lastState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Check initial lifecycle state and start uploads if resumed
    final initialState = WidgetsBinding.instance.lifecycleState;
    if (initialState == AppLifecycleState.resumed) {
      widget.coordinator.logger.info(
        'LifecycleObserver detected initial resume state',
      );
      widget.coordinator.onAppForegrounded();
    }
    _lastState = initialState;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _handleLifecycleTransition(state);
  }

  /// Handle lifecycle state transitions and trigger appropriate actions
  void _handleLifecycleTransition(AppLifecycleState state) {
    widget.coordinator.logger.debug(
      'LifecycleObserver detected state change: $_lastState → $state',
    );

    // Get visibility levels for comparison
    final currentLevel = _getVisibilityLevel(state);
    final lastLevel = _lastState != null
        ? _getVisibilityLevel(_lastState!)
        : null;

    // Visibility threshold: states at or above are considered "visible".
    // `inactive` is intentionally treated as visible so that transient
    // inactive states (native full-screen components, notification shade,
    // incoming call UI, app switcher) don't terminate the current session.
    const visibleThreshold = 2;

    // Detect transition to a non-visible state from a visible one.
    if (currentLevel < visibleThreshold &&
        lastLevel != null &&
        lastLevel >= visibleThreshold) {
      widget.coordinator.logger.info(
        'LifecycleObserver detected app becoming non-visible',
      );
      widget.coordinator.onAppBackgrounded();
    }

    // Detect transition to resumed from a non-visible state (or initial).
    if (state == AppLifecycleState.resumed &&
        (lastLevel == null || lastLevel < visibleThreshold)) {
      widget.coordinator.logger.info('LifecycleObserver detected app resuming');
      widget.coordinator.onAppForegrounded();
    }

    _lastState = state;
  }

  @override
  Widget build(BuildContext context) => widget.child;

  /// Assign visibility levels to lifecycle states
  /// Higher values = more visible/active
  /// resumed (3) > inactive (2) > hidden (1) > paused (0) > detached (-1)
  int _getVisibilityLevel(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        return 3; // Fully visible and interactive
      case AppLifecycleState.inactive:
        return 2; // Visible but not interactive (e.g., notification shade pulled down)
      case AppLifecycleState.hidden:
        return 1; // Not visible but app still running
      case AppLifecycleState.paused:
        return 0; // Backgrounded, may be suspended
      case AppLifecycleState.detached:
        return -1; // Initial state or app being terminated
    }
  }
}
