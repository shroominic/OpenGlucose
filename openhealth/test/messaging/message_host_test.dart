import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/l10n/generated/app_localizations.dart';
import 'package:openglucose/src/messaging/app_message.dart';
import 'package:openglucose/src/messaging/message_catalog.dart';
import 'package:openglucose/src/messaging/message_context.dart';
import 'package:openglucose/src/messaging/message_controller.dart';
import 'package:openglucose/src/messaging/message_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _localizedApp(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

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
  return _controllerFor(_messages);
}

Future<MessageController> _controllerFor(List<AppMessage> messages) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final preferences = await SharedPreferences.getInstance();
  return MessageController(preferences: preferences, messages: messages);
}

void main() {
  testWidgets(
    'renders the sharp-rise nudge in amber with a dismiss affordance at phone width',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = await _controllerFor(
        const <AppMessage>[
          AppMessage(
            id: 'nudge.sharpRise',
            kind: AppMessageKind.nudge,
            title: '↑↑ Glucose is spiking',
            body:
                'Up 36 mg/dL in 10 minutes\nIf walking is safe for you, take a short walk now and watch how your glucose responds.',
            persistence: AppMessagePersistence.recurring,
          ),
        ],
      );
      controller.updateContext(_context());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MessageHost(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();

      final card = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey<String>('messageCard-nudge.sharpRise')),
      );
      final decoration = card.decoration as BoxDecoration;
      expect(decoration.color, const Color(0xFFFFF3D6));
      expect(
        find.bySemanticsLabel('Sharp rise wellness nudge'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('messageDismiss-nudge.sharpRise')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rerenders live sharp-rise quantification after one message id updates',
    (tester) async {
      final controller = await _controllerFor(defaultMessageCatalog);
      controller.updateContext(
        _context().copyWith(
          sharpRise: SharpRiseSignal(
            changeMgdl: 36,
            durationMinutes: 10,
            tailStart: DateTime(2026, 6, 22, 11, 50),
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MessageHost(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Up 36 mg/dL in 10 minutes'), findsOneWidget);

      controller.updateContext(
        _context().copyWith(
          sharpRise: SharpRiseSignal(
            changeMgdl: 42,
            durationMinutes: 10,
            tailStart: DateTime(2026, 6, 22, 11, 50),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Up 42 mg/dL in 10 minutes'), findsOneWidget);
    },
  );

  testWidgets('localizes sharp-rise accessibility semantics', (tester) async {
    final controller = await _controllerFor(defaultMessageCatalog);
    controller.updateContext(
      _context().copyWith(
        sharpRise: SharpRiseSignal(
          changeMgdl: 36,
          durationMinutes: 10,
          tailStart: DateTime(2026, 6, 22, 11, 50),
        ),
      ),
    );

    await tester.pumpWidget(
      _localizedApp(
        Scaffold(
          body: MessageHost(
            controller: controller,
            messageTextResolver: localizedCatalogMessageText,
          ),
        ),
        locale: const Locale('zh'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('血糖快速上升提示'), findsOneWidget);
  });

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

  testWidgets('resolves catalog message copy in Simplified Chinese', (
    tester,
  ) async {
    final controller = await _controller();
    controller.updateContext(_context(isWarmingUp: true));

    await tester.pumpWidget(
      _localizedApp(
        Scaffold(
          body: MessageHost(
            controller: controller,
            messageTextResolver: localizedCatalogMessageText,
          ),
        ),
        locale: const Locale('zh'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('预热中'), findsOneWidget);
    expect(find.text('传感器正在稳定。大约一小时后开始显示读数，无需操作。'), findsOneWidget);
  });
}
