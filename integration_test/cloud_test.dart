import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide matches;
import 'package:integration_test/integration_test.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:science_signal/attempts.dart';
import 'package:science_signal/firebase_options.dart';
import 'package:science_signal/quiz.dart';
import 'package:science_signal/trivia.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Class B authenticated Android acceptance', (t) async {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    final auth = FirebaseAuth.instance, db = FirebaseFirestore.instance;
    if (const bool.fromEnvironment('LOCAL_SERVICES')) {
      await auth.useAuthEmulator('10.0.2.2', 9099);
      db.useFirestoreEmulator('10.0.2.2', 8080);
    }
    final tag = DateTime.now().microsecondsSinceEpoch;
    final random = Random.secure();
    String password() => List.generate(
      32,
      (_) => String.fromCharCode(65 + random.nextInt(26)),
    ).join();
    final pwd = password(), email = 'ica16-a-$tag@example.invalid';
    void trace(String check, [String id = '']) => debugPrint(
      'ICA16 ${DateTime.now().toUtc().toIso8601String()} $check ${id.isEmpty ? "" : "…${id.substring(id.length - 5)}"}',
    );
    await auth.createUserWithEmailAndPassword(email: email, password: pwd);
    final uid = auth.currentUser!.uid;
    await auth.signOut();
    await expectLater(
      auth.signInWithEmailAndPassword(email: email, password: password()),
      throwsA(isA<FirebaseAuthException>()),
    );
    await auth.signInWithEmailAndPassword(email: email, password: pwd);
    expect(auth.currentUser!.uid, uid);
    trace('T01 credentials rejected then accepted');
    final repo = Attempts(uid);
    final qs = List.generate(
      5,
      (i) => Question('Cloud test question ${i + 1}', i.isEven),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Quiz(
          attempts: repo,
          fetch: () async => qs,
          signOut: auth.signOut,
          currentUid: () => auth.currentUser?.uid,
        ),
      ),
    );
    Future<void> wait(Finder f) async {
      final limit = DateTime.now().add(const Duration(seconds: 80));
      while (f.evaluate().isEmpty && DateTime.now().isBefore(limit)) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(f, findsWidgets);
    }

    Future<void> tap(String text) async {
      final f = find.text(text).first;
      await wait(f);
      await t.ensureVisible(f);
      await t.tap(f);
      await t.pump();
    }

    Future<String> finish() async {
      for (var i = 0; i < 5; i++) {
        await tap('True');
        await tap('Continue');
      }
      await wait(find.textContaining('Round review'));
      final text = t
          .widget<SelectableText>(find.byType(SelectableText).first)
          .data!;
      return text.substring('Round '.length);
    }

    final first = await finish();
    final submit = find.text('Submit score');
    await t.ensureVisible(submit);
    await t.tap(submit);
    await t.tap(submit, warnIfMissed: false);
    await t.pump();
    await wait(find.text('Cloud verified'));
    const server = GetOptions(source: Source.server);
    expect((await repo.collection.get(server)).docs.length, 1);
    expect(await repo.verify(first, fixed(3)), true);
    trace('T06 double-submit one exact server document', first);
    await tap('Replay');
    final second = await finish();
    repo.denyNext = true;
    await tap('Submit score');
    await wait(
      find.textContaining('Write acknowledged; verification unavailable.'),
    );
    expect(find.text('Cloud verified'), findsNothing);
    expect(await repo.verify(second, fixed(3)), true);
    await tap('Verify original round');
    await wait(find.text('Cloud verified'));
    expect((await repo.collection.get(server)).docs.length, 2);
    trace('T09 acknowledged denied then server-verified same ID', second);
    await tap('Replay');
    final third = await finish();
    await db.disableNetwork();
    try {
      await tap('Submit score');
      await wait(
        find.textContaining(
          RegExp(
            'Acknowledgement unknown|Cloud service unavailable|Cloud request returned',
          ),
        ),
      );
      expect(find.text('Cloud verified'), findsNothing);
    } finally {
      await db.enableNetwork();
    }
    final deadline = DateTime.now().add(const Duration(seconds: 80));
    while (find.text('Cloud verified').evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      for (final label in ['Reconcile original round', 'Submit score']) {
        final f = find.widgetWithText(FilledButton, label);
        if (f.evaluate().isNotEmpty &&
            t.widget<FilledButton>(f).onPressed != null) {
          await tap(label);
          break;
        }
      }
      await t.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Cloud verified'), findsOneWidget);
    expect(await repo.verify(third, fixed(3)), true);
    expect((await repo.collection.get(server)).docs.length, 3);
    trace('T08 offline then reconnected original round', third);
    final doc = repo.collection.doc(first);
    final original = (await doc.get(server)).data()!;
    final denied = throwsA(
      isA<FirebaseException>().having(
        (e) => e.code,
        'code',
        'permission-denied',
      ),
    );
    Map<String, dynamic> proposed(int score) => {
      ...fixed(score),
      'submittedAt': FieldValue.serverTimestamp(),
    };
    await expectLater(repo.collection.doc().set(proposed(6)), denied);
    await expectLater(
      repo.collection.doc().set({...proposed(2), 'extra': true}),
      denied,
    );
    await expectLater(doc.update({'correctCount': 2}), denied);
    expect((await doc.get(server)).data(), original);
    trace('T11 three invalid writes denied; original unchanged', first);
    await t.pumpWidget(const SizedBox());
    await auth.signOut();
    await auth.createUserWithEmailAndPassword(
      email: 'ica16-b-$tag@example.invalid',
      password: password(),
    );
    await expectLater(doc.get(server), denied);
    await expectLater(repo.collection.doc().set(proposed(2)), denied);
    trace('T10 foreign read and create denied', first);
    await auth.signOut();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
