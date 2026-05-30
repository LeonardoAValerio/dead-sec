import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../crypto/key_manager.dart';
import '../db/repositories/channel_repository.dart';
import '../models/channel.dart';
import '../models/channel_member.dart';
import 'invite_code_service.dart';

/// Payload codificado no QR Code de convite (SPEC-CHAN-001).
/// Expira em 5 minutos. expiresAt == 0 significa sem expiração (códigos de convite de texto).
class QrPayload {
  final String channelId;
  final String channelName;
  final Uint8List creatorPublicKey;
  final Uint8List signedPreKey;
  final int expiresAt;

  const QrPayload({
    required this.channelId,
    required this.channelName,
    required this.creatorPublicKey,
    required this.signedPreKey,
    required this.expiresAt,
  });

  String encode() => base64Url.encode(utf8.encode(jsonEncode({
        'cid': channelId,
        'name': channelName,
        'pk': base64Encode(creatorPublicKey),
        'spk': base64Encode(signedPreKey),
        'exp': expiresAt,
      })));

  static QrPayload? decode(String raw) {
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(raw))) as Map<String, dynamic>;
      final payload = QrPayload(
        channelId: json['cid'] as String,
        channelName: json['name'] as String,
        creatorPublicKey: base64Decode(json['pk'] as String),
        signedPreKey: base64Decode(json['spk'] as String),
        expiresAt: json['exp'] as int,
      );
      if (payload.isExpired) return null;
      return payload;
    } catch (_) {
      return null;
    }
  }

  // expiresAt == 0 indica código de convite sem expiração
  bool get isExpired => expiresAt != 0 && DateTime.now().millisecondsSinceEpoch > expiresAt;
}

/// Gera QR Codes e códigos de convite de texto para ingresso em canais.
class PairingService {
  final ChannelRepository channelRepo;

  PairingService({required this.channelRepo});

  // ─── Gerador (quem cria o canal) ─────────────────────────────────────────

  /// Cria um novo canal e retorna o QR payload para exibir.
  Future<({Channel channel, QrPayload qr})> createChannel(String name, String creatorId) async {
    final identityPair = await KeyManager.loadIdentityKeyPair();
    final preKeyPair = await KeyManager.loadSignedPreKeyPair();
    final pubKeyBytes = Uint8List.fromList((await identityPair.extractPublicKey()).bytes);
    final preKeyBytes = Uint8List.fromList((await preKeyPair.extractPublicKey()).bytes);

    final channelId = const Uuid().v4();
    final rng = Random.secure();
    final channelKey = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));

    final channel = Channel(
      id: channelId,
      name: name,
      channelKey: channelKey,
      inviteSecretHash: '',
      createdBy: creatorId,
      createdAt: DateTime.now(),
      settings: const ChannelSettings(),
    );

    await channelRepo.saveChannel(channel);
    await channelRepo.saveMember(ChannelMember(
      channelId: channelId,
      userId: creatorId,
      publicKey: pubKeyBytes,
      role: MemberRole.admin,
      joinedAt: DateTime.now(),
      vectorClock: {},
    ));

    final qr = QrPayload(
      channelId: channelId,
      channelName: name,
      creatorPublicKey: pubKeyBytes,
      signedPreKey: preKeyBytes,
      expiresAt: DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
    );

    return (channel: channel, qr: qr);
  }

  /// Cria um canal e gera um código de convite de texto (opcionalmente protegido por senha).
  Future<({Channel channel, String inviteCode})> createChannelWithCode(
    String name,
    String creatorId, {
    String? password,
  }) async {
    final result = await createChannel(name, creatorId);
    final code = InviteCodeService.generate(result.qr, password: password);
    return (channel: result.channel, inviteCode: code);
  }

  // ─── Ingresso ────────────────────────────────────────────────────────────

  /// Processa um QR escaneado: valida e persiste o canal localmente.
  /// A sessão Signal é estabelecida durante o handshake WebRTC, não aqui.
  Future<Channel?> joinViaQr(String qrRaw, String localUserId) async {
    final payload = QrPayload.decode(qrRaw);
    if (payload == null) return null;
    return _joinWithPayload(payload, localUserId);
  }

  /// Processa um código de convite de texto, opcionalmente protegido por senha.
  Future<Channel?> joinViaCode(
    String code,
    String localUserId, {
    String? password,
  }) async {
    final payload = await InviteCodeService.decode(code, password: password);
    if (payload == null) return null;
    return _joinWithPayload(payload, localUserId);
  }

  Future<Channel> _joinWithPayload(QrPayload payload, String localUserId) async {
    final channel = Channel(
      id: payload.channelId,
      name: payload.channelName,
      channelKey: Uint8List(32),
      inviteSecretHash: '',
      createdBy: '',
      createdAt: DateTime.now(),
      settings: const ChannelSettings(),
    );

    await channelRepo.saveChannel(channel);

    final identityPair = await KeyManager.loadIdentityKeyPair();
    final myPubKey = Uint8List.fromList((await identityPair.extractPublicKey()).bytes);

    await channelRepo.saveMember(ChannelMember(
      channelId: payload.channelId,
      userId: localUserId,
      publicKey: myPubKey,
      role: MemberRole.member,
      joinedAt: DateTime.now(),
      vectorClock: {},
    ));

    await channelRepo.saveMember(ChannelMember(
      channelId: payload.channelId,
      userId: 'peer-${payload.channelId}',
      publicKey: payload.creatorPublicKey,
      role: MemberRole.admin,
      joinedAt: DateTime.now(),
      vectorClock: {},
    ));

    return channel;
  }
}
