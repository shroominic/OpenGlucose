import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_localizations_extension.dart';
import '../persistence/health_store.dart';
import 'ai_controller.dart';
import 'ai_settings.dart';
import 'ai_settings_store.dart';

/// Optional AI settings with remote-provider details deliberately nested under
/// an Advanced disclosure.
///
/// Privacy-first by design: AI is OFF by default; the user must opt in and
/// supply their own API key (stored only in the platform secure store). The
/// pane states plainly which aggregate data is sent when generation is
/// requested, and carries the wellness disclaimer.
///
class AiSettingsPane extends StatefulWidget {
  const AiSettingsPane({
    super.key,
    required this.recentReadings,
    this.unit = GlucoseUnit.mgdl,
  });

  /// Readings used by the "generate now" dev action (from the dashboard).
  final List<CgmReading> recentReadings;
  final GlucoseUnit unit;

  @override
  State<AiSettingsPane> createState() => _AiSettingsPaneState();
}

class _AiSettingsPaneState extends State<AiSettingsPane> {
  AiSettingsStore? _store;
  AiSettings _settings = const AiSettings();
  bool _hasKey = false;
  bool _loading = true;
  bool _busy = false;
  _AiStatus? _status;

  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _apiKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = AiSettingsStore(preferences: prefs);
    final settings = store.loadSettings();
    final hasKey = await store.hasApiKey();
    if (!mounted) return;
    setState(() {
      _store = store;
      _settings = settings;
      _hasKey = hasKey;
      _baseUrlController.text = settings.baseUrl;
      _modelController.text = settings.model;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<bool> _persistDraft() async {
    final store = _store;
    if (store == null) return false;
    final next = _settings.copyWith(
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
    );
    await store.saveSettings(next);
    if (_apiKeyController.text.isNotEmpty) {
      await store.writeApiKey(_apiKeyController.text);
      _apiKeyController.clear();
    }
    final hasKey = await store.hasApiKey();
    if (!mounted) return false;
    setState(() {
      _settings = next;
      _hasKey = hasKey;
    });
    return true;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      if (await _persistDraft() && mounted) {
        setState(() => _status = const _AiStatus(_AiStatusKind.saved));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearKey() async {
    final store = _store;
    if (store == null) return;
    await store.deleteApiKey();
    if (!mounted) return;
    setState(() {
      _hasKey = false;
      _status = const _AiStatus(_AiStatusKind.apiKeyRemoved);
    });
  }

  Future<void> _generateNow() async {
    final store = _store;
    if (store == null) return;
    setState(() {
      _busy = true;
      _status = const _AiStatus(_AiStatusKind.savingProviderSettings);
    });
    HealthRepository? repo;
    try {
      if (!await _persistDraft() || !mounted) {
        return;
      }
      if (!_settings.enabled) {
        setState(
          () => _status = const _AiStatus(
            _AiStatusKind.enableCloudAiBeforeTesting,
          ),
        );
        return;
      }
      if (!_hasKey) {
        setState(
          () => _status = const _AiStatus(_AiStatusKind.addApiKeyBeforeTesting),
        );
        return;
      }
      setState(() => _status = const _AiStatus(_AiStatusKind.generating));
      repo = await openHealthRepository();
      final controller = AiController(store: store, repository: repo);
      final insight = await controller.generateRecentInsight(
        readings: widget.recentReadings,
        unit: widget.unit,
      );
      if (!mounted) return;
      setState(() {
        _status = insight == null
            ? const _AiStatus(_AiStatusKind.aiDisabledOrNoKey)
            : _AiStatus(_AiStatusKind.generatedAndSaved, detail: insight.title);
      });
    } on AiGenerationException {
      if (!mounted) return;
      setState(
        () =>
            _status = const _AiStatus(_AiStatusKind.couldNotGenerateAiInsight),
      );
    } catch (_) {
      if (!mounted) return;
      setState(
        () =>
            _status = const _AiStatus(_AiStatusKind.couldNotGenerateAiInsight),
      );
    } finally {
      await repo?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: <Widget>[
        Text(
          l10n.aiInsights,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            minTileHeight: 76,
            leading: const Icon(Icons.phone_iphone_rounded),
            title: Text(
              l10n.onDeviceModel,
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(l10n.onDeviceModelDescription),
            trailing: const _ComingSoonBadge(),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            l10n.aiWellnessPrivacyNotice,
            style: theme.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: ExpansionTile(
            key: const ValueKey<String>('advancedCloudAiProvider'),
            leading: const Icon(Icons.cloud_outlined),
            title: Text(
              l10n.customCloudProvider,
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(l10n.advancedSendsAggregatesOffDevice),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.enableCloudAi),
                subtitle: Text(l10n.cloudAiDisabledByDefault),
                value: _settings.enabled,
                onChanged: _busy
                    ? null
                    : (value) => setState(
                        () => _settings = _settings.copyWith(enabled: value),
                      ),
              ),
              TextField(
                controller: _baseUrlController,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: l10n.apiBaseUrl,
                  hintText: 'https://api.openai.com/v1',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _modelController,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: l10n.aiModel,
                  hintText: 'gpt-4o-mini',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AiAuthScheme>(
                initialValue: _settings.authScheme,
                decoration: InputDecoration(labelText: l10n.authScheme),
                items: <DropdownMenuItem<AiAuthScheme>>[
                  DropdownMenuItem(
                    value: AiAuthScheme.bearer,
                    child: Text(l10n.authSchemeBearer),
                  ),
                  DropdownMenuItem(
                    value: AiAuthScheme.xApiKey,
                    child: Text(l10n.authSchemeXApiKey),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(
                        () => _settings = _settings.copyWith(authScheme: value),
                      ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.apiKeyStoredSecurely,
                  hintText: _hasKey ? l10n.apiKeySavedMask : l10n.pasteApiKey,
                  helperText: _hasKey
                      ? l10n.apiKeySavedHint
                      : l10n.apiKeyPlainTextHint,
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      child: Text(l10n.saveProvider),
                    ),
                    if (_hasKey)
                      OutlinedButton(
                        onPressed: _busy ? null : _clearKey,
                        child: Text(l10n.removeKey),
                      ),
                    OutlinedButton.icon(
                      onPressed: (_busy || !_settings.enabled)
                          ? null
                          : _generateNow,
                      icon: const Icon(Icons.science_outlined),
                      label: Text(l10n.testWithAggregates),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_status != null) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            _status!.text(context),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }
}

class _ComingSoonBadge extends StatelessWidget {
  const _ComingSoonBadge();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey<String>('comingSoonStatus'),
      label: context.l10n.onDeviceModelStatus(context.l10n.comingSoon),
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(context.l10n.comingSoon),
          ),
        ),
      ),
    );
  }
}

enum _AiStatusKind {
  saved,
  apiKeyRemoved,
  savingProviderSettings,
  enableCloudAiBeforeTesting,
  addApiKeyBeforeTesting,
  generating,
  aiDisabledOrNoKey,
  generatedAndSaved,
  couldNotGenerateAiInsight,
}

class _AiStatus {
  const _AiStatus(this.kind, {this.detail});

  final _AiStatusKind kind;
  final String? detail;

  String text(BuildContext context) {
    final l10n = context.l10n;
    return switch (kind) {
      _AiStatusKind.saved => l10n.providerSettingsSaved,
      _AiStatusKind.apiKeyRemoved => l10n.apiKeyRemoved,
      _AiStatusKind.savingProviderSettings => l10n.savingProviderSettings,
      _AiStatusKind.enableCloudAiBeforeTesting =>
        l10n.enableCloudAiBeforeTesting,
      _AiStatusKind.addApiKeyBeforeTesting => l10n.addApiKeyBeforeTesting,
      _AiStatusKind.generating => l10n.generatingAiInsight,
      _AiStatusKind.aiDisabledOrNoKey => l10n.aiDisabledOrNoKey,
      _AiStatusKind.generatedAndSaved => l10n.generatedAndSaved(detail ?? ''),
      _AiStatusKind.couldNotGenerateAiInsight => l10n.couldNotGenerateAiInsight,
    };
  }
}
