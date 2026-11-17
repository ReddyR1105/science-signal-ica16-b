import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

Map<String, dynamic> fixed(int score) => Map.unmodifiable({
  'schemaVersion': 1,
  'variant': 'B',
  'categoryId': 17,
  'questionCount': 5,
  'correctCount': score,
});
bool matches(Map<String, dynamic> data, Map<String, dynamic> expected) =>
    expected.entries.every(
      (e) =>
          data[e.key].runtimeType == e.value.runtimeType &&
          data[e.key] == e.value,
    );

class Attempts {
  final String uid;
  bool denyNext = false;
  String? injectService;
  Attempts(this.uid);
  CollectionReference<Map<String, dynamic>> get collection => FirebaseFirestore
      .instance
      .collection('users')
      .doc(uid)
      .collection('attempts');
  String newId() => collection.doc().id;
  void checkOwner() {
    if (FirebaseAuth.instance.currentUser?.uid != uid) {
      throw FirebaseException(plugin: 'auth', code: 'unauthenticated');
    }
  }

  Future<void> save(String id, Map<String, dynamic> payload) async {
    checkOwner();
    if (kDebugMode && injectService != null) {
      final code = injectService!;
      injectService = null;
      throw FirebaseException(plugin: 'debug', code: code);
    }
    final ref = collection.doc(id);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      checkOwner();
      final existing = await tx.get(ref);
      if (existing.exists) {
        if (!matches(existing.data()!, payload)) {
          throw StateError('This round ID already has a different score.');
        }
      } else {
        tx.set(ref, {...payload, 'submittedAt': FieldValue.serverTimestamp()});
      }
    });
  }

  Future<bool> verify(
    String id,
    Map<String, dynamic> payload, {
    bool afterCommit = false,
  }) async {
    checkOwner();
    if (kDebugMode && afterCommit && denyNext) {
      denyNext = false;
      throw FirebaseException(plugin: 'debug', code: 'permission-denied');
    }
    final s = await collection
        .doc(id)
        .get(const GetOptions(source: Source.server));
    if (!s.exists) return false;
    final d = s.data()!;
    if (s.id != id ||
        d.length != 6 ||
        !matches(d, payload) ||
        d['submittedAt'] is! Timestamp ||
        s.metadata.hasPendingWrites ||
        s.metadata.isFromCache) {
      throw StateError('Stored round failed verification.');
    }
    return true;
  }

  Future<({String id, int score})?> latest() async {
    checkOwner();
    final rows = await collection
        .orderBy('submittedAt', descending: true)
        .limit(1)
        .get(const GetOptions(source: Source.server));
    if (rows.docs.isEmpty) return null;
    final row = rows.docs.single;
    final score = row.data()['correctCount'];
    if (score is! int ||
        score < 0 ||
        score > 5 ||
        !await verify(row.id, fixed(score))) {
      throw StateError('Invalid saved score.');
    }
    return (id: row.id, score: score);
  }
}

String serviceMessage(Object e) {
  if (e is FirebaseException) {
    return switch (e.code) {
      'permission-denied' => 'Permission denied by Firestore.',
      'unauthenticated' => 'Authentication expired. Sign in again.',
      'unavailable' => 'Cloud service unavailable. Reconnect and try again.',
      'resource-exhausted' => 'Cloud quota exhausted. Try again later.',
      _ => 'Cloud request returned ${e.code}.',
    };
  }
  return e.toString();
}
