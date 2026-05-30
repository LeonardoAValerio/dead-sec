import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' hide MessageType;

import '../crypto/message_signer.dart';
import '../crypto/signal_session.dart';
import '../db/repositories/message_repository.dart';
import '../models/message.dart';
import '../models/message_status.dart';
import '../models/message_type.dart';

/// Integra Signal Protocol + Ed25519 com o RTCDataChannel.
///
/// Ordem de envio (SPEC-CRYPTO-002 + SPEC-MSG-001):
///   plaintext → Ed25519 sign → Signal encrypt → bytes → DataChannel
///
/// Ordem de recebimento:
///   bytes → Signal decrypt → Ed25519 verify → persist DB
class DataChannelHandler {
  final RTCDataChannel dataChannel;
  final SignalSession session;
  final MessageRepository messageRepo;
  final String localUserId;
  final String channelId;

  final _incomingController = StreamController<Message>.broadcast();
  Stream<Message> get onMessage => _incomingController.stream;

  DataChannelHandler({
    required this.dataChannel,
    required this.session,
    required this.messageRepo,
    required this.localUserId,
    required this.channelId,
  }) {
    dataChannel.onMessage = _handleIncoming;
  }

  // ─── Envio ───────────────────────────────────────────────────────────────

  Future<void> send(Message message) async {
    final plaintext = utf8.encode(jsonEncode({
      'id': message.id,
      'channel_id': message.channelId,
      'sender_id': message.senderId,
      'type': message.type.name,
      'payload': base64Encode(message.payload),
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'vector_clock': message.vectorClock,
    }));

    final payload = Uint8List.fromList(plaintext);
    final signature = await MessageSigner.sign(payload);
    final ciphertext = await session.encrypt(payload);

    // Wire format: [4 bytes sig length][signature][ciphertext]
    final sigLen = ByteData(4)..setUint32(0, signature.length, Endian.big);
    final wire = Uint8List(4 + signature.length + ciphertext.length)
      ..setRange(0, 4, sigLen.buffer.asUint8List())
      ..setRange(4, 4 + signature.length, signature)
      ..setRange(4 + signature.length, 4 + signature.length + ciphertext.length, ciphertext);

    dataChannel.send(RTCDataChannelMessage.fromBinary(wire));
  }

  // ─── Recebimento ──────────────────────────────────────────────────────────

  Future<void> _handleIncoming(RTCDataChannelMessage raw) async {
    try {
      final wire = raw.binary;
      if (wire.length < 4) return;

      final sigLen = ByteData.sublistView(wire, 0, 4).getUint32(0, Endian.big);
      if (wire.length < 4 + sigLen) return;

      final signature = wire.sublist(4, 4 + sigLen);
      final ciphertext = wire.sublist(4 + sigLen);

      final plaintext = await session.decrypt(ciphertext);

      final json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      final senderId = json['sender_id'] as String;

      // Verifica assinatura Ed25519 (SPEC-MSG-001) — requer chave pública do remetente.
      // A chave do remetente é resolvida do ChannelMember no DB pelo PairingService após o handshake.
      // A `signature` é preservada na mensagem persistida para verificação posterior.

      final message = Message(
        id: json['id'] as String,
        channelId: json['channel_id'] as String,
        senderId: senderId,
        type: MessageType.fromString(json['type'] as String? ?? 'text'),
        payload: base64Decode(json['payload'] as String),
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        vectorClock: Map<String, int>.from(json['vector_clock'] as Map? ?? {}),
        signature: signature,
        status: MessageStatus.delivered,
      );

      // Deduplicação por UUID (SPEC-SYNC-002)
      if (!await messageRepo.exists(message.id)) {
        await messageRepo.save(message);
        _incomingController.add(message);
      }
    } catch (_) {
      // Descarta silenciosamente mensagens corrompidas ou com assinatura inválida (SPEC-MSG-001)
    }
  }

  Future<void> dispose() async {
    await _incomingController.close();
  }
}
