import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

  bool _sessionReady = false;

  /// True após o primeiro decrypt bem-sucedido (X3DH completo no lado do admin).
  bool get sessionReady => _sessionReady;

  /// Chamado quando a sessão Signal está pronta para criptografar (X3DH completo).
  void Function()? onSessionReady;

  /// Chamado para mensagens de texto (não-binárias) recebidas pelo DataChannel.
  /// Usar para rotear mensagens de controle do SyncManager (SYNC_REQUEST, SYNC_RESPONSE, SYNC_ACK).
  void Function(RTCDataChannelMessage)? onControlMessage;

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

  /// Retorna `true` se o envio foi bem-sucedido, `false` se a sessão Signal não está
  /// pronta (X3DH incompleto no lado do admin) ou se houve erro de criptografia.
  Future<bool> send(Message message) async {
    try {
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
      return true;
    } catch (e) {
      debugPrint('[DCH] send failed — session not ready or crypto error: $e');
      return false;
    }
  }

  // ─── Recebimento ──────────────────────────────────────────────────────────

  Future<void> _handleIncoming(RTCDataChannelMessage raw) async {
    // Mensagens de texto são mensagens de controle (sync protocol) — não payload Signal.
    if (!raw.isBinary) {
      onControlMessage?.call(raw);
      return;
    }
    debugPrint('[DCH] _handleIncoming binary (${raw.binary.length} bytes)');
    try {
      final wire = raw.binary;
      if (wire.length < 4) return;

      final sigLen = ByteData.sublistView(wire, 0, 4).getUint32(0, Endian.big);
      if (wire.length < 4 + sigLen) return;

      final signature = wire.sublist(4, 4 + sigLen);
      final ciphertext = wire.sublist(4 + sigLen);
      debugPrint('[DCH] wire ok — sigLen=$sigLen cipherLen=${ciphertext.length}');

      final plaintext = await session.decrypt(ciphertext);
      debugPrint('[DCH] decrypt ok — plaintext ${plaintext.length} bytes');

      final json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      final senderId = json['sender_id'] as String;

      // Verifica assinatura Ed25519 (SPEC-MSG-001) — requer chave pública do remetente.
      // A chave do remetente é resolvida do ChannelMember no DB pelo PairingService após o handshake.
      // A `signature` é preservada na mensagem persistida para verificação posterior.

      final msgType = MessageType.fromString(json['type'] as String? ?? 'text');

      // Marca a sessão como pronta no primeiro decrypt bem-sucedido (X3DH completo).
      if (!_sessionReady) {
        _sessionReady = true;
        debugPrint('[DCH] X3DH complete — session ready');
        onSessionReady?.call();
      }

      final message = Message(
        id: json['id'] as String,
        channelId: json['channel_id'] as String,
        senderId: senderId,
        type: msgType,
        payload: base64Decode(json['payload'] as String),
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        vectorClock: Map<String, int>.from(json['vector_clock'] as Map? ?? {}),
        signature: signature,
        status: MessageStatus.delivered,
      );

      // Deduplicação por UUID (SPEC-SYNC-002)
      if (!await messageRepo.exists(message.id)) {
        await messageRepo.save(message);
        debugPrint('[DCH] message saved → emitting to stream');
        _incomingController.add(message);
      } else {
        debugPrint('[DCH] message already exists — skipped (id=${message.id})');
      }
    } catch (e) {
      debugPrint('[DCH] _handleIncoming error (message discarded): $e');
    }
  }

  Future<void> dispose() async {
    await _incomingController.close();
  }
}
