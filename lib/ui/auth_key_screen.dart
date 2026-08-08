import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/auth_manager.dart';

class AuthKeyScreen extends StatefulWidget {
  const AuthKeyScreen({super.key});

  @override
  State<AuthKeyScreen> createState() => _AuthKeyScreenState();
}

class _AuthKeyScreenState extends State<AuthKeyScreen> {
  final TextEditingController _keyController = TextEditingController();

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  /// Uses the State's own `context` (not a passed-in one) so the `mounted`
  /// guard below actually covers the context being used after the await.
  Future<void> _save() async {
    final value = _keyController.text;
    final success = await context.read<AuthManager>().saveKey(value);
    if (!mounted) return;

    if (success) {
      Navigator.pop(context);
    } else {
      {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid key length or format. Needs 32 hex chars!'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Update Auth Key')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              "Enter your 16-byte Auth Key as 32 hex characters without spaces.",
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _keyController,
              decoration: const InputDecoration(
                labelText: 'Auth Key (Hex)',
                border: OutlineInputBorder(),
                hintText: 'e.g. 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d',
              ),
              maxLength: 32,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _save,
              child: const Text('Save Auth Key'),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () {
                context.read<AuthManager>().clearKey();
                Navigator.pop(context);
              },
              child: const Text(
                'Clear Key',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
