import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' hide MessageType;
import 'package:http/http.dart' as http;
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../crypto/key_manager.dart';
import '../../crypto/signal_session.dart';
import '../../db/repositories/channel_repository.dart';
import '../../db/repositories/message_repository.dart';
import '../../models/channel.dart';
import '../../models/channel_member.dart';
import '../../models/message.dart';
import '../../models/message_status.dart';
import '../../models/message_type.dart';
import '../../models/user.dart';
import '../../sync/sync_manager.dart';
import '../../sync/vector_clock.dart';
import '../../webrtc/data_channel_handler.dart';
import '../../webrtc/peer_connection_manager.dart';
import '../../webrtc/signaling_client.dart';
import '../../webrtc/turn_credentials_service.dart';
import '../shared/connection_indicator.dart';
import '../shared/message_status_icon.dart';

/// URL do servidor de sinalização — sobrescrita com --dart-define=SERVER_URL=http://host:port
const _kServerUrl = String.fromEnvironment('SERVER_URL', defaultValue: 'http://localhost:8080');

class ChatScreen extends StatefulWidget {
  final Database db;
  final User currentUser;
  final Channel channel;

  const ChatScreen({
    super.key,
    required this.db,
    required this.currentUser,
    required this.channel,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final MessageRepository _repo;
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  List<Message> _messages = [];
  ConnectionIndicator _indicator = ConnectionIndicator.offline;

  // Guardados como campos para fechar corretamente no dispose / reconexão.
  SignalingClient? _signalingClient;
  String? _pubKeyB64;

  PeerConnectionManager? _peerManager;
  DataChannelHandler? _handler;
  SyncManager? _syncManager;

  StreamSubscription<ConnectionIndicator>? _indicatorSub;
  StreamSubscription? _msgSub;
  StreamSubscription<Message>? _handlerMsgSub;

  Timer? _reconnectTimer;
  bool _reconnecting = false;
  // Só aciona reconexão automática se a conexão foi estabelecida ao menos uma vez.
  bool _hadSuccessfulConnection = false;
  String? _connectionError; // mensagem de erro exibida no banner

  @override
  void initState() {
    super.initState();
    _repo = MessageRepository(widget.db);
    _loadHistory();
    _initConnection();
  }

  Future<void> _loadHistory() async {
    final msgs = await _repo.getByChannel(widget.channel.id);
    if (mounted) setState(() => _messages = msgs);
  }

  // ─── Conexão WebRTC ───────────────────────────────────────────────────────

  Future<void> _initConnection() async {
    debugPrint('[Chat] _initConnection start — channel=${widget.channel.id.substring(0, 8)}');
    try {
      final identityPair = await KeyManager.loadIdentityKeyPair();
      final pubBytes = (await identityPair.extractPublicKey()).bytes;
      _pubKeyB64 = base64Encode(pubBytes);
      debugPrint('[Chat] identity key loaded — pk=${_pubKeyB64!.substring(0, 8)}…');

      debugPrint('[Chat] fetching JWT from $_kServerUrl/auth/token');
      final tokenResp = await http.get(
        Uri.parse('$_kServerUrl/auth/token?pk=${Uri.encodeComponent(_pubKeyB64!)}'),
      ).timeout(const Duration(seconds: 4));

      debugPrint('[Chat] /auth/token → status=${tokenResp.statusCode}');
      if (tokenResp.statusCode != 200) {
        debugPrint('[Chat] token request failed — offline mode');
        return;
      }
      final jwt = (jsonDecode(tokenResp.body) as Map<String, dynamic>)['token'] as String;

      final wsUrl = _kServerUrl.replaceFirst(RegExp(r'^http'), 'ws');
      _signalingClient = SignalingClient(serverUrl: wsUrl, jwtToken: jwt);
      final turnService = TurnCredentialsService(serverUrl: _kServerUrl, jwtToken: jwt);

      _peerManager = PeerConnectionManager(
        signalingClient: _signalingClient!,
        turnService: turnService,
        roomId: widget.channel.id,
        localPubKey: _pubKeyB64!,
      );

      _indicatorSub = _peerManager!.onIndicator.listen((s) {
        debugPrint('[Chat] indicator → $s');
        if (!mounted) return;
        setState(() => _indicator = s);
        // Quando a conexão cai, agenda reconexão automática.
        if (s == ConnectionIndicator.offline) _scheduleReconnect();
      });

      // Fallback raw stream — substituído pelo handler quando Signal estiver pronto.
      // Texto é sempre protocolo de controle (SYNC_REQUEST/RESPONSE/ACK), nunca dado de usuário.
      _msgSub = _peerManager!.onMessage.listen((rtcMsg) {
        if (_handler != null) return;
        if (!rtcMsg.isBinary) return;
        _onRawMessage(rtcMsg.binary);
      });

      _peerManager!.onDataChannelReady = (ch) => _onDataChannelReady(ch);

      debugPrint('[Chat] connecting WebSocket → $wsUrl');
      await _signalingClient!.connect();
      debugPrint('[Chat] WebSocket connected ✓');

      _signalingClient!.join(widget.channel.id, _pubKeyB64!);
      debugPrint('[Chat] joined room ${widget.channel.id.substring(0, 8)}…');

      final member = await ChannelRepository(widget.db)
          .getMember(widget.channel.id, widget.currentUser.id);

      final role = member?.role.name ?? 'unknown (null member)';
      debugPrint('[Chat] local role=$role');

      if (member?.role == MemberRole.admin) {
        debugPrint('[Chat] starting as ANSWERER (admin)');
        await _peerManager!.startAsAnswerer();
      } else {
        debugPrint('[Chat] starting as OFFERER (member)');
        await _peerManager!.startAsOfferer();
      }
      debugPrint('[Chat] _initConnection complete');
    } on TimeoutException {
      debugPrint('[Chat] timeout reaching server — offline mode');
    } catch (e, stack) {
      debugPrint('[Chat] _initConnection error: $e\n$stack');
      // Chaves ausentes do keyring: provavelmente reset ou keyring bloqueado no Linux.
      // Não tem sentido reconectar — exibe aviso e para o ciclo de reconnect.
      if (e is StateError &&
          (e.message.contains('Identity key not found') ||
           e.message.contains('Signed pre-key not found') ||
           e.message.contains('Signal identity key not found'))) {
        if (mounted) {
          setState(() => _connectionError =
              'Sessão expirada — chaves não encontradas no keyring.\n'
              'Execute o app com --dart-define=RESET_ON_START=true\n'
              'para refazer o onboarding.');
        }
        _reconnecting = false; // para o loop
      }
    }
  }

  // ─── Teardown + Reconexão ─────────────────────────────────────────────────

  /// Destrói a conexão atual e limpa todos os recursos WebRTC/Signal.
  /// Envia `leave` ao servidor para remover o peer da room ANTES de fechar o WebSocket,
  /// evitando que o `cleanupAllRooms` do servidor derrube um peer recém-reconectado.
  Future<void> _tearDownConnection() async {
    _reconnectTimer?.cancel();
    _indicatorSub?.cancel();
    _msgSub?.cancel();
    _handlerMsgSub?.cancel();
    _handler?.dispose();
    _handler = null;
    _syncManager = null;

    if (_signalingClient != null && _pubKeyB64 != null) {
      debugPrint('[Chat] sending leave before closing WebSocket');
      _signalingClient!.leave(widget.channel.id, _pubKeyB64!);
    }
    await _signalingClient?.close();
    _signalingClient = null;

    await _peerManager?.dispose();
    _peerManager = null;
  }

  /// Agenda reconexão automática 3s após a queda.
  /// Só dispara se a conexão foi estabelecida ao menos uma vez e não há erro de chaves.
  void _scheduleReconnect() {
    if (_reconnecting) return;
    if (!_hadSuccessfulConnection) return; // não reconecta se nunca conectou
    if (_connectionError != null) return;  // não reconecta se há erro de chaves
    _reconnecting = true;
    debugPrint('[Chat] connection lost — reconnecting in 3s…');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      if (!mounted) return;
      debugPrint('[Chat] attempting reconnect');
      await _tearDownConnection();
      _reconnecting = false;
      if (mounted) await _initConnection();
    });
  }

  // ─── DataChannel aberto: inicia Signal Protocol + SyncManager ────────────

  Future<void> _onDataChannelReady(RTCDataChannel ch) async {
    _hadSuccessfulConnection = true; // habilita reconexão automática a partir de agora
    debugPrint('[Chat] DataChannel OPEN — initializing Signal Protocol');
    try {
      final channelRepo = ChannelRepository(widget.db);
      final localMember = await channelRepo.getMember(widget.channel.id, widget.currentUser.id);
      final allMembers = await channelRepo.getMembers(widget.channel.id);

      // Seleciona papel Signal
      final session = SignalSession(peerId: widget.channel.id);
      if (localMember?.role == MemberRole.admin) {
        // Admin (criador): aguarda o PreKeySignalMessage do joiner para completar X3DH.
        debugPrint('[Chat] Signal role=ADMIN — calling session.receive()');
        await session.receive();
      } else {
        // Member (joiner): inicia X3DH com as chaves do criador.
        final peerMember = allMembers.firstWhere(
          (m) => m.userId != widget.currentUser.id,
          orElse: () => allMembers.first,
        );
        debugPrint('[Chat] Signal role=MEMBER — peer signalKey=${peerMember.signalKey != null} sig=${peerMember.signalPreKeySig != null}');
        if (peerMember.signalKey != null &&
            peerMember.signalPreKey != null &&
            peerMember.signalPreKeySig != null) {
          final peerBundle = await SignalSession.buildPeerBundle(
            peerMember.signalKey!,
            peerMember.signalPreKey!,
            peerMember.signalPreKeySig!,
          );
          await session.initiate(peerBundle);
          debugPrint('[Chat] Signal X3DH initiated ✓');
        } else {
          // Sem chaves Signal no QrPayload — canal criado com keyring antigo
          debugPrint('[Chat] Signal keys absent — raw bytes fallback (reset with RESET_ON_START=true)');
          return;
        }
      }

      // Cria o handler e substitui o stream raw
      _handler = DataChannelHandler(
        dataChannel: ch,
        session: session,
        messageRepo: _repo,
        localUserId: widget.currentUser.id,
        channelId: widget.channel.id,
      );

      // P2-A: SyncManager ao conectar (SPEC-SYNC-001)
      _syncManager = SyncManager(
        dataChannel: ch,
        messageRepo: _repo,
        channelId: widget.channel.id,
        localUserId: widget.currentUser.id,
        localClock: VectorClock({widget.currentUser.id: 0}),
      );
      _handler!.onControlMessage = (msg) => _syncManager?.handleControlMessage(msg);
      _handler!.onSessionReady = () {
        if (mounted) _retrySendPending();
      };

      _handlerMsgSub = _handler!.onMessage.listen((msg) {
        debugPrint('[Chat] received message via Signal ✓');
        if (mounted) setState(() => _messages.add(msg));
        _scrollToBottom();
      });

      await _syncManager!.startSync();
      debugPrint('[Chat] SyncManager started ✓');

      // P2-B: reenviar mensagens pending ao conectar
      await _retrySendPending();
      debugPrint('[Chat] DataChannel ready — Signal Protocol active');
    } catch (e, stack) {
      debugPrint('[Chat] Signal init failed: $e\n$stack — falling back to raw bytes');
    }
  }

  // ─── Mensagem raw (antes do Signal inicializar) ───────────────────────────

  Future<void> _onRawMessage(Uint8List payload) async {
    final msg = Message(
      id: '${DateTime.now().millisecondsSinceEpoch}_rx',
      channelId: widget.channel.id,
      senderId: 'peer-${widget.channel.id}',
      type: MessageType.text,
      payload: payload,
      timestamp: DateTime.now(),
      vectorClock: {},
      signature: Uint8List(0),
      status: MessageStatus.delivered,
    );
    await _repo.save(msg);
    if (mounted) setState(() => _messages.add(msg));
    _scrollToBottom();
  }

  // P2-B: reenviar mensagens pending quando DataChannel abre ou X3DH completa.
  Future<void> _retrySendPending() async {
    if (_handler == null) return;
    final pending = (await _repo.getPending())
        .where((m) => m.channelId == widget.channel.id)
        .toList();
    for (final msg in pending) {
      final sent = await _handler!.send(msg);
      if (sent) await _repo.updateStatus(msg.id, MessageStatus.sent);
    }
    await _loadHistory();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(widget.channel.name, style: const TextStyle(color: AppColors.onSurface)),
        iconTheme: const IconThemeData(color: AppColors.onSurface),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ConnectionIndicatorWidget(state: _indicator),
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner de erro quando as chaves do keyring não são encontradas.
          if (_connectionError != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade900,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _connectionError!,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text('Sem mensagens.',
                        style: TextStyle(color: AppColors.subtle)))
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _bubble(_messages[i]),
                  ),
          ),
          _composer(),
        ],
      ),
    );
  }

  Widget _bubble(Message msg) {
    final isMe = msg.senderId == widget.currentUser.id;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: isMe ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(18).copyWith(
            bottomRight: isMe ? const Radius.circular(4) : null,
            bottomLeft: isMe ? null : const Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              utf8.decode(msg.payload, allowMalformed: true),
              style: const TextStyle(color: AppColors.onSurface, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _time(msg.timestamp),
                  style: TextStyle(color: AppColors.subtle, fontSize: 11),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  MessageStatusIcon(status: msg.status),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer() => Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textCtrl,
                style: const TextStyle(color: AppColors.onSurface),
                decoration: InputDecoration(
                  hintText: 'Mensagem',
                  hintStyle: TextStyle(color: AppColors.subtle),
                  filled: true,
                  fillColor: AppColors.background,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _sendText,
              icon: const Icon(Icons.send_rounded, color: AppColors.primary),
            ),
          ],
        ),
      );

  // ─── Envio ────────────────────────────────────────────────────────────────

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();

    final connected = _peerManager?.isConnected == true;
    final msg = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      channelId: widget.channel.id,
      senderId: widget.currentUser.id,
      type: MessageType.text,
      payload: Uint8List.fromList(utf8.encode(text)),
      timestamp: DateTime.now(),
      vectorClock: {},
      signature: Uint8List(0),
      status: connected ? MessageStatus.sent : MessageStatus.pending,
    );

    await _repo.save(msg);
    if (mounted) setState(() => _messages.add(msg));

    if (connected) {
      if (_handler != null) {
        // Pipeline completo: Signal encrypt + Ed25519 sign (SPEC-CRYPTO-002 + SPEC-MSG-001).
        // Se sessionReady=false (X3DH incompleto no admin), send() retorna false e a mensagem
        // fica pending — onSessionReady dispara _retrySendPending quando o X3DH completar.
        final sent = await _handler!.send(msg);
        if (!sent) {
          await _repo.updateStatus(msg.id, MessageStatus.pending);
          if (mounted) {
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == msg.id);
              if (idx != -1) _messages[idx] = msg.copyWith(status: MessageStatus.pending);
            });
          }
        }
      } else {
        // Fallback raw enquanto Signal Protocol não estiver inicializado
        _peerManager!.sendBytes(Uint8List.fromList(utf8.encode(text)));
      }
    }

    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _time(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _indicatorSub?.cancel();
    _msgSub?.cancel();
    _handlerMsgSub?.cancel();
    _handler?.dispose();

    // Envia leave e fecha o WebSocket — evita que o cleanup do servidor derrube
    // um peer recém-reconectado que entrou na mesma room com a mesma pubkey.
    if (_signalingClient != null && _pubKeyB64 != null) {
      _signalingClient!.leave(widget.channel.id, _pubKeyB64!);
    }
    _signalingClient?.close();

    _peerManager?.dispose();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }
}
