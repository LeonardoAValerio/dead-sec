import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling_client.dart';
import 'turn_credentials_service.dart';

enum ConnectionIndicator { p2pDirect, turnRelay, offline }

/// Gerencia o ciclo de vida de uma conexão WebRTC P2P com um peer remoto específico.
///
/// - DataChannel em modo reliable+ordered para mensagens e chunks.
/// - Indicador visual derivado do tipo de candidato ICE selecionado (SPEC-UI-001).
/// - Credenciais TURN buscadas do backend antes de cada conexão (SPEC-TURN-002).
/// - Filtra mensagens de sinalização pelo [remotePubKey] para suportar topologia mesh.
class PeerConnectionManager {
  final SignalingClient signalingClient;
  final TurnCredentialsService turnService;
  final String roomId;
  final String localPubKey;
  final String remotePubKey;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dataChannel;

  bool _startedAsOfferer = false;

  /// True se este PCM foi iniciado como offerer (enviou offer ao peer remoto).
  bool get isOfferer => _startedAsOfferer;

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
  void Function(RTCDataChannel)? onDataChannelReady;

  // Guard: evita double-subscribe em _listenSignaling() quando startAs* é chamado
  // múltiplas vezes (ex: após resetWebRTC + reconnect).
  StreamSubscription<SignalingMessage>? _signalingSubscription;

  PeerConnectionManager({
    required this.signalingClient,
    required this.turnService,
    required this.roomId,
    required this.localPubKey,
    required this.remotePubKey,
  });

  // ─── Iniciar chamada (peer que cria a oferta) ──────────────────────────

  Future<void> startAsOfferer() async {
    _startedAsOfferer = true;
    debugPrint('[PCM:${_short(remotePubKey)}] startAsOfferer');
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
    debugPrint('[PCM:${_short(remotePubKey)}] offer sent → to=${_short(remotePubKey)}');
    signalingClient.send('offer', roomId, localPubKey, offer.toMap(), to: remotePubKey);
  }

  // ─── Responder chamada ─────────────────────────────────────────────────

  Future<void> startAsAnswerer() async {
    _startedAsOfferer = false;
    debugPrint('[PCM:${_short(remotePubKey)}] startAsAnswerer — expecting offer from ${_short(remotePubKey)}');
    await _createPeerConnection();
    _pc!.onDataChannel = (channel) {
      debugPrint('[PCM:${_short(remotePubKey)}] onDataChannel received');
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
      signalingClient.send(
        'ice-candidate',
        roomId,
        localPubKey,
        candidate.toMap(),
        to: remotePubKey,
      );
    };

    _pc!.onConnectionState = (state) {
      debugPrint('[PCM:${_short(remotePubKey)}] connectionState → $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _indicatorController.add(ConnectionIndicator.offline);
      }
    };

    _pc!.onSignalingState = (state) {
      debugPrint('[PCM:${_short(remotePubKey)}] signalingState → $state');
    };

    // Detecta tipo de candidato via getStats() quando ICE conecta (SPEC-UI-001).
    _pc!.onIceConnectionState = (state) async {
      debugPrint('[PCM:${_short(remotePubKey)}] iceConnectionState → $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        await _updateIndicatorFromStats();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _indicatorController.add(ConnectionIndicator.offline);
      }
    };

    _pc!.onIceGatheringState = (state) {
      debugPrint('[PCM:${_short(remotePubKey)}] iceGatheringState → $state');
    };
  }

  void _setupDataChannel(RTCDataChannel channel) {
    channel.onMessage = (msg) => _messageController.add(msg);
    channel.onDataChannelState = (state) {
      debugPrint('[PCM:${_short(remotePubKey)}] dataChannelState → $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onDataChannelReady?.call(channel);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _indicatorController.add(ConnectionIndicator.offline);
      }
    };
  }

  void _listenSignaling() {
    // Guard: uma única subscription por instância.
    if (_signalingSubscription != null) return;
    _signalingSubscription = signalingClient.messages.listen((msg) async {
      // Filtra: só processa offer/answer/ice-candidate do nosso peer remoto específico.
      // peer_joined, peer_left e room_peers são tratados pelo ChatScreen via sua própria sub.
      switch (msg.type) {
        case SignalingMessageType.offer:
          if (msg.from != remotePubKey) return;
          debugPrint('[PCM:${_short(remotePubKey)}] received offer');
          try {
            await _pc!.setRemoteDescription(
              RTCSessionDescription(msg.data['sdp'] as String, msg.data['type'] as String),
            );
            _remoteDescriptionSet = true;
            await _flushPendingCandidates();
            final answer = await _pc!.createAnswer();
            await _pc!.setLocalDescription(answer);
            debugPrint('[PCM:${_short(remotePubKey)}] answer sent');
            signalingClient.send('answer', roomId, localPubKey, answer.toMap(), to: remotePubKey);
          } catch (e) {
            debugPrint('[PCM:${_short(remotePubKey)}] error handling offer: $e');
          }

        case SignalingMessageType.answer:
          if (msg.from != remotePubKey) return;
          debugPrint('[PCM:${_short(remotePubKey)}] received answer');
          try {
            await _pc!.setRemoteDescription(
              RTCSessionDescription(msg.data['sdp'] as String, msg.data['type'] as String),
            );
            _remoteDescriptionSet = true;
            await _flushPendingCandidates();
            debugPrint('[PCM:${_short(remotePubKey)}] remote description set ✓');
          } catch (e) {
            debugPrint('[PCM:${_short(remotePubKey)}] error handling answer: $e');
          }

        case SignalingMessageType.iceCandidate:
          if (msg.from != remotePubKey) return;
          final candidate = RTCIceCandidate(
            msg.data['candidate'] as String?,
            msg.data['sdpMid'] as String?,
            msg.data['sdpMLineIndex'] as int?,
          );
          if (_remoteDescriptionSet) {
            try {
              await _pc!.addCandidate(candidate);
            } catch (e) {
              debugPrint('[PCM:${_short(remotePubKey)}] addCandidate error (ignored): $e');
            }
          } else {
            debugPrint('[PCM:${_short(remotePubKey)}] ICE candidate buffered, total=${_pendingCandidates.length + 1}');
            _pendingCandidates.add(candidate);
          }

        default:
          break;
      }
    });
  }

  Future<void> _flushPendingCandidates() async {
    if (_pendingCandidates.isEmpty) return;
    debugPrint('[PCM:${_short(remotePubKey)}] flushing ${_pendingCandidates.length} buffered ICE candidates');
    for (final candidate in _pendingCandidates) {
      try {
        await _pc!.addCandidate(candidate);
      } catch (e) {
        debugPrint('[PCM:${_short(remotePubKey)}] buffered candidate failed (ignored): $e');
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
    } catch (_) {}
  }

  /// Fecha a conexão WebRTC (PC + DataChannel) sem tocar no WebSocket de sinalização.
  Future<void> resetWebRTC() async {
    debugPrint('[PCM:${_short(remotePubKey)}] resetWebRTC');
    await _dataChannel?.close();
    await _pc?.close();
    _dataChannel = null;
    _pc = null;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _indicatorController.add(ConnectionIndicator.offline);
  }

  Future<void> dispose() async {
    await _signalingSubscription?.cancel();
    _signalingSubscription = null;
    await _dataChannel?.close();
    await _pc?.close();
    await _messageController.close();
    await _indicatorController.close();
  }

  static String _short(String key) => key.length > 8 ? '${key.substring(0, 8)}…' : key;
}
