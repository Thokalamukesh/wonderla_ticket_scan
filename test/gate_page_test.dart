import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticket_scan/hikvision_service.dart';
import 'package:ticket_scan/main.dart';

class _SlowService extends HikvisionService {
  _SlowService()
    : super(
        host: 'terminal',
        port: 80,
        useHttps: false,
        doorId: 1,
        username: 'operator',
        password: 'secret',
        endpointVerified: true,
      );
  int calls = 0;
  final Completer<GateCommandResult> result = Completer<GateCommandResult>();

  @override
  Future<GateCommandResult> openDoor() {
    calls++;
    return result.future;
  }
}

class _ConnectionService extends _SlowService {
  @override
  Future<ConnectionCheckResult> checkConnection() async {
    onProgress?.call(
      'CONNECTED | Target: $connectionAddress | HTTP 200 | Login accepted | Open command: SUPPORTED',
    );
    return ConnectionCheckResult(
      address: connectionAddress,
      httpStatus: 200,
      openSupported: true,
    );
  }
}

void main() {
  testWidgets('shows the terminal address and connection result', (
    tester,
  ) async {
    final service = _ConnectionService();
    await tester.pumpWidget(MaterialApp(home: GatePage(service: service)));

    await tester.tap(find.text('CHECK CONNECTION'));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.textContaining('http://terminal:80'), findsOneWidget);
    final activityButton = find.textContaining('Activity log');
    await tester.ensureVisible(activityButton);
    await tester.pumpAndSettle();
    await tester.tap(activityButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('Open command: SUPPORTED'), findsOneWidget);
  });

  testWidgets('disables repeated taps while a command is in progress', (
    tester,
  ) async {
    final service = _SlowService();
    await tester.pumpWidget(MaterialApp(home: GatePage(service: service)));
    await tester.tap(find.text('OPEN GATE'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open gate'));
    await tester.pump();
    expect(service.calls, 1);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'CONNECTING…'),
          )
          .onPressed,
      isNull,
    );
    service.result.complete(
      const GateCommandResult(physicalOpeningConfirmed: false),
    );
    await tester.pumpAndSettle();
  });
}
