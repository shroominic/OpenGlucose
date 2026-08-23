import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String? _status;

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
        setState(() => _status = 'Saved.');
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
      _status = 'API key removed.';
    });
  }

  Future<void> _generateNow() async {
    final store = _store;
    if (store == null) return;
    setState(() {
      _busy = true;
      _status = 'Saving provider settings…';
    });
    HealthRepository? repo;
    try {
      if (!await _persistDraft() || !mounted) {
        return;
      }
      if (!_settings.enabled) {
        setState(() => _status = 'Enable cloud AI before testing.');
        return;
      }
      if (!_hasKey) {
        setState(() => _status = 'Add an API key before testing.');
        return;
      }
      setState(() => _status = 'Generating…');
      repo = await openHealthRepository();
      final controller = AiController(store: store, repository: repo);
      final insight = await controller.generateRecentInsight(
        readings: widget.recentReadings,
        unit: widget.unit,
      );
      if (!mounted) return;
      setState(() {
        _status = insight == null
            ? 'AI is disabled or no key set.'
            : 'Generated & saved: "${insight.title}".';
      });
    } on AiGenerationException catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Could not generate: ${error.message}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = 'Could not generate the AI insight.');
    } finally {
      await repo?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    final store = _store;
    if (store == null) return;
    setState(() {
      _busy = true;
      _status = 'Saving provider settings…';
    });
    try {
      if (!await _persistDraft() || !mounted) return;
      final controller = AiController(
        store: store,
        repository: InMemoryHealthRepository(),
      );
      final result = await controller.testRemoteConnection();
      if (!mounted) return;
      setState(() {
        _status = result.responseReceived
            ? 'Connection works. No health data was sent.'
            : 'The provider did not return a connection response.';
      });
    } on AiGenerationException catch (error) {
      if (!mounted) return;
      setState(
        () => _status = (StringBuffer(
          'Could not test connection: ',
        )..write(error.message)).toString(),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = 'Could not test the AI connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestGenerationConsent() async {
    final store = _store;
    if (store == null) return;
    setState(() {
      _busy = true;
      _status = 'Saving provider settings…';
    });
    try {
      if (!await _persistDraft() || !mounted) return;
      final controller = AiController(
        store: store,
        repository: InMemoryHealthRepository(),
      );
      final disclosure = await controller.remoteGenerationDisclosure();
      if (!mounted) return;
      if (disclosure == null) {
        setState(
          () => _status = 'Enable a valid cloud provider and add an API key.',
        );
        return;
      }
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            (StringBuffer('Send aggregates to ')
                  ..write(disclosure.endpointHostname)
                  ..write('?'))
                .toString(),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'This real generation sends only these categories. It never '
                'sends raw readings or journal note text.',
              ),
              const SizedBox(height: 12),
              for (final category in disclosure.dataCategories)
                Text('• $category'),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Generate'),
            ),
          ],
        ),
      );
      if (approved == true && mounted) {
        await _generateNow();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: <Widget>[
        Text(
          'AI insights',
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
            title: const Text(
              'On-device model',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text(
              'Planned · private local inference with a downloaded model',
            ),
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
            'Wellness and self-experimentation only—not medical advice, '
            'diagnosis, or dosing. AI remains off unless you explicitly '
            'configure it. A future on-device model will keep inference '
            'local; the advanced cloud option below sends only aggregate '
            'statistics, never raw readings or note text.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: ExpansionTile(
            key: const ValueKey<String>('advancedCloudAiProvider'),
            leading: const Icon(Icons.cloud_outlined),
            title: const Text(
              'Custom cloud provider',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text('Advanced · sends aggregates off-device'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enable cloud AI'),
                subtitle: const Text(
                  'Off by default. Requires your own API key.',
                ),
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
                decoration: const InputDecoration(
                  labelText: 'API base URL',
                  hintText: 'https://api.openai.com/v1',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _modelController,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  hintText: 'gpt-4o-mini',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AiAuthScheme>(
                initialValue: _settings.authScheme,
                decoration: const InputDecoration(labelText: 'Auth scheme'),
                items: const <DropdownMenuItem<AiAuthScheme>>[
                  DropdownMenuItem(
                    value: AiAuthScheme.bearer,
                    child: Text('Bearer (OpenAI-compatible)'),
                  ),
                  DropdownMenuItem(
                    value: AiAuthScheme.xApiKey,
                    child: Text('x-api-key (compatible gateway)'),
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
                  labelText: 'API key (stored securely)',
                  hintText: _hasKey ? '•••••••• (saved)' : 'Paste your key',
                  helperText: _hasKey
                      ? 'A key is saved. Leave blank to keep it.'
                      : 'Never stored in plain text.',
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
                      child: const Text('Save provider'),
                    ),
                    if (_hasKey)
                      OutlinedButton(
                        onPressed: _busy ? null : _clearKey,
                        child: const Text('Remove key'),
                      ),
                    OutlinedButton.icon(
                      onPressed: (_busy || !_settings.enabled)
                          ? null
                          : _testConnection,
                      icon: const Icon(Icons.wifi_tethering_rounded),
                      label: const Text('Test connection (no health data)'),
                    ),
                    FilledButton.icon(
                      onPressed: (_busy || !_settings.enabled)
                          ? null
                          : _requestGenerationConsent,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: const Text('Generate aggregate insight'),
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
            _status!,
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
      label: 'On-device model status: coming soon',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(9),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('COMING'),
          ),
        ),
      ),
    );
  }
}
