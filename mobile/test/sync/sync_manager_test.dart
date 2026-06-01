import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' hide MessageType;
import 'package:safechannel/sync/sync_manager.dart';
import 'package:safechannel/sync/vector_clock.dart';
import 'package:safechannel/db/repositories/message_repository.dart';
import 'package:safechannel/models/message.dart';
import 'package:safechannel/models/message_status.dart';
import 'package:safechannel/models/message_type.dart';
import 'package:safechannel/db/database.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// RTCDataChannel falso que captura mensagens enviadas para validação.
class FakeDataChannel extends RTCDataChannel {
  final List<RTCDataChannelMessage> sent = [];
  final _controller = StreamController<RTCDataChannelMessage>.broadcast();

  // ─── Membros abstratos obrigatórios ──────────────────────────────────
  @override
  int get id => 0;
  @override
  String get label => 'fake';
  @override
  int get bufferedAmount => 0;
  @override
  RTCDataChannelState get state => RTCDataChannelState.RTCDataChannelOpen;

  // ─── Comportamento fake ───────────────────────────────────────────────
  @override
  Future<void> send(RTCDataChannelMessage message) async => sent.add(message);

  void receive(String json) => _controller.add(RTCDataChannelMessage(json));

  @override
  set onMessage(dynamic Function(RTCDataChannelMessage)? cb) {
    if (cb != null) _controller.stream.listen(cb);
  }

  @override
  Future<void> close() async => _controller.close();
}

void main() {
  late FakeDataChannel channel;
  late MessageRepository repo;
  late SyncManager syncManager;
  late Database db;

  setUp(() async {
    db = await openTestDatabase();
    // Inserir canal para satisfazer FK constraint de messages.channel_id
    await db.insert('channels', {
      'id': 'ch-1',
      'name': 'Test',
      'channel_key': Uint8List(32),
      'invite_secret_hash': '',
      'created_by': 'alice',
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'max_members': 50,
      'allow_media': 1,
    });
    repo = MessageRepository(db);
    channel = FakeDataChannel();
    syncManager = SyncManager(
      dataChannel: channel,
      messageRepo: repo,
      channelId: 'ch-1',
      localUserId: 'alice',
      localClock: VectorClock({'alice': 2}),
    );
  });

  tearDown(() async => db.close());

  test('startSync envia SYNC_REQUEST com vector clock local', () async {
    await syncManager.startSync();

    expect(channel.sent, hasLength(1));
    final json = jsonDecode(channel.sent.first.text) as Map<String, dynamic>;
    expect(json['type'], equals('SYNC_REQUEST'));
    expect(json['vc'], equals({'alice': 2}));
  });

  test('handleControlMessage(SYNC_REQUEST) envia SYNC_RESPONSE', () async {
    // Salva uma mensagem local que será incluída no delta
    await repo.save(Message(
      id: 'msg-1',
      channelId: 'ch-1',
      senderId: 'alice',
      type: MessageType.text,
      payload: Uint8List.fromList('olá'.codeUnits),
      timestamp: DateTime.now(),
      vectorClock: {'alice': 1},
      signature: Uint8List(0),
      status: MessageStatus.sent,
    ));

    // Simula peer enviando SYNC_REQUEST com clock vazio (não conhece nenhuma msg)
    await syncManager.handleControlMessage(
      RTCDataChannelMessage(jsonEncode({
        'type': 'SYNC_REQUEST',
        'channel_id': 'ch-1',
        'vc': {},
      })),
    );

    expect(channel.sent, hasLength(1));
    final json = jsonDecode(channel.sent.first.text) as Map<String, dynamic>;
    expect(json['type'], equals('SYNC_RESPONSE'));
    final messages = json['messages'] as List;
    expect(messages, hasLength(1));
    expect(messages.first['id'], equals('msg-1'));
  });

  test('handleControlMessage(SYNC_RESPONSE) persiste mensagens novas e envia ACK', () async {
    final remoteMsg = {
      'id': 'msg-remote-1',
      'channel_id': 'ch-1',
      'sender_id': 'bob',
      'type': 'text',
      'payload': base64Encode(Uint8List.fromList('oi'.codeUnits)),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'vector_clock': {'bob': 1},
      'signature': base64Encode(Uint8List(0)),
      'status': 'delivered',
    };

    await syncManager.handleControlMessage(
      RTCDataChannelMessage(jsonEncode({
        'type': 'SYNC_RESPONSE',
        'channel_id': 'ch-1',
        'messages': [remoteMsg],
      })),
    );

    // Mensagem deve ter sido persistida
    expect(await repo.exists('msg-remote-1'), isTrue);

    // Deve ter enviado SYNC_ACK + SYNC_REQUEST (reverse sync)
    expect(channel.sent.length, greaterThanOrEqualTo(1));
    final ack = jsonDecode(channel.sent.first.text) as Map<String, dynamic>;
    expect(ack['type'], equals('SYNC_ACK'));
    expect((ack['ids'] as List).contains('msg-remote-1'), isTrue);
  });
}
