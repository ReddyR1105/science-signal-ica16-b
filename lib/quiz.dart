import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'attempts.dart';
import 'trivia.dart';

enum Stage {
  loading,
  requestError,
  playing,
  readyToSubmit,
  submitting,
  verifying,
  cloudVerified,
  saveUnknown,
  permissionDenied,
  verificationUnavailable,
  conflict,
}

class Quiz extends StatefulWidget {
  final Attempts attempts;
  final Future<List<Question>> Function() fetch;
  final Future<void> Function() signOut;
  final String? Function() currentUid;
  const Quiz({
    super.key,
    required this.attempts,
    required this.fetch,
    required this.signOut,
    required this.currentUid,
  });
  @override
  State<Quiz> createState() => _Quiz();
}

class _Quiz extends State<Quiz> {
  late final repo = widget.attempts;
  Stage stage = Stage.loading;
  Round? round;
  Map<String, dynamic>? payload;
  String message = '', history = '';
  bool busy = false, ack = false;
  Timer? timer;
  bool get owner => mounted && widget.currentUid() == repo.uid;
  bool get unresolved =>
      busy ||
      [
        Stage.saveUnknown,
        Stage.verificationUnavailable,
        Stage.submitting,
        Stage.verifying,
      ].contains(stage);
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (unresolved) return;
    setState(() {
      stage = Stage.loading;
      busy = true;
      round = null;
      payload = null;
      message = '';
      ack = false;
    });
    try {
      final q = await widget.fetch();
      if (owner) {
        setState(() {
          round = Round(repo.newId(), q);
          stage = Stage.playing;
        });
      }
    } catch (e) {
      if (owner) {
        setState(() {
          stage = Stage.requestError;
          message = 'Could not load questions. $e';
        });
      }
    } finally {
      if (owner) setState(() => busy = false);
    }
  }

  Future<void> previous() async {
    if (unresolved) return;
    setState(() => busy = true);
    try {
      final r = await repo.latest().timeout(const Duration(seconds: 10));
      if (owner) {
        setState(
          () => history = r == null
              ? 'No saved rounds.'
              : 'Server verified previous round ${r.id} · ${r.score}/5',
        );
      }
    } catch (e) {
      if (owner) {
        setState(
          () => history = 'Previous round unavailable. ${serviceMessage(e)}',
        );
      }
    } finally {
      if (owner) setState(() => busy = false);
    }
  }

  Future<void> cloud() async {
    final r = round;
    if (busy || r == null || payload == null || !owner) return;
    final id = r.id;
    bool current() => owner && round?.id == id;
    final readFirst =
        ack || stage == Stage.saveUnknown || stage == Stage.permissionDenied;
    setState(() {
      busy = true;
      message = '';
    });
    void enter(Stage next) {
      timer?.cancel();
      setState(() => stage = next);
      timer = Timer(const Duration(seconds: 10), () {
        if (current()) {
          setState(() {
            stage = ack ? Stage.verificationUnavailable : Stage.saveUnknown;
            message = ack
                ? 'Write acknowledged; verification unavailable. Waiting for the server read.'
                : 'Acknowledgement unknown. Waiting for the active request before reconciliation.';
          });
        }
      });
    }

    try {
      if (readFirst) {
        enter(Stage.verifying);
        if (await repo.verify(id, payload!)) {
          if (current()) setState(() => stage = Stage.cloudVerified);
          return;
        }
        if (!current()) return;
        if (ack) throw StateError('Acknowledged document missing on server.');
        // A confirmed absence permits an explicit new submission at this same ID.
        setState(() {
          stage = Stage.readyToSubmit;
          message = 'No record on server. Submit this round again.';
        });
        return;
      }
      enter(Stage.submitting);
      await repo.save(id, payload!);
      if (!current()) return;
      ack = true;
      enter(Stage.verifying);
      if (!await repo.verify(id, payload!, afterCommit: true)) {
        throw StateError('Document missing on server.');
      }
      if (current()) {
        setState(() {
          stage = Stage.cloudVerified;
          message = '';
        });
      }
    } catch (e) {
      if (current()) {
        setState(() {
          if (ack) {
            stage = Stage.verificationUnavailable;
            message =
                'Write acknowledged; verification unavailable. ${serviceMessage(e)}';
          } else if (e is StateError) {
            stage = Stage.conflict;
            message = serviceMessage(e);
          } else {
            stage = e is FirebaseException && e.code == 'permission-denied'
                ? Stage.permissionDenied
                : Stage.saveUnknown;
            message = serviceMessage(e);
          }
        });
      }
    } finally {
      timer?.cancel();
      if (current()) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = round;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Science Signal'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: unresolved ? null : widget.signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Science & Nature',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              if (stage == Stage.loading) const LinearProgressIndicator(),
              if (stage == Stage.requestError)
                OutlinedButton(
                  onPressed: busy ? null : load,
                  child: const Text('Retry questions'),
                ),
              if (stage == Stage.playing && r != null) ...[
                Text('Question ${r.index + 1} of 5'),
                LinearProgressIndicator(value: (r.index + 1) / 5),
                const SizedBox(height: 24),
                Text(
                  r.questions[r.index].text,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                for (final v in [true, false])
                  OutlinedButton(
                    onPressed: r.answered
                        ? null
                        : () => setState(() => r.choose(v)),
                    child: Text(v ? 'True' : 'False'),
                  ),
                if (r.answered)
                  Builder(
                    builder: (_) {
                      final ok = r.choices.last == r.questions[r.index].answer;
                      return Text(
                        ok ? 'Correct' : 'Incorrect',
                        style: TextStyle(
                          color: ok
                              ? Colors.teal.shade800
                              : Colors.red.shade800,
                          fontWeight: FontWeight.bold,
                        ),
                      );
                    },
                  ),
                FilledButton(
                  onPressed: r.answered
                      ? () => setState(() {
                          if (r.advance()) {
                            payload = fixed(r.score);
                            stage = Stage.readyToSubmit;
                          }
                        })
                      : null,
                  child: const Text('Continue'),
                ),
              ],
              if (r != null && stage != Stage.playing) ...[
                Text(
                  'Round review · ${r.score}/5',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                SelectableText('Round ${r.id}'),
                if (stage == Stage.cloudVerified)
                  const ListTile(
                    leading: Icon(Icons.verified, color: Colors.teal),
                    title: Text('Cloud verified'),
                  ),
                if (stage == Stage.submitting || stage == Stage.verifying)
                  Text(
                    stage == Stage.submitting
                        ? 'Submitting…'
                        : 'Verifying on server…',
                  ),
                if (message.isNotEmpty) Text(message),
                if (![Stage.cloudVerified, Stage.conflict].contains(stage))
                  FilledButton(
                    onPressed: busy ? null : cloud,
                    child: Text(
                      stage == Stage.readyToSubmit
                          ? 'Submit score'
                          : ack
                          ? 'Verify original round'
                          : 'Reconcile original round',
                    ),
                  ),
                OutlinedButton(
                  onPressed: unresolved ? null : load,
                  child: const Text('Replay'),
                ),
                if (kDebugMode && stage == Stage.readyToSubmit) ...[
                  SwitchListTile(
                    title: const Text('Deny next post-write verification'),
                    value: repo.denyNext,
                    onChanged: (v) => setState(() => repo.denyNext = v),
                  ),
                  for (final code in ['unavailable', 'resource-exhausted'])
                    TextButton(
                      onPressed: () =>
                          setState(() => repo.injectService = code),
                      child: Text('Inject $code once'),
                    ),
                ],
                for (var i = 0; i < r.choices.length; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${i + 1}. ${r.questions[i].text}'),
                    subtitle: Text(
                      'Selected: ${r.choices[i] ? "True" : "False"}   Correct: ${r.questions[i].answer ? "True" : "False"}',
                    ),
                  ),
              ],
              if (stage == Stage.requestError) Text(message),
              const Divider(),
              TextButton(
                onPressed: unresolved ? null : previous,
                child: const Text('Retrieve latest saved round'),
              ),
              if (history.isNotEmpty) SelectableText(history),
            ],
          ),
        ),
      ),
    );
  }
}
