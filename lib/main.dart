import 'package:flutter/material.dart';

import 'gate_settings.dart';
import 'hikvision_service.dart';

void main() => runApp(const GateApp());

class GateApp extends StatelessWidget {
  const GateApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Wonderla Gate Access',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF17357A),
        primary: const Color(0xFF17357A),
        secondary: const Color(0xFFFFD500),
      ),
      scaffoldBackgroundColor: const Color(0xFFF5F7FB),
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF17357A),
        foregroundColor: Colors.white,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF17357A),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: const GatePage(),
  );
}

class _ActivityEntry {
  const _ActivityEntry(this.at, this.message, [this.error = false]);
  final DateTime at;
  final String message;
  final bool error;

  Map<String, Object> toJson() => {
    'at': at.toIso8601String(),
    'message': message,
    'error': error,
  };

  factory _ActivityEntry.fromJson(Map<String, dynamic> json) => _ActivityEntry(
    DateTime.parse(json['at'] as String),
    json['message'] as String,
    json['error'] as bool? ?? false,
  );
}

class GatePage extends StatefulWidget {
  const GatePage({super.key, this.service});
  final HikvisionService? service;
  @override
  State<GatePage> createState() => _GatePageState();
}

class _GatePageState extends State<GatePage> {
  final GateSettingsStore _settingsStore = GateSettingsStore();
  final GateActivityStore _activityStore = GateActivityStore();
  HikvisionService? _service;
  bool _busy = false;
  String _status = 'Not connected';
  String? _message;
  final List<_ActivityEntry> _activity = [];
  Future<void> _activityWrite = Future<void>.value();

  void _log(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _activity.insert(0, _ActivityEntry(DateTime.now(), message, error));
      if (_activity.length > GateActivityStore.maxEntries) {
        _activity.removeRange(GateActivityStore.maxEntries, _activity.length);
      }
    });
    _saveActivity();
  }

  Future<void> _saveActivity() async {
    final snapshot = _activity.map((entry) => entry.toJson()).toList();
    _activityWrite = _activityWrite.then((_) async {
      try {
        await _activityStore.save(snapshot);
      } on Object {
        // Activity remains available for this session if secure storage fails.
      }
    });
    await _activityWrite;
  }

  Future<void> _loadActivity() async {
    try {
      final stored = await _activityStore.load();
      if (!mounted || stored.isEmpty) return;
      final oldEntries = stored.map(_ActivityEntry.fromJson).toList();
      setState(() {
        _activity.addAll(oldEntries);
        _activity.sort((a, b) => b.at.compareTo(a.at));
        if (_activity.length > GateActivityStore.maxEntries) {
          _activity.removeRange(GateActivityStore.maxEntries, _activity.length);
        }
      });
    } on Object {
      // A damaged or unavailable history must not prevent terminal setup.
    }
  }

  Future<void> _showActivity() => showDialog<void>(
    context: context,
    builder: (_) => _ActivityDialog(entries: List.unmodifiable(_activity)),
  );

  @override
  void initState() {
    super.initState();
    _service = widget.service;
    _loadActivity();
    if (_service == null) _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await _settingsStore.load();
    if (!mounted) return;
    if (settings != null) {
      _service = settings.createService();
      _log('Saved terminal settings loaded');
    }
    setState(() {});
  }

  Future<void> _configure() async {
    final settings = await showDialog<GateSettings>(
      context: context,
      builder: (context) => _SettingsDialog(
        initial: _service == null
            ? null
            : GateSettings(
                host: _service!.host,
                port: _service!.port,
                useHttps: _service!.useHttps,
                doorId: _service!.doorId,
                username: _service!.username,
                password: _service!.password,
                endpointVerified: _service!.endpointVerified,
              ),
      ),
    );
    if (settings == null || !mounted) {
      if (mounted) _log('Terminal setup cancelled');
      return;
    }
    await _settingsStore.save(settings);
    if (!mounted) return;
    setState(() {
      _service = settings.createService();
      _status = 'Connection not checked';
      _message =
          'Target: ${settings.useHttps ? 'https' : 'http'}://${settings.host}:${settings.port}';
    });
    _log(
      'SETTINGS SAVED | Target: ${settings.useHttps ? 'https' : 'http'}://${settings.host}:${settings.port} | Door ID: ${settings.doorId} | Password not logged',
    );
  }

  Future<void> _checkConnection() async {
    final service = _service;
    if (_busy || service == null || !service.canCheckConnection) return;
    service.onProgress = (message) => _log(
      message,
      error:
          message.startsWith('NOT CONNECTED') ||
          message.startsWith('DEVICE REACHED, CHECK FAILED'),
    );
    setState(() {
      _busy = true;
      _status = 'Checking connection';
      _message = 'Connecting to ${service.connectionAddress}';
    });
    _log(
      'OPERATOR STARTED CONNECTION CHECK | Target: ${service.connectionAddress}',
    );
    try {
      final result = await service.checkConnection();
      if (!mounted) return;
      setState(() {
        _status = result.openSupported
            ? 'Connected'
            : 'Connected, open unavailable';
        _message = result.openSupported
            ? 'Device responded at ${result.address} (HTTP ${result.httpStatus}). Open command is supported.'
            : 'Device responded at ${result.address} (HTTP ${result.httpStatus}), but firmware did not advertise the open command.';
      });
    } on HikvisionException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = error.deviceResponded
            ? 'Device reached, check failed'
            : 'Not connected';
        _message = '${service.connectionAddress} — ${error.message}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openGate() async {
    if (_busy || _service == null) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open gate?'),
        content: const Text('Send an open command to the configured gate?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open gate'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) {
      if (mounted) _log('Gate opening cancelled');
      return;
    }
    _log('Gate opening requested by operator');
    _service!.onProgress = (message) => _log(
      message,
      error:
          message.startsWith('NOT CONNECTED') ||
          message.startsWith('COMMAND RESULT UNKNOWN'),
    );
    setState(() {
      _busy = true;
      _status = 'Connecting to terminal';
      _message = _service!.connectionAddress;
    });
    try {
      final result = await _service!.openDoor();
      if (!mounted) return;
      final message = result.physicalOpeningConfirmed
          ? 'Gate opened.'
          : 'The device accepted the command. Physical gate movement was not confirmed.';
      setState(() {
        _status = 'Command accepted';
        _message = message;
      });
      _log(message, error: !result.physicalOpeningConfirmed);
    } on HikvisionException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = error.deviceResponded
            ? 'Device reached, command failed'
            : 'Not connected';
        _message = '${_service!.connectionAddress} — ${error.message}';
      });
      _log(error.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'Wonderla Gate Access',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      actions: [
        IconButton(
          onPressed: _showActivity,
          tooltip: 'Activity log',
          icon: const Icon(Icons.receipt_long_outlined),
        ),
        IconButton(
          onPressed: _busy ? null : _configure,
          tooltip: 'Device settings',
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF17357A).withValues(alpha: .08),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Image.asset(
                        'assets/wonderla_logo.webp',
                        height: 94,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'PARKS AND RESORTS',
                        style: TextStyle(
                          color: Colors.blueGrey.shade500,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Text(
                  'OPERATIONS',
                  style: TextStyle(
                    color: Colors.blueGrey.shade500,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.8,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Gate access',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF15264B),
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE7EAF1)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color:
                              (_status == 'Command accepted' ||
                                          _status == 'Connected'
                                      ? Colors.green
                                      : const Color(0xFF17357A))
                                  .withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Icon(
                          _status == 'Command accepted' ||
                                  _status == 'Connected'
                              ? Icons.check_circle_outline
                              : Icons.door_front_door_outlined,
                          color:
                              _status == 'Command accepted' ||
                                  _status == 'Connected'
                              ? Colors.green.shade700
                              : const Color(0xFF17357A),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _status,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            if (_message != null) ...[
                              const SizedBox(height: 5),
                              Text(
                                _message!,
                                style: TextStyle(
                                  color: Colors.blueGrey.shade600,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: _busy || !(_service?.canCheckConnection ?? false)
                      ? null
                      : _checkConnection,
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('CHECK CONNECTION'),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 58,
                  child: FilledButton.icon(
                    onPressed: _busy || !(_service?.isConfigured ?? false)
                        ? null
                        : _openGate,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.lock_open_rounded),
                    label: Text(
                      _busy ? 'CONNECTING…' : 'OPEN GATE',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        letterSpacing: .6,
                      ),
                    ),
                  ),
                ),
                if (!(_service?.isConfigured ?? false))
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      'Set up your Hikvision terminal to get started.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.blueGrey.shade600),
                    ),
                  ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _showActivity,
                  icon: const Icon(Icons.history),
                  label: Text('Activity log · ${_activity.length}'),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 16,
                      color: Colors.blueGrey.shade400,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Secure terminal control',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blueGrey.shade500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _ActivityDialog extends StatelessWidget {
  const _ActivityDialog({required this.entries});
  final List<_ActivityEntry> entries;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Expanded(child: Text('Activity log')),
        Icon(Icons.history, color: Theme.of(context).colorScheme.primary),
      ],
    ),
    content: SizedBox(
      width: 440,
      height: 360,
      child: entries.isEmpty
          ? const Center(
              child: Text('Gate and setup activity will appear here.'),
            )
          : ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final time =
                    '${entry.at.hour.toString().padLeft(2, '0')}:${entry.at.minute.toString().padLeft(2, '0')}:${entry.at.second.toString().padLeft(2, '0')}';
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    entry.error
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    color: entry.error
                        ? Colors.deepOrange
                        : const Color(0xFF17357A),
                  ),
                  title: Text(entry.message),
                  subtitle: Text(time),
                );
              },
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({this.initial});
  final GateSettings? initial;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _host = TextEditingController(text: widget.initial?.host ?? '');
  late final _port = TextEditingController(
    text: widget.initial?.port.toString() ?? '',
  );
  late final _door = TextEditingController(
    text: widget.initial?.doorId.toString() ?? '',
  );
  late final _username = TextEditingController(
    text: widget.initial?.username ?? '',
  );
  late final _password = TextEditingController(
    text: widget.initial?.password ?? '',
  );
  late bool _https = widget.initial?.useHttps ?? true;
  late bool _verified = widget.initial?.endpointVerified ?? false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _door.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;

  String? _validateHost(String? value) {
    final requiredError = _required(value);
    if (requiredError != null) return requiredError;
    final host = value!.trim();
    if (RegExp(r'[\s/@?#]').hasMatch(host)) {
      return 'Enter only an IP address or hostname';
    }
    try {
      Uri(scheme: 'http', host: host);
    } on FormatException {
      return 'Enter a valid IP address or hostname';
    }
    return null;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final port = int.parse(_port.text);
    final door = int.parse(_door.text);
    if (port < 1 || port > 65535 || door < 1) return;
    Navigator.pop(
      context,
      GateSettings(
        host: _host.text.trim(),
        port: port,
        useHttps: _https,
        doorId: door,
        username: _username.text.trim(),
        password: _password.text,
        endpointVerified: _verified,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect Hikvision terminal'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Enter the terminal details here in the app. These are not settings to change on the terminal dashboard.',
                ),
              ),
              TextFormField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'Terminal IP address',
                  hintText: 'Example: 10.10.10.196',
                ),
                validator: _validateHost,
                keyboardType: TextInputType.url,
              ),
              TextFormField(
                controller: _port,
                decoration: const InputDecoration(
                  labelText: 'Terminal web port',
                  hintText: 'Use the port configured on the terminal',
                ),
                validator: (value) {
                  final n = int.tryParse(value ?? '');
                  return n == null || n < 1 || n > 65535
                      ? 'Enter a port from 1 to 65535'
                      : null;
                },
                keyboardType: TextInputType.number,
              ),
              TextFormField(
                controller: _door,
                decoration: const InputDecoration(labelText: 'Door ID'),
                validator: (value) {
                  final n = int.tryParse(value ?? '');
                  return n == null || n < 1 ? 'Enter a valid door ID' : null;
                },
                keyboardType: TextInputType.number,
              ),
              DropdownButtonFormField<bool>(
                initialValue: _https,
                decoration: const InputDecoration(labelText: 'Protocol'),
                items: const [
                  DropdownMenuItem(value: true, child: Text('HTTPS')),
                  DropdownMenuItem(
                    value: false,
                    child: Text('HTTP (local network only)'),
                  ),
                ],
                onChanged: (value) => setState(() => _https = value ?? true),
              ),
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(
                  labelText: 'Terminal username',
                ),
                validator: _required,
              ),
              TextFormField(
                controller: _password,
                decoration: const InputDecoration(
                  labelText: 'Terminal password',
                ),
                obscureText: true,
                validator: _required,
              ),
              CheckboxListTile(
                value: _verified,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'I verified this firmware advertises the open command',
                ),
                onChanged: (value) =>
                    setState(() => _verified = value ?? false),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save settings')),
    ],
  );
}
