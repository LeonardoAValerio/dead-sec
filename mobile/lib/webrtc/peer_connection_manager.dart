import 'dart:async';

import 'package:flutter/foundation.dart';
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

  // ICE candidates que chegam antes de setRemoteDescription são bufferizados e
  // aplicados assim que a remote description estiver pronta.
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  final _messageController = StreamController<RTCDataChannelMessage>.broadcast();
  final _indicatorController = StreamController<ConnectionIndicator>.broadcast();

  Stream<RTCDataChannelMessage> get onMessage => _messageController.stream;
  Stream<ConnectionIndicator> get onIndicator => _indicatorController.stream;

  bool get isConnected => _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  /// Chamado quando o RTCDataChannel está aberto e pronto para enviar/receber.
  /// Usar para inicializar Signal Protocol, SyncManager e reenviar mensagens pending.
  void Function(RTCDataChannel)? onDataChannelReady;

  PeerConnectionManager({
    required this.signalingClient,
    required this.turnService,
    required this.roomId,
    required this.localPubKey,
  });

  // ─── Iniciar chamada (peer que cria a oferta) ──────────────────────────

  Future<void> startAsOfferer() async {
    debugPrint('[PCM] startAsOfferer — creating peer connection');
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
    debugPrint('[PCM] offer created and sent');
    signalingClient.send('offer', roomId, localPubKey, offer.toMap());
  }

  // ─── Responder chamada ─────────────────────────────────────────────────

  Future<void> startAsAnswerer() async {
    debugPrint('[PCM] startAsAnswerer — waiting for offer');
    await _createPeerConnection();
    _pc!.onDataChannel = (channel) {
      debugPrint('[PCM] onDataChannel received');
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
      debugPrint('[PCM] connectionState → $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _indicatorController.add(ConnectionIndicator.offline);
      }
    };

    _pc!.onSignalingState = (state) {
      debugPrint('[PCM] signalingState → $state');
    };

    // Detecta tipo de candidato via getStats() quando ICE conecta (SPEC-UI-001).
    _pc!.onIceConnectionState = (state) async {
      debugPrint('[PCM] iceConnectionState → $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        await _updateIndicatorFromStats();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _indicatorController.add(ConnectionIndicator.offline);
      }
    };

    _pc!.onIceGatheringState = (state) {
      debugPrint('[PCM] iceGatheringState → $state');
    };
  }

  void _setupDataChannel(RTCDataChannel channel) {
    channel.onMessage = (msg) => _messageController.add(msg);
    channel.onDataChannelState = (state) {
      debugPrint('[PCM] dataChannelState → $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onDataChannelReady?.call(channel);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _indicatorController.add(ConnectionIndicator.offline);
      }
    };
  }

  void _listenSignaling() {
    signalingClient.messages.listen((msg) async {
      switch (msg.type) {
        case SignalingMessageType.offer:
          debugPrint('[PCM] received offer — setting remote description');
          try {
            await _pc!.setRemoteDescription(
              RTCSessionDescription(msg.data['sdp'] as String, msg.data['type'] as String),
            );
            _remoteDescriptionSet = true;
            await _flushPendingCandidates();
            final answer = await _pc!.createAnswer();
            await _pc!.setLocalDescription(answer);
            debugPrint('[PCM] answer created and sent');
            signalingClient.send('answer', roomId, localPubKey, answer.toMap());
          } catch (e) {
            debugPrint('[PCM] error handling offer: $e');
          }

        case SignalingMessageType.answer:
          debugPrint('[PCM] received answer — setting remote description');
          try {
            await _pc!.setRemoteDescription(
              RTCSessionDescription(msg.data['sdp'] as String, msg.data['type'] as String),
            );
            _remoteDescriptionSet = true;
            await _flushPendingCandidates();
            debugPrint('[PCM] remote description set ✓ (flushed ${_pendingCandidates.length} buffered candidates)');
          } catch (e) {
            debugPrint('[PCM] error handling answer: $e');
          }

        case SignalingMessageType.iceCandidate:
          final candidate = RTCIceCandidate(
            msg.data['candidate'] as String?,
            msg.data['sdpMid'] as String?,
            msg.data['sdpMLineIndex'] as int?,
          );
          if (_remoteDescriptionSet) {
            try {
              await _pc!.addCandidate(candidate);
            } catch (e) {
              debugPrint('[PCM] addCandidate error (ignored): $e');
            }
          } else {
            debugPrint('[PCM] ICE candidate buffered (remote desc not ready yet), total=${_pendingCandidates.length + 1}');
            _pendingCandidates.add(candidate);
          }

        default:
          debugPrint('[PCM] unknown signaling message type: ${msg.type}');
          break;
      }
    });
  }

  Future<void> _flushPendingCandidates() async {
    if (_pendingCandidates.isEmpty) return;
    debugPrint('[PCM] flushing ${_pendingCandidates.length} buffered ICE candidates');
    for (final candidate in _pendingCandidates) {
      try {
        await _pc!.addCandidate(candidate);
      } catch (e) {
        debugPrint('[PCM] buffered candidate failed (ignored): $e');
      }
    }
    _pendingCandidates.clear();
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
