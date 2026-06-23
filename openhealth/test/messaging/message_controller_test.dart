import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/messaging/app_message.dart';
import 'package:openglucose/src/messaging/message_catalog.dart';
import 'package:openglucose/src/messaging/message_context.dart';
import 'package:openglucose/src/messaging/message_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

MessageContext _context({
  bool hasSession = true,
  bool isWarmingUp = false,
  bool hasReadings = true,
}) {
  return MessageContext(
    hasSession: hasSession,
    isWarmingUp: isWarmingUp,
    hasReadings: hasReadings,
    now: DateTime(2026, 6, 22, 12),
  );
}

Future<MessageController> _build(
  List<AppMessage> messages, {
  Map<String, Object> initial = const <String, Object>{},
}) async {
  SharedPreferences.setMockInitialValues(initial);
  final preferences = await SharedPreferences.getInstance();
  return MessageController(preferences: preferences, messages: messages);
}

void main() {
  group('selection', () {
    test('surfaces only messages whose trigger matches the context', () async {
      final controller = await _build(defaultMessageCatalog);

      controller.updateContext(_context(isWarmingUp: true, hasReadings: false));
      expect(controller.topMessage?.id, 'info.warmup');

      controller.updateContext(_context(isWarmingUp: false, hasReadings: true));
      expect(controller.topMessage?.id, 'tip.tapReading');
    });

    test('a null trigger means always eligible', () async {
      final controller = await _build(const <AppMessage>[
        AppMessage(
          id: 'always',
          kind: AppMessageKind.tip,
          title: 't',
          body: 'b',
        ),
      ]);
      controller.updateContext(_context());
      expect(controller.topMessage?.id, 'always');
    });

    test('orders by priority, then kind (alert>info>tip), then id', () async {
      final controller = await _build(const <AppMessage>[
        AppMessage(id: 'tip', kind: AppMessageKind.tip, title: 't', body: 'b'),
        AppMessage(
          id: 'info',
          kind: AppMessageKind.info,
          title: 't',
          body: 'b',
        ),
        AppMessage(
          id: 'alertLow',
          kind: AppMessageKind.alert,
          title: 't',
          body: 'b',
        ),
        AppMessage(
          id: 'alertHigh',
          kind: AppMessageKind.alert,
          title: 't',
          body: 'b',
          priority: 50,
        ),
      ]);
      controller.updateContext(_context());
      expect(
        controller.visibleMessages.map((m) => m.id).toList(),
        <String>['alertHigh', 'alertLow', 'info', 'tip'],
      );
    });
  });

  group('dismissal', () {
    test('showUntilDismissed hides the message after dismiss', () async {
      final controller = await _build(defaultMessageCatalog);
      controller.updateContext(_context(hasReadings: true));
      final tip = controller.topMessage!;
      expect(tip.id, 'tip.tapReading');

      await controller.dismiss(tip);
      expect(controller.isDismissed(tip), isTrue);
      expect(controller.topMessage, isNull);
    });

    test('non-dismissible messages cannot be dismissed', () async {
      final controller = await _build(const <AppMessage>[
        AppMessage(
          id: 'fixed',
          kind: AppMessageKind.alert,
          title: 't',
          body: 'b',
          dismissible: false,
        ),
      ]);
      controller.updateContext(_context());
      final message = controller.topMessage!;
      await controller.dismiss(message);
      expect(controller.isDismissed(message), isFalse);
      expect(controller.topMessage?.id, 'fixed');
    });

    test('persistent dismissal survives a fresh controller (next launch)',
        () async {
      final first = await _build(defaultMessageCatalog);
      first.updateContext(_context(hasReadings: true));
      await first.dismiss(first.topMessage!);

      // Same backing store, brand new controller == next app launch.
      final preferences = await SharedPreferences.getInstance();
      final second = MessageController(
        preferences: preferences,
        messages: defaultMessageCatalog,
      );
      second.updateContext(_context(hasReadings: true));
      expect(second.topMessage, isNull);
    });

    test('recurring dismissal only hides for the current run', () async {
      final messages = <AppMessage>[
        AppMessage(
          id: 'recurring',
          kind: AppMessageKind.info,
          title: 't',
          body: 'b',
          persistence: AppMessagePersistence.recurring,
          trigger: (ctx) => ctx.isWarmingUp,
        ),
      ];
      final controller = await _build(messages);
      controller.updateContext(_context(isWarmingUp: true));
      await controller.dismiss(controller.topMessage!);
      expect(controller.topMessage, isNull);

      // Persistence store is empty: a fresh controller shows it again.
      final preferences = await SharedPreferences.getInstance();
      final relaunched = MessageController(
        preferences: preferences,
        messages: messages,
      );
      relaunched.updateContext(_context(isWarmingUp: true));
      expect(relaunched.topMessage?.id, 'recurring');
    });
  });

  group('notifications', () {
    test('notifies only when the visible set changes', () async {
      final controller = await _build(defaultMessageCatalog);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.updateContext(_context(isWarmingUp: true, hasReadings: false));
      expect(notifications, 1);

      // Same selection -> no extra notification.
      controller.updateContext(_context(isWarmingUp: true, hasReadings: false));
      expect(notifications, 1);

      // Different selection -> notifies.
      controller.updateContext(_context(isWarmingUp: false, hasReadings: true));
      expect(notifications, 2);
    });
  });
}
