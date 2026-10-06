import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_store.dart';
import '../state/app_state.dart';

/// Edit the relay URL and control token. The token is stored in secure storage.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>().settings;
    _urlCtrl = TextEditingController(text: s.relayUrl);
    _tokenCtrl = TextEditingController(text: s.controlToken);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    await context.read<AppState>().updateSettings(
          RelaySettings(
            relayUrl: _urlCtrl.text.trim(),
            controlToken: _tokenCtrl.text.trim(),
          ),
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved — reconnecting to relay')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Relay settings')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Relay URL',
                hintText: 'wss://relay.example.com/control',
                helperText: 'Use ws:// only for local testing',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              validator: (v) {
                final t = v?.trim() ?? '';
                if (t.isEmpty) return 'Required';
                final uri = Uri.tryParse(t);
                if (uri == null || !(uri.isScheme('ws') || uri.isScheme('wss'))) {
                  return 'Must be a ws:// or wss:// URL';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _tokenCtrl,
              obscureText: _obscureToken,
              decoration: InputDecoration(
                labelText: 'Control token',
                helperText: 'Sent as Authorization: Bearer …',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  icon: Icon(_obscureToken ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscureToken = !_obscureToken),
                ),
              ),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Save & connect'),
            ),
          ],
        ),
      ),
    );
  }
}
