import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'attempts.dart';
import 'quiz.dart';
import 'trivia.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Widget home;
  try {
    const project = String.fromEnvironment('FIREBASE_PROJECT_ID');
    if (project.isEmpty) {
      throw StateError(
        'Supply the registered Firebase Android configuration at build time.',
      );
    }
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
        appId: String.fromEnvironment('FIREBASE_APP_ID'),
        messagingSenderId: String.fromEnvironment('FIREBASE_SENDER_ID'),
        projectId: project,
      ),
    );
    home = const AuthGate();
  } catch (e) {
    home = Scaffold(
      body: SafeArea(child: Center(child: Text('Firebase setup required. $e'))),
    );
  }
  runApp(
    MaterialApp(
      title: 'Science Signal',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xff146e69),
        useMaterial3: true,
      ),
      home: home,
    ),
  );
}

final trivia = Trivia();

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: FirebaseAuth.instance.authStateChanges(),
    builder: (context, s) {
      if (s.hasError) {
        return const Scaffold(
          body: Center(child: Text('Authentication service unavailable.')),
        );
      }
      if (s.connectionState == ConnectionState.waiting) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final user = s.data;
      return user == null
          ? const SignIn()
          : Quiz(
              key: ValueKey(user.uid),
              attempts: Attempts(user.uid),
              fetch: trivia.fetch,
              signOut: FirebaseAuth.instance.signOut,
              currentUid: () => FirebaseAuth.instance.currentUser?.uid,
            );
    },
  );
}

class SignIn extends StatefulWidget {
  const SignIn({super.key});
  @override
  State<SignIn> createState() => _SignIn();
}

class _SignIn extends State<SignIn> {
  final email = TextEditingController(), password = TextEditingController();
  String? authError;
  bool busy = false;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> login() async {
    if (busy) return;
    setState(() {
      busy = true;
      authError = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.text.trim(),
        password: password.text,
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => authError = 'Sign-in unsuccessful (${e.code}).');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Science Signal')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            Text('Sign in', style: Theme.of(context).textTheme.headlineMedium),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            if (authError != null) Text(authError!),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : login,
              child: Text(busy ? 'Signing in…' : 'Sign in'),
            ),
          ],
        ),
      ),
    ),
  );
}
