import 'package:flutter/material.dart';

import '../actions/action_spec.dart';
import '../models/daemon.dart';

/// Bottom sheet that collects an action's argument payload and returns it as a
/// `Map<String, dynamic>` ready for dispatch, or null if cancelled.
Future<Map<String, dynamic>?> showDispatchSheet(
  BuildContext context, {
  required ActionSpec spec,
  required Daemon daemon,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _DispatchForm(spec: spec, daemon: daemon),
  );
}

class _DispatchForm extends StatefulWidget {
  const _DispatchForm({required this.spec, required this.daemon});

  final ActionSpec spec;
  final Daemon daemon;

  @override
  State<_DispatchForm> createState() => _DispatchFormState();
}

class _DispatchFormState extends State<_DispatchForm> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _bools = {};
  String? _provider;

  @override
  void initState() {
    super.initState();
    for (final f in widget.spec.fields) {
      if (f.type == FieldType.boolean) {
        _bools[f.key] = (f.defaultValue as bool?) ?? false;
      } else {
        _controllers[f.key] =
            TextEditingController(text: f.defaultValue?.toString() ?? '');
      }
    }
    if (widget.spec.needsProvider && widget.daemon.providers.isNotEmpty) {
      _provider = widget.daemon.providers.first;
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? true)) return;
    final args = <String, dynamic>{};

    if (widget.spec.needsProvider && _provider != null) {
      args['provider'] = _provider;
    }

    for (final f in widget.spec.fields) {
      switch (f.type) {
        case FieldType.boolean:
          final v = _bools[f.key] ?? false;
          // Only include non-default booleans to keep payloads clean.
          if (v != (f.defaultValue as bool? ?? false)) args[f.key] = v;
          break;
        case FieldType.integer:
          final t = _controllers[f.key]!.text.trim();
          if (t.isNotEmpty) args[f.key] = int.tryParse(t) ?? t;
          break;
        case FieldType.stringList:
          final t = _controllers[f.key]!.text.trim();
          if (t.isNotEmpty) {
            args[f.key] = t.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
          }
          break;
        default:
          final t = _controllers[f.key]!.text;
          if (t.trim().isNotEmpty) args[f.key] = t;
      }
    }
    Navigator.of(context).pop(args);
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (context, scrollController) => Form(
          key: _formKey,
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(spec.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(spec.description,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 20),
              if (spec.needsProvider) ...[
                DropdownButtonFormField<String>(
                  initialValue: _provider,
                  decoration: const InputDecoration(
                    labelText: 'Provider',
                    border: OutlineInputBorder(),
                  ),
                  items: widget.daemon.providers
                      .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                      .toList(),
                  onChanged: (v) => setState(() => _provider = v),
                  validator: (v) => v == null ? 'Pick a provider' : null,
                ),
                const SizedBox(height: 16),
              ],
              ...spec.fields.map(_buildField),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.send),
                label: Text('Dispatch ${spec.action}'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(ActionField f) {
    if (f.type == FieldType.boolean) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(f.label),
        value: _bools[f.key] ?? false,
        onChanged: (v) => setState(() => _bools[f.key] = v),
      );
    }
    final isMultiline = f.type == FieldType.multiline;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: _controllers[f.key],
        maxLines: isMultiline ? 5 : 1,
        minLines: isMultiline ? 3 : 1,
        keyboardType: f.type == FieldType.integer
            ? TextInputType.number
            : (isMultiline ? TextInputType.multiline : TextInputType.text),
        autocorrect: f.type == FieldType.path ? false : true,
        decoration: InputDecoration(
          labelText: f.label + (f.required ? ' *' : ''),
          hintText: f.hint,
          helperText: f.type == FieldType.stringList ? 'Space-separated' : null,
          border: const OutlineInputBorder(),
        ),
        validator: (v) {
          final t = v?.trim() ?? '';
          if (f.required && t.isEmpty) return 'Required';
          if (f.type == FieldType.path && t.isNotEmpty && !t.startsWith('/')) {
            return 'Must be an absolute path';
          }
          if (f.type == FieldType.integer && t.isNotEmpty && int.tryParse(t) == null) {
            return 'Must be a number';
          }
          return null;
        },
      ),
    );
  }
}
