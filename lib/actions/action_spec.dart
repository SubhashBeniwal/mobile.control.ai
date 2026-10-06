// Declarative catalog of the daemon actions and the argument fields each one
// needs, driving the dispatch forms. Mirrors the handoff "Actions" table.
import 'package:flutter/material.dart';

enum FieldType { text, multiline, path, integer, boolean, stringList }

/// Grouping used to organize the Actions tab, each with its own accent color.
enum ActionCategory {
  system('System', Color(0xFF6366F1)),
  files('Files', Color(0xFF0EA5E9)),
  dev('Source & Git', Color(0xFF10B981)),
  ai('AI Agents', Color(0xFFA855F7)),
  ops('Deploy & Ops', Color(0xFFF59E0B));

  const ActionCategory(this.label, this.color);
  final String label;
  final Color color;
}

class ActionField {
  const ActionField(
    this.key,
    this.label, {
    this.type = FieldType.text,
    this.required = false,
    this.hint,
    this.defaultValue,
  });

  final String key;
  final String label;
  final FieldType type;
  final bool required;
  final String? hint;
  final Object? defaultValue;
}

class ActionSpec {
  const ActionSpec(
    this.action,
    this.title, {
    required this.description,
    this.icon = Icons.terminal,
    this.category = ActionCategory.system,
    this.fields = const [],
    this.needsProvider = false,
  });

  final String action;
  final String title;
  final String description;
  final IconData icon;
  final ActionCategory category;
  final List<ActionField> fields;

  /// Whether this action takes a `provider` field populated from the daemon.
  final bool needsProvider;

  /// Whether this action can be dispatched immediately with no argument form.
  bool get isQuickRun => fields.isEmpty && !needsProvider;

  static const catalog = <ActionSpec>[
    ActionSpec(
      'system.info',
      'System info',
      description: 'Daemon identity, workspaces, and capabilities',
      category: ActionCategory.system,
      icon: Icons.info_outline,
    ),
    ActionSpec(
      'agent.providers',
      'AI providers',
      description: 'List installed AI providers',
      category: ActionCategory.ai,
      icon: Icons.smart_toy,
    ),
    ActionSpec(
      'file.list',
      'List directory',
      description: 'List entries in a directory',
      category: ActionCategory.files,
      icon: Icons.folder,
      fields: [
        ActionField('path', 'Directory path',
            type: FieldType.path, required: true, hint: '/abs/dir'),
      ],
    ),
    ActionSpec(
      'file.read',
      'Read file',
      description: 'Read a file\'s contents',
      category: ActionCategory.files,
      icon: Icons.description,
      fields: [
        ActionField('path', 'File path',
            type: FieldType.path, required: true, hint: '/abs/path'),
      ],
    ),
    ActionSpec(
      'file.write',
      'Write file',
      description: 'Write or append content to a file',
      category: ActionCategory.files,
      icon: Icons.edit,
      fields: [
        ActionField('path', 'File path',
            type: FieldType.path, required: true, hint: '/abs/path'),
        ActionField('content', 'Content', type: FieldType.multiline),
        ActionField('append', 'Append', type: FieldType.boolean, defaultValue: false),
      ],
    ),
    ActionSpec(
      'git',
      'Git',
      description: 'Run raw git args in a repo',
      category: ActionCategory.dev,
      icon: Icons.merge_type,
      fields: [
        ActionField('workdir', 'Repo path',
            type: FieldType.path, required: true, hint: '/abs/repo'),
        ActionField('args', 'Args', type: FieldType.stringList,
            required: true, hint: 'status --short'),
      ],
    ),
    ActionSpec(
      'agent.run',
      'Run AI agent',
      description: 'Run an AI coding agent; output streams as logs',
      category: ActionCategory.ai,
      icon: Icons.smart_toy,
      needsProvider: true,
      fields: [
        ActionField('workdir', 'Working dir',
            type: FieldType.path, required: true, hint: '/abs/path'),
        ActionField('prompt', 'Prompt', type: FieldType.multiline, required: true),
        ActionField('model', 'Model (optional)'),
        ActionField('args', 'Extra args', type: FieldType.stringList, hint: '--flag'),
        ActionField('auto_approve', 'Auto approve',
            type: FieldType.boolean, defaultValue: false),
      ],
    ),
    ActionSpec(
      'deploy',
      'Deploy',
      description: 'Run a deploy command; output streams as logs',
      category: ActionCategory.ops,
      icon: Icons.cloud_upload,
      fields: [
        ActionField('workdir', 'Working dir',
            type: FieldType.path, required: true, hint: '/abs/dir'),
        ActionField('command', 'Command', required: true, hint: './deploy.sh'),
        ActionField('args', 'Args', type: FieldType.stringList),
        ActionField('shell', 'Run via shell (sh -c)',
            type: FieldType.boolean, defaultValue: false),
      ],
    ),
    ActionSpec(
      'pr.review',
      'PR review',
      description: 'Review a GitHub PR (needs gh on the daemon)',
      category: ActionCategory.dev,
      icon: Icons.rate_review,
      needsProvider: true,
      fields: [
        ActionField('workdir', 'Repo path',
            type: FieldType.path, required: true, hint: '/abs/repo'),
        ActionField('number', 'PR number', type: FieldType.integer, required: true),
        ActionField('model', 'Model (optional)'),
        ActionField('instructions', 'Instructions (optional)', type: FieldType.multiline),
      ],
    ),
  ];
}
