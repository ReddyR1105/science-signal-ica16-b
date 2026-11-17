import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart' hide matches;
import 'package:science_signal/attempts.dart';
import 'package:science_signal/quiz.dart';
import 'package:science_signal/trivia.dart';

class MemoryAttempts extends Attempts {
  MemoryAttempts() : super('fixture-owner');
  int sequence = 0, writes = 0;
  final saved = <String, Map<String, dynamic>>{};
  Completer<void>? pause;
  @override
  String newId() => 'local-fixture-${++sequence}';
  @override
  Future<void> save(String id, Map<String, dynamic> p) async {
    writes++;
    if (injectService != null) {
      final code = injectService!;
      injectService = null;
      throw FirebaseException(plugin: 'fixture', code: code);
    }
    await pause?.future;
    if (saved.containsKey(id) && !matches(saved[id]!, p)) {
      throw StateError('Conflict');
    }
    saved[id] = p;
  }

  @override
  Future<bool> verify(
    String id,
    Map<String, dynamic> p, {
    bool afterCommit = false,
  }) async {
    if (denyNext && afterCommit) {
      denyNext = false;
      throw FirebaseException(plugin: 'fixture', code: 'permission-denied');
    }
    return saved.containsKey(id) && matches(saved[id]!, p);
  }
}

void main() {
  final data = File('evidence/t02.json').readAsStringSync();
  late MemoryAttempts repo;
  final capture = GlobalKey();
  Future<void> start(WidgetTester t) async {
    const font = String.fromEnvironment('CAPTURE_FONT');
    if (font.isNotEmpty) {
      await t.runAsync(() async {
        final loader = FontLoader('Evidence')
          ..addFont(
            Future.value(ByteData.sublistView(await File(font).readAsBytes())),
          );
        await loader.load();
      });
    }
    repo = MemoryAttempts();
    t.view.physicalSize = const Size(900, 1500);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: font.isEmpty ? null : 'Evidence',
            colorSchemeSeed: const Color(0xff146e69),
          ),
          home: Quiz(
            attempts: repo,
            fetch: () async => parseQuestions(data),
            currentUid: () => repo.uid,
            signOut: () async {},
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, String label) async {
    final f = find.text(label).first;
    await t.ensureVisible(f);
    await t.tap(f);
    await t.pumpAndSettle();
  }

  Future<void> finish(WidgetTester t) async {
    final qs = parseQuestions(data);
    for (var i = 0; i < 5; i++) {
      final button = t.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Continue'),
      );
      expect(button.onPressed, isNull);
      final choice = i.isEven ? qs[i].answer : !qs[i].answer;
      final label = choice ? 'True' : 'False';
      await tap(t, label);
      await tap(t, label);
      final feedback = t.widget<Text>(
        find.text(i.isEven ? 'Correct' : 'Incorrect'),
      );
      expect(
        feedback.style!.color,
        i.isEven ? Colors.teal.shade800 : Colors.red.shade800,
      );
      await tap(t, 'Continue');
    }
    expect(find.text('Round review · 3/5'), findsOneWidget);
    expect(find.textContaining('Selected:'), findsNWidgets(5));
  }

  testWidgets('T04 T05 feedback, double taps, all five entries and replay', (
    t,
  ) async {
    await start(t);
    await finish(t);
    await tap(t, 'Replay');
    expect(find.text('Question 1 of 5'), findsOneWidget);
    expect(repo.sequence, 2);
    expect(find.textContaining('Selected:'), findsNothing);
  });
  testWidgets(
    'T09 component only: acknowledged then denied and read-only retry',
    (t) async {
      await start(t);
      await finish(t);
      repo.denyNext = true;
      await tap(t, 'Submit score');
      expect(
        find.textContaining('Write acknowledged; verification unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Cloud verified'), findsNothing);
      expect(
        t
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Replay'),
            )
            .onPressed,
        isNull,
      );
      if (const bool.fromEnvironment('CAPTURE')) {
        await t.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final img = await boundary.toImage(pixelRatio: 1);
          final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
          await File('evidence/verification-fixture.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          img.dispose();
        });
      }
      await tap(t, 'Verify original round');
      expect(find.text('Cloud verified'), findsOneWidget);
      expect(repo.writes, 1);
      expect(repo.saved.keys, ['local-fixture-1']);
    },
  );
  testWidgets('T12 unavailable and quota messages with manual reconciliation', (
    t,
  ) async {
    for (final entry in {
      'unavailable': 'Cloud service unavailable.',
      'resource-exhausted': 'Cloud quota exhausted.',
    }.entries) {
      await t.pumpWidget(const SizedBox());
      await start(t);
      await finish(t);
      await tap(t, 'Inject ${entry.key} once');
      await tap(t, 'Submit score');
      expect(find.textContaining(entry.value), findsOneWidget);
      expect(find.text('Cloud verified'), findsNothing);
      await t.pump(const Duration(seconds: 30));
      expect(repo.writes, 1);
      await tap(t, 'Reconcile original round');
      expect(repo.writes, 1);
      await tap(t, 'Submit score');
      expect(find.text('Cloud verified'), findsOneWidget);
    }
  });
  testWidgets('Slow acknowledgement keeps one active transaction', (t) async {
    await start(t);
    await finish(t);
    repo.pause = Completer<void>();
    await tap(t, 'Submit score');
    await t.pump(const Duration(seconds: 11));
    expect(find.textContaining('Acknowledgement unknown.'), findsOneWidget);
    await tap(t, 'Reconcile original round');
    expect(repo.writes, 1);
    repo.pause!.complete();
    await t.pumpAndSettle();
    expect(find.text('Cloud verified'), findsOneWidget);
  });
  test('fixture is genuine JSON', () {
    expect(jsonDecode(data)['results'], hasLength(5));
  });
}
