import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../crypto/key_manager.dart';
import '../../db/repositories/channel_repository.dart';
import '../../db/repositories/message_repository.dart';
import '../../models/channel.dart';
import '../../models/channel_member.dart';
import '../../models/message.dart';
import '../../models/message_status.dart';
import '../../models/message_type.dart';
import '../../models/user.dart';
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

  PeerConnectionManager? _peerManager;
  StreamSubscription<ConnectionIndicator>? _indicatorSub;
  StreamSubscription? _msgSub;

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
    try {
      // 1. Chave pública local
      final identityPair = await KeyManager.loadIdentityKeyPair();
      final pubBytes = (await identityPair.extractPublicKey()).bytes;
      final pubKeyB64 = base64Encode(pubBytes);

      // 2. JWT anônimo do servidor
      final tokenResp = await http.get(
        Uri.parse('$_kServerUrl/auth/token?pk=${Uri.encodeComponent(pubKeyB64)}'),
      ).timeout(const Duration(seconds: 4));

      if (tokenResp.statusCode != 200) return;
      final jwt = (jsonDecode(tokenResp.body) as Map<String, dynamic>)['token'] as String;

      // 3. Serviços (WS para sinalização, HTTP para TURN)
      final wsUrl = _kServerUrl.replaceFirst(RegExp(r'^http'), 'ws');
      final signalingClient = SignalingClient(serverUrl: wsUrl, jwtToken: jwt);
      final turnService = TurnCredentialsService(serverUrl: _kServerUrl, jwtToken: jwt);

      // 4. PeerConnectionManager
      _peerManager = PeerConnectionManager(
        signalingClient: signalingClient,
        turnService: turnService,
        roomId: widget.channel.id,
        localPubKey: pubKeyB64,
      );

      // 5. Indicador de conexão
      _indicatorSub = _peerManager!.onIndicator.listen((s) {
        if (mounted) setState(() => _indicator = s);
      });

      // 6. Mensagens recebidas pelo DataChannel
      _msgSub = _peerManager!.onMessage.listen((rtcMsg) async {
        final payload = rtcMsg.isBinary
            ? rtcMsg.binary
            : Uint8List.fromList(utf8.encode(rtcMsg.text));

        final inMsg = Message(
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

        await _repo.save(inMsg);
        if (mounted) setState(() => _messages.add(inMsg));
        _scrollToBottom();
      });

      // 7. Conecta ao servidor de sinalização e entra na sala
      await signalingClient.connect();
      signalingClient.join(widget.channel.id, pubKeyB64);

      // 8. Admin (criador) aguarda offer; member (quem entrou) envia offer
      final member = await ChannelRepository(widget.db)
          .getMember(widget.channel.id, widget.currentUser.id);

      if (member?.role == MemberRole.admin) {
        await _peerManager!.startAsAnswerer();
      } else {
        await _peerManager!.startAsOfferer();
      }
    } on TimeoutException {
      // Servidor offline — modo offline, mensagens ficam como pending
    } catch (_) {
      // Qualquer outro erro — continua offline sem crashar
    }
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
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text('Sem mensagens.',
                        style: TextStyle(color: AppColors.subtle)))
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding:
                        const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
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
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
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
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
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
      _peerManager!.sendBytes(Uint8List.fromList(utf8.encode(text)));
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
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _indicatorSub?.cancel();
    _msgSub?.cancel();
    _peerManager?.dispose();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }
}
