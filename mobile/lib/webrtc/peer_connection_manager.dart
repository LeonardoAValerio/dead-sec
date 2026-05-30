import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling_client.dart';
import 'turn_credentials_service.dart';

enum ConnectionIndicator { p2pDirect, turnRelay, offline }

/// Gerencia o ciclo de vida de uma conexão WebRTC P2P.
///
/// - DataChannel em modo reliable+ordered para mensagens e chunks.
/// - Indicador visual derivado do tipo de candidato ICE selecionado (SPEC-UI-001).
/// - Credenciais TURN buscadas do backend antes de cada conexão (SPEC-TURN-002).
class PeerConnectionManager {
  final SignalingClient signalingClient;
  final TurnCredentialsService turnService;
  final String roomId;
  final String localPubKey;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dataChannel;

  final _messageController = StreamController<RTCDataChannelMessage>.broadcast();
  final _indicatorController = StreamController<ConnectionIndicator>.broadcast();

  Stream<RTCDataChannelMessage> get onMessage => _messageController.stream;
  Stream<ConnectionIndicator> get onIndicator => _indicatorController.stream;

  bool get isConnected => _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  PeerConnectionManager({
    required this.signalingClient,
    required this.turnService,
    required this.roomId,
    required this.localPubKey,
  });

  // ─── Iniciar chamada (peer que cria a oferta) ──────────────────────────

  Future<void> startAsOfferer() async {
    await _createPeerConnection();
    _dataChannel = await _pc!.createDataChannel(
      'safechannel',
      RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = -1,
    );
    _setupDataChannel(_dataChannel!);
    _listenSignaling();

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    signalingClient.send('offer', roomId, localPubKey, offer.toMap());
  }

  // ─── Responder chamada ─────────────────────────────────────────────────

  Future<void> startAsAnswerer() async {
    await _createPeerConnection();
    _pc!.onDataChannel = (channel) {
      _dataChannel = channel;
      _setupDataChannel(channel);
    };
    _listenSignaling();
  }

  // ─── Enviar dados ─────────────────────────────────────────────────────

  void sendBytes(Uint8List bytes) {
    if (!isConnected) return;
    _dataChannel!.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  // ─── Setup interno ────────────────────────────────────────────────────

  Future<void> _createPeerConnection() async {
    final creds = await turnService.fetch();
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': ['turn:${Uri.parse(signalingClient.serverUrl).host}:3478'],
          'username': creds.username,
          'credential': creds.password,
        },
      ],
      'sdpSemantics': 'unified-plan',
    };

    _pc = await createPeerConnection(config);

    _pc!.onIceCandidate = (candidate) {
      signalingClient.send('ice-candidate', roomId, localPubKey, candidate.toMap());
    };

    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _indicatorController.add(ConnectionIndicator.offline);
      }
    };

    // Detecta tipo de candidato via getStats() quando ICE conecta (SPEC-UI-001).
    // flutter_webrtc não expõe onSelectedCandidatePairChanged — usa stats para inferir.
    _pc!.onIceConnectionState = (state) async {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        await _updateIndicatorFromStats();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _indicatorController.add(ConnectionIndicator.offline);
      }
    };
  }

  void _setupDataChannel(RTCDataChannel channel) {
    channel.onMessage = (msg) => _messageController.add(msg);
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _indicatorController.add(ConnectionIndicator.offline);
      }
    };
  }

  void _listenSignaling() {
    signalingClient.messages.listen((msg) async {
      switch (msg.type) {
        case SignalingMessageType.offer:
          await _pc!.setRemoteDescription(
            RTCSessionDescription(msg.data['sdp'] as String, msg.data['type'] as String),
          );
          final answer = await _pc!.createAnswer();
          await _pc!.setLocalDescription(answer);
          signalingClient.send('answer', roomId, localPubKey, answer.toMap());

        case SignalingMessageType.answer:
          await _pc!.setRemoteDescription(
            RTCSessionDescription(msg.data['sdp'] as String, msg.data['type'] as String),
          );

        case SignalingMessageType.iceCandidate:
          await _pc!.addCandidate(RTCIceCandidate(
            msg.data['candidate'] as String?,
            msg.data['sdpMid'] as String?,
            msg.data['sdpMLineIndex'] as int?,
          ));

        default:
          break;
      }
    });
  }

  Future<void> _updateIndicatorFromStats() async {
    if (_pc == null) return;
    try {
      final stats = await _pc!.getStats();

      // Encontra o par de candidatos ativo (nominated)
      final pair = stats.firstWhere(
        (r) => r.type == 'candidate-pair' && r.values['nominated'] == true,
        orElse: () => stats.firstWhere(
          (r) => r.type == 'candidate-pair' && r.values['state'] == 'succeeded',
          orElse: () => stats.firstWhere((r) => r.type == 'candidate-pair', orElse: () => stats.first),
        ),
      );

      final localCandidateId = pair.values['localCandidateId'] as String?;
      if (localCandidateId == null) return;

      final localCandidate = stats.firstWhere(
        (r) => r.id == localCandidateId,
        orElse: () => stats.first,
      );

      final candidateType = localCandidate.values['candidateType'] as String? ?? '';
      if (candidateType == 'relay') {
        _indicatorController.add(ConnectionIndicator.turnRelay);
      } else {
        _indicatorController.add(ConnectionIndicator.p2pDirect);
      }
    } catch (_) {
      // getStats pode falhar se a conexão já fechou
    }
  }

  Future<void> dispose() async {
    await _dataChannel?.close();
    await _pc?.close();
    await _messageController.close();
    await _indicatorController.close();
  }
}
