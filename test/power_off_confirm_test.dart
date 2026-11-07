import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/widgets/power_off_confirm.dart';

void main() {
  const holdLabel = 'Hold 5s to close and stop';

  /// Opens the dialog; the returned list gets the answer once it's closed.
  Future<List<bool>> open(WidgetTester tester) async {
    final answers = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => answers.add(await confirmPowerOff(context, closingApp: true)),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return answers;
  }

  testWidgets('a full 5s hold says yes', (tester) async {
    final answers = await open(tester);
    final press = await tester.startGesture(tester.getCenter(find.text(holdLabel)));
    await tester.pump(const Duration(milliseconds: 4900));
    expect(answers, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(answers, [true]);
    await press.up();
  });

  testWidgets('a tap on the hold button does nothing', (tester) async {
    final answers = await open(tester);
    await tester.tap(find.text(holdLabel));
    await tester.pump(const Duration(seconds: 6));
    expect(answers, isEmpty);
    expect(find.text(holdLabel), findsOneWidget);
  });

  testWidgets('letting go early starts the hold over', (tester) async {
    final answers = await open(tester);
    final first = await tester.startGesture(tester.getCenter(find.text(holdLabel)));
    await tester.pump(const Duration(seconds: 4));
    await first.up();
    final second = await tester.startGesture(tester.getCenter(find.text(holdLabel)));
    await tester.pump(const Duration(seconds: 4));
    expect(answers, isEmpty);
    await second.up();
    await tester.pump();
  });

  testWidgets('Keep running takes one click and says no', (tester) async {
    final answers = await open(tester);
    await tester.tap(find.text('Keep running'));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });

  testWidgets('a stray tap outside the dialog says no', (tester) async {
    final answers = await open(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });
}
