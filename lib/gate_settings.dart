import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'hikvision_service.dart';

class GateSettings {
  const GateSettings({
    required this.host,
    required this.port,
    required this.useHttps,
    required this.doorId,
    required this.username,
    required this.password,
    required this.endpointVerified,
  });

  final String host, username, password;
  final int port, doorId;
  final bool useHttps, endpointVerified;

  HikvisionService createService() => HikvisionService(
    host: host,
    port: port,
    useHttps: useHttps,
    doorId: doorId,
    username: username,
    password: password,
    endpointVerified: endpointVerified,
  );

  Map<String, Object> toJson() => {
    'host': host,
    'port': port,
    'https': useHttps,
    'doorId': doorId,
    'username': username,
    'password': password,
    'endpointVerified': endpointVerified,
  };

  factory GateSettings.fromJson(Map<String, dynamic> json) => GateSettings(
    host: json['host'] as String,
    port: json['port'] as int,
    useHttps: json['https'] as bool,
    doorId: json['doorId'] as int,
    username: json['username'] as String,
    password: json['password'] as String,
    endpointVerified: json['endpointVerified'] as bool,
  );
}

class GateSettingsStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'hikvision_gate_settings';

  Future<GateSettings?> load() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    try {
      return GateSettings.fromJson(jsonDecode(value) as Map<String, dynamic>);
    } on Object {
      await _storage.delete(key: _key);
      return null;
    }
  }

  Future<void> save(GateSettings settings) =>
      _storage.write(key: _key, value: jsonEncode(settings.toJson()));
}

class GateActivityStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'hikvision_gate_activity';
  static const maxEntries = 200;

  Future<List<Map<String, dynamic>>> load() async {
    final value = await _storage.read(key: _key);
    if (value == null) return const [];
    try {
      final entries = jsonDecode(value) as List<dynamic>;
      return entries
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();
    } on Object {
      await _storage.delete(key: _key);
      return const [];
    }
  }

  Future<void> save(List<Map<String, dynamic>> entries) => _storage.write(
    key: _key,
    value: jsonEncode(entries.take(maxEntries).toList()),
  );
}
