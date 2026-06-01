import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';

import '../crypto/key_manager.dart';
import '../db/repositories/channel_repository.dart';
import '../models/channel.dart';
import '../models/channel_member.dart';
import 'invite_code_service.dart';

// Adiciona o prefixo 0x05 exigido pelo libsignal para chaves Curve25519.
Uint8List _prefixed(Uint8List raw) =>
    raw.length == 33 ? raw : (Uint8List(33)..[0] = 0x05..setRange(1, 33, raw));

/// Payload codificado no QR Code de convite (SPEC-CHAN-001).
/// Expira em 5 minutos. expiresAt == 0 significa sem expiração (códigos de convite de texto).
class QrPayload {
  final String channelId;
  final String channelName;
  final Uint8List creatorPublicKey;
  final Uint8List signedPreKey;
  final int expiresAt;
  // Chave de identidade Signal (X25519) do criador — para X3DH no Double Ratchet.
  final Uint8List? signalIdentityKey;
  // Assinatura da signed pre-key pela signal identity key — exigida pelo processPreKeyBundle.
  final Uint8List? preKeySignature;

  const QrPayload({
    required this.channelId,
    required this.channelName,
    required this.creatorPublicKey,
    required this.signedPreKey,
    required this.expiresAt,
    this.signalIdentityKey,
    this.preKeySignature,
  });

  String encode() => base64Url.encode(utf8.encode(jsonEncode({
        'cid': channelId,
        'name': channelName,
        'pk': base64Encode(creatorPublicKey),
        'spk': base64Encode(signedPreKey),
        'exp': expiresAt,
        if (signalIdentityKey != null) 'sik': base64Encode(signalIdentityKey!),
        if (preKeySignature != null) 'spksig': base64Encode(preKeySignature!),
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
        signalIdentityKey: json['sik'] != null ? base64Decode(json['sik'] as String) : null,
        preKeySignature: json['spksig'] != null ? base64Decode(json['spksig'] as String) : null,
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

    // Tenta carregar a signal identity key (X25519) para incluir suporte a Signal Protocol.
    // Se a chave não existir (keyring antigo), o canal é criado sem suporte a X3DH —
    // mensagens ainda funcionam via raw bytes sobre o DataChannel.
    Uint8List? signalIdPubBytes;
    Uint8List? preKeySig;
    try {
      final signalIdPair = await KeyManager.loadSignalIdentityKeyPair();
      signalIdPubBytes = Uint8List.fromList((await signalIdPair.extractPublicKey()).bytes);
      final signalIdPrivBytes = Uint8List.fromList(await signalIdPair.extractPrivateKeyBytes());
      final ecSignalIdPriv = Curve.decodePrivatePoint(signalIdPrivBytes);
      preKeySig = Curve.calculateSignature(ecSignalIdPriv, _prefixed(preKeyBytes));
    } catch (_) {
      // signal_identity_v1 ausente — execute onboarding com RESET_ON_START=true para gerar
    }

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
      signalIdentityKey: signalIdPubBytes,  // null se keyring antigo sem signal_identity_v1
      preKeySignature: preKeySig,            // null se keyring antigo
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
      signalKey: payload.signalIdentityKey,
      signalPreKey: payload.signedPreKey,
      signalPreKeySig: payload.preKeySignature,
    ));

    return channel;
  }
}
