import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/messaging/app_message.dart';
import 'package:openglucose/src/messaging/message_context.dart';
import 'package:openglucose/src/messaging/message_controller.dart';
import 'package:openglucose/src/messaging/message_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

MessageContext _context({bool isWarmingUp = false}) => MessageContext(
  hasSession: true,
  isWarmingUp: isWarmingUp,
  hasReadings: !isWarmingUp,
  now: DateTime(2026, 6, 22, 12),
);

const _messages = <AppMessage>[
  AppMessage(
    id: 'info.warmup',
    kind: AppMessageKind.info,
    title: 'Warming up',
    body: 'Readings begin after about an hour.',
    trigger: _whileWarmingUp,
    persistence: AppMessagePersistence.recurring,
  ),
];

bool _whileWarmingUp(MessageContext ctx) => ctx.isWarmingUp;

Future<MessageController> _controller() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final preferences = await SharedPreferences.getInstance();
  return MessageController(preferences: preferences, messages: _messages);
}

void main() {
  testWidgets('renders the top message and dismisses it on tap', (
    tester,
  ) async {
    final controller = await _controller();
    controller.updateContext(_context(isWarmingUp: true));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageHost(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Warming up'), findsOneWidget);
    expect(find.text('Readings begin after about an hour.'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('messageDismiss-info.warmup')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Warming up'), findsNothing);
  });

  testWidgets('renders nothing when no message is eligible', (tester) async {
    final controller = await _controller();
    controller.updateContext(_context(isWarmingUp: false));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageHost(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Warming up'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('messageHostEmpty')),
      findsOneWidget,
    );
  });
}
