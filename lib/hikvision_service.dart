import 'dart:async';
import 'dart:io';

import 'package:xml/xml.dart';

class HikvisionException implements Exception {
  const HikvisionException(this.message, {this.deviceResponded = false});
  final String message;
  final bool deviceResponded;
  @override
  String toString() => message;
}

class GateCommandResult {
  const GateCommandResult({required this.physicalOpeningConfirmed});
  final bool physicalOpeningConfirmed;
}

class ConnectionCheckResult {
  const ConnectionCheckResult({
    required this.address,
    required this.httpStatus,
    required this.openSupported,
  });

  final String address;
  final int httpStatus;
  final bool openSupported;
}

class HikvisionService {
  HikvisionService({
    required this.host,
    required this.port,
    required this.useHttps,
    required this.doorId,
    required this.username,
    required this.password,
    required this.endpointVerified,
    HttpClient? client,
    this.requestTimeout = const Duration(seconds: 8),
    this.onProgress,
  }) : _client = client ?? HttpClient();

  factory HikvisionService.fromEnvironment() => HikvisionService(
    host: const String.fromEnvironment('HIKVISION_HOST'),
    port: const int.fromEnvironment('HIKVISION_PORT', defaultValue: 0),
    useHttps: const bool.fromEnvironment('HIKVISION_HTTPS'),
    doorId: const int.fromEnvironment('HIKVISION_DOOR_ID', defaultValue: 0),
    username: const String.fromEnvironment('HIKVISION_USERNAME'),
    password: const String.fromEnvironment('HIKVISION_PASSWORD'),
    endpointVerified: const bool.fromEnvironment(
      'HIKVISION_REMOTE_CONTROL_VERIFIED',
    ),
  );

  final String host, username, password;
  final int port, doorId;
  final bool useHttps, endpointVerified;
  final Duration requestTimeout;
  void Function(String message)? onProgress;
  HttpClient? _client;
  String get connectionAddress =>
      '${useHttps ? 'https' : 'http'}://$host:$port';
  bool get canCheckConnection =>
      host.isNotEmpty &&
      port > 0 &&
      port <= 65535 &&
      doorId > 0 &&
      username.isNotEmpty &&
      password.isNotEmpty;
  bool get isConfigured => canCheckConnection && endpointVerified;

  Future<ConnectionCheckResult> checkConnection() async {
    if (!canCheckConnection) {
      throw const HikvisionException(
        'Terminal settings are incomplete. Enter the IP/host, port, door ID, username, and password first.',
      );
    }
    var deviceResponded = false;
    onProgress?.call(
      'CONNECTION CHECK START | Target: $connectionAddress | Door ID: $doorId',
    );
    try {
      _configureClient();
      final path = '/ISAPI/AccessControl/RemoteControl/door/$doorId';
      final reply = await _request(
        Uri(
          scheme: useHttps ? 'https' : 'http',
          host: host,
          port: port,
        ).replace(path: '$path/capabilities'),
        'GET',
      ).timeout(requestTimeout);
      deviceResponded = true;
      onProgress?.call(
        'DEVICE RESPONDED | Target: $connectionAddress | HTTP ${reply.statusCode} | Checking login and door capability',
      );
      _checkHttp(reply.statusCode, 'capability check');
      final xml = _parse(reply.body);
      final command = xml.findAllElements('cmd').firstOrNull;
      final supported =
          command
              ?.getAttribute('opt')
              ?.split(',')
              .map((v) => v.trim())
              .contains('open') ??
          command?.innerText.toLowerCase().contains('open') ??
          false;
      onProgress?.call(
        'CONNECTED | Target: $connectionAddress | HTTP ${reply.statusCode} | Login accepted | Open command: ${supported ? 'SUPPORTED' : 'NOT ADVERTISED'}',
      );
      return ConnectionCheckResult(
        address: connectionAddress,
        httpStatus: reply.statusCode,
        openSupported: supported,
      );
    } on HikvisionException catch (error) {
      onProgress?.call(
        '${deviceResponded || error.deviceResponded ? 'DEVICE REACHED, CHECK FAILED' : 'NOT CONNECTED'} | Target: $connectionAddress | ${error.message}',
      );
      throw HikvisionException(
        error.message,
        deviceResponded: deviceResponded || error.deviceResponded,
      );
    } on TimeoutException {
      const message =
          'Connection check timed out. Check the IP, port, network, and device power.';
      onProgress?.call('NOT CONNECTED | Target: $connectionAddress | $message');
      throw const HikvisionException(message);
    } on SocketException catch (error) {
      final refused = error.message.toLowerCase().contains('refused');
      final message = refused
          ? 'Connection refused at this address. The device was not reached and credentials were not checked. Verify the terminal IP, configured web port, HTTP/HTTPS selection, and that its web/ISAPI service is enabled. Network detail: ${error.message}'
          : 'Cannot reach terminal. Check the IP, port, network, and power. Network detail: ${error.message}';
      onProgress?.call('NOT CONNECTED | Target: $connectionAddress | $message');
      throw HikvisionException(message);
    } on HandshakeException catch (error) {
      const message =
          'HTTPS certificate validation failed. Install a valid device certificate; certificate checks are not disabled.';
      onProgress?.call(
        'NOT CONNECTED | Target: $connectionAddress | $message | ${error.message}',
      );
      throw const HikvisionException(message);
    } on HttpException catch (error) {
      final message = 'HTTP communication failed: ${error.message}';
      onProgress?.call(
        '${deviceResponded ? 'DEVICE REACHED, CHECK FAILED' : 'NOT CONNECTED'} | Target: $connectionAddress | $message',
      );
      throw HikvisionException(message, deviceResponded: deviceResponded);
    } on FormatException catch (error) {
      final message = 'Invalid terminal IP/host: ${error.message}';
      onProgress?.call('NOT CONNECTED | Target: $connectionAddress | $message');
      throw HikvisionException(message);
    } finally {
      _closeClient();
    }
  }

  Future<GateCommandResult> openDoor() async {
    if (!isConfigured) {
      throw const HikvisionException(
        'Device settings are incomplete or firmware endpoint support has not been verified.',
      );
    }
    try {
      final base = Uri(
        scheme: useHttps ? 'https' : 'http',
        host: host,
        port: port,
      );
      _configureClient();
      final path = '/ISAPI/AccessControl/RemoteControl/door/$doorId';
      onProgress?.call(
        'GATE COMMAND START | Target: $connectionAddress | Door ID: $doorId',
      );
      final caps = await _request(
        base.replace(path: '$path/capabilities'),
        'GET',
      ).timeout(requestTimeout);
      _checkHttp(caps.statusCode, 'capability check');
      final capabilityXml = _parse(caps.body);
      final command = capabilityXml.findAllElements('cmd').firstOrNull;
      final supported =
          command
              ?.getAttribute('opt')
              ?.split(',')
              .map((v) => v.trim())
              .contains('open') ??
          command?.innerText.toLowerCase().contains('open') ??
          false;
      if (!supported) {
        throw const HikvisionException(
          'This door/firmware does not advertise the open command. No command was sent.',
          deviceResponded: true,
        );
      }

      onProgress?.call(
        'DEVICE CONNECTED | Target: $connectionAddress | Open command supported | Sending command to door $doorId',
      );
      final response = await _request(
        base.replace(path: path),
        'PUT',
        body: '<RemoteControlDoor version="2.0" xmlns="http://www.isapi.org/ver20/XMLSchema"><cmd>open</cmd></RemoteControlDoor>',
      ).timeout(requestTimeout);
      _checkHttp(response.statusCode, 'door command');
      final xml = _parse(response.body);
      final statusCode = xml
          .findAllElements('statusCode')
          .firstOrNull
          ?.innerText
          .trim();
      final subStatus = xml
          .findAllElements('subStatusCode')
          .firstOrNull
          ?.innerText
          .trim()
          .toLowerCase();
      if (statusCode != '1' || (subStatus != null && subStatus != 'ok')) {
        throw HikvisionException(
          'Device rejected the command: ${xml.findAllElements('statusString').firstOrNull?.innerText ?? 'unexpected ISAPI status'} (${subStatus ?? statusCode ?? 'unknown status'}).',
          deviceResponded: true,
        );
      }
      onProgress?.call(
        'COMMAND ACCEPTED | Target: $connectionAddress | Physical gate movement is not confirmed',
      );
      return const GateCommandResult(physicalOpeningConfirmed: false);
    } on TimeoutException {
      onProgress?.call(
        'COMMAND RESULT UNKNOWN | Target: $connectionAddress | Request timed out; command was not retried',
      );
      throw const HikvisionException(
        'Request timed out. The command may have reached the device; it was not resent. Check gate status before trying again.',
      );
    } on SocketException catch (error) {
      final refused = error.message.toLowerCase().contains('refused');
      final message = refused
          ? 'Connection refused at this address. Verify the terminal IP, configured web port, HTTP/HTTPS selection, and that its web/ISAPI service is enabled.'
          : 'Cannot reach the device. Check its IP, port, network, and power.';
      onProgress?.call(
        'NOT CONNECTED | Target: $connectionAddress | $message | Network detail: ${error.message}',
      );
      throw HikvisionException(message);
    } on HandshakeException {
      onProgress?.call('HTTPS certificate validation failed');
      throw const HikvisionException(
        'HTTPS certificate validation failed. Install a valid device certificate; certificate checks are not disabled.',
      );
    } on HttpException catch (error) {
      onProgress?.call('HTTP communication failed: ${error.message}');
      throw HikvisionException('HTTP communication failed: ${error.message}');
    } finally {
      _closeClient();
    }
  }

  void _configureClient() {
    final client = _client ??= HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    client.idleTimeout = const Duration(seconds: 5);
    client.authenticate = (uri, scheme, realm) async {
      if (scheme.toLowerCase() != 'digest' || realm == null) return false;
      client.addCredentials(
        uri,
        realm,
        HttpClientDigestCredentials(username, password),
      );
      return true;
    };
  }

  void _closeClient() {
    _client?.close(force: true);
    _client = null;
  }

  Future<_Reply> _request(Uri uri, String method, {String? body}) async {
    final request = await _client!
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 5));
    request.headers.set(HttpHeaders.acceptHeader, 'application/xml');
    if (body != null) {
      request.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      request.write(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 5));
    return _Reply(
      response.statusCode,
      await response
          .transform(const SystemEncoding().decoder)
          .join()
          .timeout(const Duration(seconds: 5)),
    );
  }

  XmlDocument _parse(String body) {
    try {
      final doc = XmlDocument.parse(body);
      if (doc.rootElement.localName != 'ResponseStatus' &&
          doc.rootElement.localName != 'RemoteControlDoor') {
        throw const HikvisionException(
          'Unexpected XML response from device.',
          deviceResponded: true,
        );
      }
      return doc;
    } on XmlException {
      throw const HikvisionException(
        'Device returned malformed XML.',
        deviceResponded: true,
      );
    }
  }

  void _checkHttp(int status, String operation) {
    if (status == 401 || status == 403) {
      throw const HikvisionException(
        'Authentication failed or this account lacks door-control permission.',
        deviceResponded: true,
      );
    }
    if (status == 404 || status == 405) {
      throw HikvisionException(
        'Device does not support the ISAPI $operation endpoint (HTTP $status).',
        deviceResponded: true,
      );
    }
    if (status < 200 || status >= 300) {
      throw HikvisionException(
        'ISAPI $operation failed with HTTP $status.',
        deviceResponded: true,
      );
    }
  }
}

class _Reply {
  const _Reply(this.statusCode, this.body);
  final int statusCode;
  final String body;
}
