import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

enum SignalingMessageType {
  offer,
  answer,
  iceCandidate,
  join,
  leave,
  peerJoined,
  peerLeft,
  roomPeers,
  unknown,
}

class SignalingMessage {
  final SignalingMessageType type;
  final String room;
  final String from;
  final String? to;
  final Map<String, dynamic> data;

  const SignalingMessage({
    required this.type,
    required this.room,
    required this.from,
    this.to,
    required this.data,
  });

  factory SignalingMessage.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? '';
    final type = switch (typeStr) {
      'offer' => SignalingMessageType.offer,
      'answer' => SignalingMessageType.answer,
      'ice-candidate' => SignalingMessageType.iceCandidate,
      'join' => SignalingMessageType.join,
      'leave' => SignalingMessageType.leave,
      'peer_joined' => SignalingMessageType.peerJoined,
      'peer_left' => SignalingMessageType.peerLeft,
      'room_peers' => SignalingMessageType.roomPeers,
      _ => SignalingMessageType.unknown,
    };
    return SignalingMessage(
      type: type,
      room: json['room'] as String? ?? '',
      from: json['from'] as String? ?? '',
      to: json['to'] as String?,
      data: Map<String, dynamic>.from(json['data'] as Map? ?? {}),
    );
  }
}

/// Cliente WebSocket para sinalização WebRTC.
/// Conecta ao servidor Go via WSS com JWT anônimo (SPEC-SIG-001, SPEC-SIG-002).
class SignalingClient {
  final String serverUrl;
  final String jwtToken;

  WebSocketChannel? _channel;
  StreamController<SignalingMessage>? _controller;

  SignalingClient({required this.serverUrl, required this.jwtToken});

  Stream<SignalingMessage> get messages => _controller!.stream;

  Future<void> connect() async {
    _controller = StreamController<SignalingMessage>.broadcast();
    final uri = Uri.parse('$serverUrl/ws?token=$jwtToken');
    _channel = WebSocketChannel.connect(uri);

    _channel!.stream.listen(
      (data) {
        try {
          final json = jsonDecode(data as String) as Map<String, dynamic>;
          _controller!.add(SignalingMessage.fromJson(json));
        } catch (_) {}
      },
      onDone: () => _controller!.close(),
      onError: (e) => _controller!.addError(e),
    );

    await _channel!.ready;
  }

  /// Envia uma mensagem de sinalização. Use [to] para roteamento direto peer-a-peer.
  void send(String type, String room, String from, Map<String, dynamic> data, {String? to}) {
    final msg = <String, dynamic>{'type': type, 'room': room, 'from': from, 'data': data};
    if (to != null) msg['to'] = to;
    _channel?.sink.add(jsonEncode(msg));
  }

  void join(String room, String pubKey) => send('join', room, pubKey, {});
  void leave(String room, String pubKey) => send('leave', room, pubKey, {});

  Future<void> close() async {
    await _channel?.sink.close();
    await _controller?.close();
  }
}
