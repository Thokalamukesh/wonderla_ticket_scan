import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ticket_scan/hikvision_service.dart';

const capabilities =
    '<RemoteControlDoor xmlns="http://www.isapi.org/ver20/XMLSchema"><cmd opt="open,close"/></RemoteControlDoor>';
const success =
    '<ResponseStatus xmlns="http://www.hikvision.com/ver20/XMLSchema"><statusCode>1</statusCode><statusString>OK</statusString><subStatusCode>ok</subStatusCode></ResponseStatus>';

Future<(HttpServer, HikvisionService)> setup(
  Future<void> Function(HttpRequest) handler, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return (
    server,
    HikvisionService(
      host: '127.0.0.1',
      port: server.port,
      useHttps: false,
      requestTimeout: timeout,
      doorId: 1,
      username: 'operator',
      password: 'secret',
      endpointVerified: true,
    ),
  );
}

void main() {
  test('connection check reports the target and open capability', () async {
    final (server, service) = await setup((request) async {
      expect(request.method, 'GET');
      expect(request.uri.path, contains('/capabilities'));
      request.response.write(capabilities);
      await request.response.close();
    });
    final messages = <String>[];
    service.onProgress = messages.add;

    final result = await service.checkConnection();

    expect(result.address, startsWith('http://127.0.0.1:'));
    expect(result.httpStatus, HttpStatus.ok);
    expect(result.openSupported, isTrue);
    expect(messages.first, contains('CONNECTION CHECK START'));
    expect(messages.last, contains('CONNECTED'));
    expect(messages.last, contains('Open command: SUPPORTED'));
    await server.close(force: true);
  });

  test('checks advertised capability and parses accepted response', () async {
    var puts = 0;
    final (server, service) = await setup((request) async {
      if (request.method == 'GET') {
        request.response.write(capabilities);
      } else {
        puts++;
        expect(
          await request
              .cast<List<int>>()
              .transform(const SystemEncoding().decoder)
              .join(),
          contains('<cmd>open</cmd>'),
        );
        request.response.write(success);
      }
      await request.response.close();
    });
    final result = await service.openDoor();
    expect(result.physicalOpeningConfirmed, isFalse);
    expect(puts, 1);
    await server.close(force: true);
  });

  test('does not PUT when firmware does not advertise open', () async {
    var puts = 0;
    final (server, service) = await setup((request) async {
      if (request.method == 'PUT') puts++;
      request.response.write(
        '<RemoteControlDoor><cmd opt="close"/></RemoteControlDoor>',
      );
      await request.response.close();
    });
    await expectLater(service.openDoor(), throwsA(isA<HikvisionException>()));
    expect(puts, 0);
    await server.close(force: true);
  });

  test('reports authentication failure', () async {
    final (server, service) = await setup((request) async {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
    });
    await expectLater(service.openDoor(), throwsA(isA<HikvisionException>()));
    await server.close(force: true);
  });

  test('reports malformed XML', () async {
    final (server, service) = await setup((request) async {
      request.response.write('not xml');
      await request.response.close();
    });
    await expectLater(service.openDoor(), throwsA(isA<HikvisionException>()));
    await server.close(force: true);
  });

  test('does not permit an unverified endpoint', () async {
    final service = HikvisionService(
      host: 'device',
      port: 80,
      useHttps: false,
      doorId: 1,
      username: 'operator',
      password: 'secret',
      endpointVerified: false,
    );
    await expectLater(service.openDoor(), throwsA(isA<HikvisionException>()));
  });

  test('reports timeout without retrying the open command', () async {
    var puts = 0;
    final (server, service) = await setup((request) async {
      if (request.method == 'PUT') puts++;
      if (request.method == 'PUT') {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      try {
        request.response.write(
          request.method == 'GET' ? capabilities : success,
        );
        await request.response.close();
      } on HttpException {
        // The client timed out and closed this connection.
      }
    }, timeout: const Duration(milliseconds: 20));
    await expectLater(service.openDoor(), throwsA(isA<HikvisionException>()));
    expect(puts, 1);
    await server.close(force: true);
  });
}
