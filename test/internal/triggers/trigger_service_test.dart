// Tests drive MixpanelEventBridge.notifyListeners directly to simulate
// upstream events. The member is @internal but reserved for Mixpanel-authored
// downstream packages like this one.
// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter_test/flutter_test.dart';
import 'package:mixpanel_flutter_common/mixpanel_flutter_common.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/logger.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/triggers/trigger_service.dart';
import 'package:mixpanel_flutter_session_replay/src/models/configuration.dart';
import 'package:mixpanel_flutter_session_replay/src/models/event_trigger.dart';

void main() {
  final logger = MixpanelLogger(LogLevel.none);

  late List<double> fired;
  late TriggerService service;

  setUp(() {
    fired = <double>[];
    service = TriggerService(logger: logger, onTriggerFired: fired.add);
  });

  tearDown(() async {
    await service.dispose();
  });

  test('does not fire before start() is called', () async {
    service.updateTriggers({'Login': const EventTrigger(percentage: 100)});
    MixpanelEventBridge.notifyListeners(eventName: 'Login');
    await Future<void>.delayed(Duration.zero);
    expect(fired, isEmpty);
  });

  test('fires callback with trigger percentage when event matches', () async {
    service.updateTriggers({'Login': const EventTrigger(percentage: 42)});
    service.start();
    MixpanelEventBridge.notifyListeners(eventName: 'Login');
    await Future<void>.delayed(Duration.zero);
    expect(fired, [42]);
  });

  test('does not fire when event name has no registered trigger', () async {
    service.updateTriggers({'Login': const EventTrigger(percentage: 100)});
    service.start();
    MixpanelEventBridge.notifyListeners(eventName: 'Logout');
    await Future<void>.delayed(Duration.zero);
    expect(fired, isEmpty);
  });

  test('updateTriggers(null) clears all triggers', () async {
    service.updateTriggers({'Login': const EventTrigger(percentage: 100)});
    service.start();
    service.updateTriggers(null);
    MixpanelEventBridge.notifyListeners(eventName: 'Login');
    await Future<void>.delayed(Duration.zero);
    expect(fired, isEmpty);
  });

  test(
    'updateTriggers swaps the active trigger set without resubscribing',
    () async {
      service.updateTriggers({'A': const EventTrigger(percentage: 10)});
      service.start();

      MixpanelEventBridge.notifyListeners(eventName: 'A');
      await Future<void>.delayed(Duration.zero);
      expect(fired, [10]);

      service.updateTriggers({'B': const EventTrigger(percentage: 90)});
      MixpanelEventBridge.notifyListeners(
        eventName: 'A',
      ); // no longer registered
      MixpanelEventBridge.notifyListeners(eventName: 'B');
      await Future<void>.delayed(Duration.zero);
      expect(fired, [10, 90]);
    },
  );

  test(
    'start() is idempotent (does not create duplicate subscriptions)',
    () async {
      service.updateTriggers({'Once': const EventTrigger(percentage: 1)});
      service.start();
      service.start();
      service.start();

      MixpanelEventBridge.notifyListeners(eventName: 'Once');
      await Future<void>.delayed(Duration.zero);
      // Single subscription → callback fired once, not three times.
      expect(fired, [1]);
    },
  );

  test('after dispose(), no further callbacks fire', () async {
    service.updateTriggers({'X': const EventTrigger(percentage: 100)});
    service.start();
    await service.dispose();

    MixpanelEventBridge.notifyListeners(eventName: 'X');
    await Future<void>.delayed(Duration.zero);
    expect(fired, isEmpty);
  });

  test('events that pass propertyFilters fire the callback', () async {
    service.updateTriggers({
      'Purchase': const EventTrigger(
        percentage: 25,
        propertyFilters: {
          '>': [
            {'var': 'amount'},
            100,
          ],
        },
      ),
    });
    service.start();

    MixpanelEventBridge.notifyListeners(
      eventName: 'Purchase',
      properties: {'amount': 50},
    );
    await Future<void>.delayed(Duration.zero);
    expect(fired, isEmpty);

    MixpanelEventBridge.notifyListeners(
      eventName: 'Purchase',
      properties: {'amount': 250},
    );
    await Future<void>.delayed(Duration.zero);
    expect(fired, [25]);
  });
}
