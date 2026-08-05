import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart' hide MessageType;

import '../db/repositories/message_repository.dart';
import '../models/message.dart';
import '../models/message_status.dart';
import '../models/message_type.dart' as app;
import 'vector_clock.dart';

/// Tipos de mensagens de controle do protocolo de sincronização.
const _kSyncRequest = 'SYNC_REQUEST';
const _kSyncResponse = 'SYNC_RESPONSE';
const _kSyncAck = 'SYNC_ACK';

/// Sincroniza mensagens pendentes com um peer ao reconectar (SPEC-SYNC-001).
///
/// Protocolo bidirecional:
///   B → A: SYNC_REQUEST  { vc: vectorClock }
///   A → B: SYNC_RESPONSE { messages: [...] }
///   B → A: SYNC_ACK      { ids: [...] }
///   (inverte papéis)
class SyncManager {
  final RTCDataChannel dataChannel;
  final MessageRepository messageRepo;
  final String channelId;
  final String localUserId;
  final VectorClock localClock;
  // Chamado após salvar mensagens recebidas via SYNC_RESPONSE, para que a UI atualize.
  final void Function()? onMessagesReceived;

  SyncManager({
    required this.dataChannel,
    required this.messageRepo,
    required this.channelId,
    required this.localUserId,
    required this.localClock,
    this.onMessagesReceived,
  });

  /// Inicia o handshake enviando o Vector Clock local ao peer.
  Future<void> startSync() async {
    _send({
      'type': _kSyncRequest,
      'channel_id': channelId,
      'vc': localClock.toMap(),
    });
  }

  /// Processa mensagens de controle de sync recebidas pelo DataChannel.
  Future<void> handleControlMessage(RTCDataChannelMessage raw) async {
    try {
      final json = jsonDecode(raw.text) as Map<String, dynamic>;
      final type = json['type'] as String?;

      switch (type) {
        case _kSyncRequest:
          await _handleSyncRequest(json);
        case _kSyncResponse:
          await _handleSyncResponse(json);
        case _kSyncAck:
          await _handleSyncAck(json);
      }
    } catch (_) {}
  }

  Future<void> _handleSyncRequest(Map<String, dynamic> json) async {
    final peerVc = Map<String, int>.from(json['vc'] as Map? ?? {});
    final delta = await messageRepo.getMessagesSince(channelId, peerVc);

    _send({
      'type': _kSyncResponse,
      'channel_id': channelId,
      'messages': delta.map(_messageToJson).toList(),
    });
  }

  Future<void> _handleSyncResponse(Map<String, dynamic> json) async {
    final msgs = (json['messages'] as List? ?? []).cast<Map<String, dynamic>>();
    final receivedIds = <String>[];

    for (final m in msgs) {
      final msg = _messageFromJson(m);
      if (!await messageRepo.exists(msg.id)) {
        await messageRepo.save(msg);
        receivedIds.add(msg.id);
      }
    }

    _send({'type': _kSyncAck, 'channel_id': channelId, 'ids': receivedIds});

    if (receivedIds.isNotEmpty) onMessagesReceived?.call();

    // Após receber delta do peer, envia as próprias mensagens pendentes
    await startSync();
  }

  Future<void> _handleSyncAck(Map<String, dynamic> json) async {
    final ids = (json['ids'] as List? ?? []).cast<String>();
    for (final id in ids) {
      await messageRepo.updateStatus(id, MessageStatus.delivered);
    }
  }

  void _send(Map<String, dynamic> payload) {
    dataChannel.send(RTCDataChannelMessage(jsonEncode(payload)));
  }

  Map<String, dynamic> _messageToJson(Message m) => {
        'id': m.id,
        'channel_id': m.channelId,
        'sender_id': m.senderId,
        'type': m.type.name,
        'payload': base64Encode(m.payload),
        'timestamp': m.timestamp.millisecondsSinceEpoch,
        'vector_clock': m.vectorClock,
        'signature': base64Encode(m.signature),
        'status': m.status.name,
      };

  Message _messageFromJson(Map<String, dynamic> m) => Message(
        id: m['id'] as String,
        channelId: m['channel_id'] as String,
        senderId: m['sender_id'] as String,
        type: _msgType(m['type'] as String? ?? 'text'),
        payload: base64Decode(m['payload'] as String),
        timestamp: DateTime.fromMillisecondsSinceEpoch(m['timestamp'] as int),
        vectorClock: Map<String, int>.from(m['vector_clock'] as Map? ?? {}),
        signature: base64Decode(m['signature'] as String? ?? ''),
        status: MessageStatus.delivered,
      );

  static app.MessageType _msgType(String s) => switch (s) {
        'image' => app.MessageType.image,
        'audio' => app.MessageType.audio,
        'video' => app.MessageType.video,
        'file' => app.MessageType.file,
        _ => app.MessageType.text,
      };
}
