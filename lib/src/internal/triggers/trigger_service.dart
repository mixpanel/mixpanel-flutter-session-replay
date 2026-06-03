import 'dart:async';

import 'package:mixpanel_flutter_common/mixpanel_flutter_common.dart';

import '../../models/event_trigger.dart';
import '../logger.dart';
import 'event_trigger_evaluator.dart';

/// Subscribes to [MixpanelEventBridge.events] and fires a callback when a
/// tracked event matches a server-configured Event Trigger.
///
/// The callback (`onTriggerFired`) is invoked with the trigger's sampling
/// percentage. The coordinator wires it to its own `startRecording`, which
/// handles the sampling decision, double-start guards, and the
/// remote-disabled check.
final class TriggerService {
  TriggerService({
    required MixpanelLogger logger,
    required void Function(double percentage) onTriggerFired,
  }) : _logger = logger,
       _onTriggerFired = onTriggerFired,
       _evaluator = EventTriggerEvaluator(const {}, logger);

  final MixpanelLogger _logger;
  final void Function(double percentage) _onTriggerFired;

  EventTriggerEvaluator _evaluator;
  StreamSubscription<MixpanelEvent>? _subscription;
  bool _isDisposed = false;

  /// Replace the active trigger set. Called by the coordinator after settings
  /// load (and on any future refresh). Passing `null` clears all triggers.
  void updateTriggers(Map<String, EventTrigger>? triggers) {
    _evaluator = EventTriggerEvaluator(triggers ?? const {}, _logger);
    _logger.debug(
      'Updated triggers (${triggers?.length ?? 0} active)',
      tag: 'triggers',
    );
  }

  /// Begin listening to the Mixpanel event bridge. Safe to call repeatedly;
  /// only the first call attaches a subscription.
  void start() {
    if (_isDisposed || _subscription != null) return;
    _subscription = MixpanelEventBridge.events.listen(
      _onEvent,
      onError: (Object error, StackTrace stack) {
        // Never let a bridge error crash the host app.
        _logger.error('MixpanelEventBridge stream error', error, stack);
      },
    );
    _logger.info('Subscribed to MixpanelEventBridge.events', tag: 'triggers');
  }

  void _onEvent(MixpanelEvent event) {
    final percentage = _evaluator.shouldStartRecording(
      event.eventName,
      event.properties,
    );
    if (percentage != null) {
      _logger.info(
        "Trigger fired for '${event.eventName}' at $percentage%",
        tag: 'triggers',
      );
      _onTriggerFired(percentage);
    } else {
      _logger.debug(
        "Event '${event.eventName}' did not match any active trigger",
        tag: 'triggers',
      );
    }
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await _subscription?.cancel();
    _subscription = null;
  }
}
