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
import '../../services/notification_service.dart';
import '../channels/channel_details_screen.dart';
import '../shared/connection_indicator.dart';
import '../shared/message_status_icon.dart';

/// URL do servidor de sinalização — sobrescrita com --dart-define=SERVER_URL=http://host:port
const _kServerUrl = String.fromEnvironment('SERVER_URL', defaultValue: 'http://localhost:8000');

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

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final MessageRepository _repo;
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  List<Message> _messages = [];
  Map<String, String> _memberNames = {};
  ConnectionIndicator _indicator = ConnectionIndicator.offline;

  // Sinalização compartilhada por todas as conexões do canal.
  SignalingClient? _signalingClient;
  TurnCredentialsService? _turnService;
  String? _pubKeyB64;

  // Topologia mesh: um PCM + handler + syncManager por peer remoto (chave = pubKey do peer).
  final _peerManagers  = <String, PeerConnectionManager>{};
  final _handlers      = <String, DataChannelHandler>{};
  final _syncManagers  = <String, SyncManager>{};
  final _indicatorSubs = <String, StreamSubscription<ConnectionIndicator>>{};
  final _handlerMsgSubs = <String, StreamSubscription<Message>>{};
  final _indicatorStates = <String, ConnectionIndicator>{};

  // Subscription global para eventos de presença (peer_joined, peer_left, room_peers).
  StreamSubscription<SignalingMessage>? _globalSignalingSub;

  String? _connectionError;
  bool _appInForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repo = MessageRepository(widget.db);
    _memberNames = {widget.currentUser.id: widget.currentUser.displayName};
    _loadHistory();
    _loadMemberNames();
    _initConnection();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
  }

  Future<void> _loadHistory() async {
    final msgs = await _repo.getByChannel(widget.channel.id);
    if (mounted) setState(() => _messages = msgs);
  }

  Future<void> _loadMemberNames() async {
    final members = await ChannelRepository(widget.db).getMembers(widget.channel.id);
    if (!mounted) return;
    setState(() {
      for (final m in members) {
        if (m.displayName.isNotEmpty) _memberNames[m.userId] = m.displayName;
      }
    });
  }

  // ─── Conexão com o servidor de sinalização ────────────────────────────────

  Future<void> _initConnection() async {
    debugPrint('[Chat] _initConnection — channel=${widget.channel.id.substring(0, 8)}');
    try {
      final identityPair = await KeyManager.loadIdentityKeyPair();
      final pubBytes = (await identityPair.extractPublicKey()).bytes;
      _pubKeyB64 = base64Encode(pubBytes);
      debugPrint('[Chat] identity key loaded — pk=${_pubKeyB64!.substring(0, 8)}…');

      debugPrint('[Chat] fetching JWT from $_kServerUrl/auth/token');
      final tokenResp = await http.get(
        Uri.parse('$_kServerUrl/auth/token?pk=${Uri.encodeComponent(_pubKeyB64!)}'),
      ).timeout(const Duration(seconds: 4));

      if (tokenResp.statusCode != 200) {
        debugPrint('[Chat] token request failed — offline mode');
        return;
      }
      final jwt = (jsonDecode(tokenResp.body) as Map<String, dynamic>)['token'] as String;

      final wsUrl = _kServerUrl.replaceFirst(RegExp(r'^http'), 'ws');
      _signalingClient = SignalingClient(serverUrl: wsUrl, jwtToken: jwt);
      _turnService = TurnCredentialsService(serverUrl: _kServerUrl, jwtToken: jwt);

      await _signalingClient!.connect();
      debugPrint('[Chat] WebSocket connected ✓');

      // Subscription global: trata eventos de presença para todo o mesh.
      // Deve vir APÓS connect() — _controller só existe depois de connect().
      _globalSignalingSub = _signalingClient!.messages.listen(_onSignalingEvent);

      _signalingClient!.join(widget.channel.id, _pubKeyB64!);
      debugPrint('[Chat] joined room ${widget.channel.id.substring(0, 8)}…');
    } on TimeoutException {
      debugPrint('[Chat] timeout reaching server — offline mode');
    } catch (e, stack) {
      debugPrint('[Chat] _initConnection error: $e\n$stack');
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
      }
    }
  }

  // ─── Eventos globais de sinalização ──────────────────────────────────────

  void _onSignalingEvent(SignalingMessage msg) {
    if (!mounted) return;
    switch (msg.type) {
      case SignalingMessageType.peerJoined:
        debugPrint('[Chat] peer_joined from=${msg.from.substring(0, 8)}…');
        _onPeerJoined(msg.from);
      case SignalingMessageType.peerLeft:
        debugPrint('[Chat] peer_left from=${msg.from.substring(0, 8)}…');
        _onPeerLeft(msg.from);
      case SignalingMessageType.roomPeers:
        final peers = (msg.data['peers'] as List<dynamic>?)?.cast<String>() ?? [];
        debugPrint('[Chat] room_peers — ${peers.length} existing peer(s)');
        _onRoomPeers(peers);
      default:
        break;
    }
  }

  // ─── Gestão de conexões por peer ─────────────────────────────────────────

  /// Novo peer entrou na sala → somos answerer para ele.
  Future<void> _onPeerJoined(String remotePK) async {
    if (!_appInForeground) NotificationService.notifyPeerJoined(widget.channel.name);
    // Se já existe uma conexão (peer reconectou), descarta a anterior.
    if (_peerManagers.containsKey(remotePK)) {
      await _disposePeer(remotePK);
    }
    await _createPeerConnection(remotePK, isOfferer: false);
  }

  /// Recebemos lista de peers já presentes → somos o novo joiner, offerer para cada um.
  Future<void> _onRoomPeers(List<String> peerPKs) async {
    for (final remotePK in peerPKs) {
      if (!_peerManagers.containsKey(remotePK)) {
        await _createPeerConnection(remotePK, isOfferer: true);
      }
    }
  }

  /// Peer saiu da sala → descarta recursos da conexão com ele.
  Future<void> _onPeerLeft(String remotePK) async {
    await _disposePeer(remotePK);
    _updateIndicator();
  }

  /// Cria e configura um [PeerConnectionManager] para [remotePK].
  Future<void> _createPeerConnection(String remotePK, {required bool isOfferer}) async {
    if (_signalingClient == null || _turnService == null || _pubKeyB64 == null) return;

    final pcm = PeerConnectionManager(
      signalingClient: _signalingClient!,
      turnService: _turnService!,
      roomId: widget.channel.id,
      localPubKey: _pubKeyB64!,
      remotePubKey: remotePK,
    );
    _peerManagers[remotePK] = pcm;

    _indicatorSubs[remotePK] = pcm.onIndicator.listen((s) {
      if (!mounted) return;
      _indicatorStates[remotePK] = s;
      _updateIndicator();
    });

    pcm.onDataChannelReady = (ch) => _onDataChannelReady(ch, remotePK);

    if (isOfferer) {
      await pcm.startAsOfferer();
    } else {
      await pcm.startAsAnswerer();
    }
  }

  /// Remove e descarta todos os recursos associados ao peer [remotePK].
  Future<void> _disposePeer(String remotePK) async {
    _handlerMsgSubs[remotePK]?.cancel();
    _handlerMsgSubs.remove(remotePK);
    _indicatorSubs[remotePK]?.cancel();
    _indicatorSubs.remove(remotePK);
    _indicatorStates.remove(remotePK);
    _handlers[remotePK]?.dispose();
    _handlers.remove(remotePK);
    _syncManagers.remove(remotePK);
    await _peerManagers[remotePK]?.dispose();
    _peerManagers.remove(remotePK);
  }

  void _updateIndicator() {
    if (!mounted) return;
    ConnectionIndicator best = ConnectionIndicator.offline;
    for (final s in _indicatorStates.values) {
      if (s == ConnectionIndicator.p2pDirect) {
        best = ConnectionIndicator.p2pDirect;
        break;
      } else if (s == ConnectionIndicator.turnRelay) {
        best = ConnectionIndicator.turnRelay;
      }
    }
    setState(() => _indicator = best);
  }

  // ─── DataChannel aberto: troca MEMBER_INFO + inicia Signal Protocol ──────

  Future<void> _onDataChannelReady(RTCDataChannel ch, String remotePK) async {
    debugPrint('[Chat] DataChannel OPEN for peer=${remotePK.substring(0, 8)}…');

    // Early buffer: captura todas as mensagens que chegam antes do handler estar pronto.
    // Binárias = Signal ciphertext. Texto = MEMBER_INFO ou controle (SYNC_*).
    final earlyBinaryBuffer = <RTCDataChannelMessage>[];
    final earlyTextBuffer   = <RTCDataChannelMessage>[];
    final memberInfoCompleter = Completer<Map<String, dynamic>?>();

    ch.onMessage = (raw) {
      if (!raw.isBinary) {
        try {
          final json = jsonDecode(raw.text) as Map<String, dynamic>;
          if (json['type'] == 'MEMBER_INFO' && !memberInfoCompleter.isCompleted) {
            memberInfoCompleter.complete(json);
            return;
          }
        } catch (_) {}
        earlyTextBuffer.add(raw);
      } else {
        earlyBinaryBuffer.add(raw);
      }
    };

    // Envia MEMBER_INFO imediatamente (pré-Signal, protegido por DTLS).
    // Resolve Bug 1 (detalhes do canal) e bootstrapa Signal para pares não-admin (Bug 2).
    await _sendMemberInfo(ch);

    // Aguarda MEMBER_INFO do peer remoto (máximo 5s).
    Map<String, dynamic>? remoteMemberInfo;
    try {
      remoteMemberInfo = await memberInfoCompleter.future.timeout(const Duration(seconds: 5));
      debugPrint('[Chat] MEMBER_INFO received from peer=${remotePK.substring(0, 8)}…');
    } catch (_) {
      debugPrint('[Chat] MEMBER_INFO timeout for peer=${remotePK.substring(0, 8)}… — continuing');
    }

    if (remoteMemberInfo != null) await _saveRemoteMemberInfo(remoteMemberInfo);

    final pcm = _peerManagers[remotePK];
    if (pcm == null || !mounted) return;

    try {
      final session = SignalSession(peerId: remotePK);

      if (pcm.isOfferer) {
        // Offerer = X3DH initiator: constrói a bundle com as chaves Signal do peer.
        // Prioridade: MEMBER_INFO (mais fresco) → DB (join via QR anterior).
        final bundle = await _buildPeerBundle(remoteMemberInfo, remotePK);
        if (bundle == null) {
          debugPrint('[Chat] Signal keys absent for peer=${remotePK.substring(0, 8)}… — skipping Signal');
          return;
        }
        await session.initiate(bundle);
        debugPrint('[Chat] Signal X3DH initiated with peer=${remotePK.substring(0, 8)}…');
      } else {
        // Answerer = X3DH responder: aguarda o PreKeySignalMessage do offerer.
        await session.receive();
        debugPrint('[Chat] Signal session.receive() ready for peer=${remotePK.substring(0, 8)}…');
      }

      final handler = DataChannelHandler(
        dataChannel: ch,
        session: session,
        messageRepo: _repo,
        localUserId: widget.currentUser.id,
        channelId: widget.channel.id,
      );
      _handlers[remotePK] = handler;

      final syncManager = SyncManager(
        dataChannel: ch,
        messageRepo: _repo,
        channelId: widget.channel.id,
        localUserId: widget.currentUser.id,
        localClock: VectorClock({widget.currentUser.id: 0}),
        onMessagesReceived: _loadHistory,
      );
      _syncManagers[remotePK] = syncManager;

      handler.onControlMessage = (msg) => syncManager.handleControlMessage(msg);
      handler.onSessionReady = () {
        if (mounted) _retrySendPending();
      };

      _handlerMsgSubs[remotePK] = handler.onMessage.listen((msg) {
        if (!mounted) return;
        setState(() {
          // Deduplicação por UUID na UI (SPEC-SYNC-002).
          if (!_messages.any((m) => m.id == msg.id)) _messages.add(msg);
        });
        _scrollToBottom();
        if (!_appInForeground) {
          final preview = msg.payload.length > 40
              ? String.fromCharCodes(msg.payload.take(40))
              : String.fromCharCodes(msg.payload);
          NotificationService.notifyNewMessage(widget.channel.name, preview);
        }
      });

      // Replay mensagens bufferizadas antes do handler estar pronto.
      for (final raw in earlyBinaryBuffer) {
        await handler.processRawMessage(raw);
      }
      for (final raw in earlyTextBuffer) {
        await handler.processRawMessage(raw);
      }

      // Offerer envia SESSION_HELLO para completar o X3DH no lado do answerer.
      if (pcm.isOfferer) await handler.sendSessionHello();

      await syncManager.startSync();
      debugPrint('[Chat] SyncManager started for peer=${remotePK.substring(0, 8)}…');
      await _retrySendPending();
    } catch (e, stack) {
      debugPrint('[Chat] Signal init failed for peer=${remotePK.substring(0, 8)}…: $e\n$stack');
    }
  }

  /// Constrói a PreKeyBundle do peer remoto.
  /// Prioridade: dados frescos do [remoteMemberInfo] → fallback para DB.
  Future<dynamic> _buildPeerBundle(Map<String, dynamic>? remoteMemberInfo, String remotePK) async {
    // 1. Dados do MEMBER_INFO (mais recente).
    if (remoteMemberInfo != null &&
        remoteMemberInfo['signalKey'] != null &&
        remoteMemberInfo['signalPreKey'] != null &&
        remoteMemberInfo['signalPreKeySig'] != null) {
      return SignalSession.buildPeerBundle(
        base64Decode(remoteMemberInfo['signalKey'] as String),
        base64Decode(remoteMemberInfo['signalPreKey'] as String),
        base64Decode(remoteMemberInfo['signalPreKeySig'] as String),
      );
    }

    // 2. Fallback: chaves guardadas no DB ao ingressar via QR/invite.
    final allMembers = await ChannelRepository(widget.db).getMembers(widget.channel.id);
    final peerMember = allMembers.firstWhereOrNull(
      (m) => m.userId != widget.currentUser.id,
    );
    if (peerMember?.signalKey != null &&
        peerMember?.signalPreKey != null &&
        peerMember?.signalPreKeySig != null) {
      return SignalSession.buildPeerBundle(
        peerMember!.signalKey!,
        peerMember.signalPreKey!,
        peerMember.signalPreKeySig!,
      );
    }

    return null;
  }

  // ─── Troca de MEMBER_INFO ─────────────────────────────────────────────────

  /// Envia as informações do peer local via DataChannel (pré-Signal, protegido por DTLS).
  Future<void> _sendMemberInfo(RTCDataChannel ch) async {
    try {
      final localMember = await ChannelRepository(widget.db)
          .getMember(widget.channel.id, widget.currentUser.id);
      final signalKeys = await SignalSession.getLocalSignalKeys();

      final info = jsonEncode({
        'type': 'MEMBER_INFO',
        'userId': widget.currentUser.id,
        'displayName': widget.currentUser.displayName,
        'publicKey': base64Encode(widget.currentUser.identityPublicKey),
        'signalKey': base64Encode(signalKeys['signalKey']!),
        'signalPreKey': base64Encode(signalKeys['signalPreKey']!),
        'signalPreKeySig': base64Encode(signalKeys['signalPreKeySig']!),
        'role': localMember?.role.name ?? 'member',
        'channelId': widget.channel.id,
      });
      ch.send(RTCDataChannelMessage(info));
      debugPrint('[Chat] MEMBER_INFO sent');
    } catch (e) {
      debugPrint('[Chat] sendMemberInfo failed: $e');
    }
  }

  /// Persiste as informações do peer remoto em channel_members (upsert).
  /// Remove o placeholder 'peer-<channelId>' salvo no join via QR para evitar duplicatas.
  Future<void> _saveRemoteMemberInfo(Map<String, dynamic> info) async {
    try {
      final userId = info['userId'] as String;
      final publicKey = base64Decode(info['publicKey'] as String);
      final displayName = info['displayName'] as String? ?? '';
      final repo = ChannelRepository(widget.db);

      // Remove registro placeholder (userId sintético) com a mesma chave pública.
      await repo.deleteMemberByPublicKey(
        widget.channel.id,
        publicKey,
        exceptUserId: userId,
      );

      final member = ChannelMember(
        channelId: widget.channel.id,
        userId: userId,
        displayName: displayName,
        publicKey: publicKey,
        role: info['role'] == 'admin' ? MemberRole.admin : MemberRole.member,
        joinedAt: DateTime.now(),
        vectorClock: {},
        signalKey: info['signalKey'] != null
            ? base64Decode(info['signalKey'] as String) : null,
        signalPreKey: info['signalPreKey'] != null
            ? base64Decode(info['signalPreKey'] as String) : null,
        signalPreKeySig: info['signalPreKeySig'] != null
            ? base64Decode(info['signalPreKeySig'] as String) : null,
      );
      await repo.saveMember(member);

      if (displayName.isNotEmpty && mounted) {
        setState(() => _memberNames[userId] = displayName);
      }
      debugPrint('[Chat] MEMBER_INFO saved — userId=$userId displayName=$displayName');
    } catch (e) {
      debugPrint('[Chat] saveRemoteMemberInfo failed: $e');
    }
  }

  // ─── Reenvio de pending + retry ──────────────────────────────────────────

  Future<void> _retrySendPending() async {
    if (_handlers.isEmpty) return;
    final pending = (await _repo.getPending())
        .where((m) => m.channelId == widget.channel.id)
        .toList();
    for (final msg in pending) {
      bool anySent = false;
      for (final handler in _handlers.values) {
        if (await handler.send(msg)) anySent = true;
      }
      if (anySent) await _repo.updateStatus(msg.id, MessageStatus.sent);
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
          IconButton(
            icon: const Icon(Icons.info_outline, color: AppColors.onSurface),
            tooltip: 'Detalhes do canal',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChannelDetailsScreen(
                  db: widget.db,
                  currentUser: widget.currentUser,
                  channel: widget.channel,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ConnectionIndicatorWidget(state: _indicator),
          ),
        ],
      ),
      body: Column(
        children: [
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
    final senderName = isMe ? '' : (_memberNames[msg.senderId] ?? '');
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe && senderName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  senderName,
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Text(
              utf8.decode(msg.payload, allowMalformed: true),
              style: const TextStyle(color: AppColors.onSurface, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer() => SafeArea(
        top: false,
        child: Container(
          color: AppColors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textCtrl,
                  style: const TextStyle(color: AppColors.onSurface),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendText(),
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
        ),
      );

  // ─── Envio ────────────────────────────────────────────────────────────────

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();

    final connected = _handlers.isNotEmpty;
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
      bool anySent = false;
      for (final handler in _handlers.values) {
        if (await handler.send(msg)) anySent = true;
      }
      if (!anySent) {
        await _repo.updateStatus(msg.id, MessageStatus.pending);
        if (mounted) {
          setState(() {
            final idx = _messages.indexWhere((m) => m.id == msg.id);
            if (idx != -1) _messages[idx] = msg.copyWith(status: MessageStatus.pending);
          });
        }
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
    WidgetsBinding.instance.removeObserver(this);
    _globalSignalingSub?.cancel();
    for (final sub in _indicatorSubs.values) {
      sub.cancel();
    }
    for (final sub in _handlerMsgSubs.values) {
      sub.cancel();
    }
    for (final handler in _handlers.values) {
      handler.dispose();
    }
    if (_signalingClient != null && _pubKeyB64 != null) {
      _signalingClient!.leave(widget.channel.id, _pubKeyB64!);
    }
    _signalingClient?.close();
    for (final pcm in _peerManagers.values) {
      pcm.dispose();
    }
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }
}

extension _FirstOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
