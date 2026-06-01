import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'key_manager.dart';

// Adiciona o prefixo 0x05 exigido pelo libsignal para chaves Curve25519 (33 bytes).
Uint8List _prefixed(Uint8List raw) =>
    raw.length == 33 ? raw : (Uint8List(33)..[0] = 0x05..setRange(1, 33, raw));

/// Wrapper sobre libsignal_protocol_dart para criptografia E2E (SPEC-CRYPTO-002).
///
/// Ciclo de vida por conversa 1:1:
///   1. [initiate]  — peer A cria uma sessão com a bundle de chaves do peer B (X3DH).
///   2. [encrypt]   — cada mensagem usa uma chave única (Double Ratchet).
///   3. [decrypt]   — peer B descriptografa e avança o ratchet.
class SignalSession {
  final String peerId;

  late SessionCipher _cipher;
  late InMemorySignalProtocolStore _store;
  late SignalProtocolAddress _peerAddress;

  SignalSession({required this.peerId});

  // ─── Inicialização ───────────────────────────────────────────────────

  /// Cria a sessão a partir da bundle de pré-chaves do peer remoto (X3DH).
  Future<void> initiate(PreKeyBundle peerBundle) async {
    _store = await _buildStore();
    _peerAddress = SignalProtocolAddress(peerId, 1);

    final sessionBuilder = SessionBuilder.fromSignalStore(_store, _peerAddress);
    await sessionBuilder.processPreKeyBundle(peerBundle);
    _cipher = SessionCipher.fromStore(_store, _peerAddress);
  }

  /// Prepara a sessão para receber a primeira mensagem de um peer que iniciou contato.
  /// O X3DH acontece automaticamente ao receber o primeiro PreKeySignalMessage.
  Future<void> receive() async {
    _store = await _buildStore();
    _peerAddress = SignalProtocolAddress(peerId, 1);
    _cipher = SessionCipher.fromStore(_store, _peerAddress);
  }

  // ─── Encrypt / Decrypt ───────────────────────────────────────────────

  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final msg = await _cipher.encrypt(plaintext);
    return Uint8List.fromList(msg.serialize());
  }

  Future<Uint8List> decrypt(Uint8List ciphertext) async {
    // Tenta PreKeySignalMessage primeiro (primeira mensagem após X3DH).
    // A ordem importa: tentar SignalMessage primeiro pode modificar estado interno
    // do cipher antes de lançar exceção, corrompendo a tentativa seguinte.
    try {
      final preKeyMsg = PreKeySignalMessage(ciphertext);
      return Uint8List.fromList(await _cipher.decrypt(preKeyMsg));
    } catch (_) {
      // Mensagem subsequente (Double Ratchet) — SignalMessage
      final msg = SignalMessage.fromSerialized(ciphertext);
      return Uint8List.fromList(await _cipher.decryptFromSignal(msg));
    }
  }

  // ─── Store setup ─────────────────────────────────────────────────────

  /// Constrói o store com as chaves persistentes do KeyManager.
  /// Usa a signal identity key (X25519) — distinta da identity key Ed25519 de assinatura.
  Future<InMemorySignalProtocolStore> _buildStore() async {
    final signalIdPair = await KeyManager.loadSignalIdentityKeyPair();
    final signalIdPrivBytes = Uint8List.fromList(await signalIdPair.extractPrivateKeyBytes());
    final signalIdPubBytes = Uint8List.fromList((await signalIdPair.extractPublicKey()).bytes);

    final ecIdentityKeyPair = IdentityKeyPair(
      IdentityKey(Curve.decodePoint(_prefixed(signalIdPubBytes), 0)),
      Curve.decodePrivatePoint(signalIdPrivBytes),
    );

    final store = InMemorySignalProtocolStore(ecIdentityKeyPair, generateRegistrationId(false));

    // Registra a pre-key persistente — deve coincidir com a chave do QrPayload/invite code.
    final preKeyPair = await KeyManager.loadSignedPreKeyPair();
    final preKeyPrivBytes = Uint8List.fromList(await preKeyPair.extractPrivateKeyBytes());
    final preKeyPubBytes = Uint8List.fromList((await preKeyPair.extractPublicKey()).bytes);

    final ecPreKeyPub = Curve.decodePoint(_prefixed(preKeyPubBytes), 0);
    final ecPreKeyPriv = Curve.decodePrivatePoint(preKeyPrivBytes);
    final ecPreKeyPair = ECKeyPair(ecPreKeyPub, ecPreKeyPriv);

    final ecSignalIdPriv = Curve.decodePrivatePoint(signalIdPrivBytes);
    final preKeySig = Curve.calculateSignature(ecSignalIdPriv, _prefixed(preKeyPubBytes));

    // Armazena como signed pre-key (para completar X3DH no lado do admin).
    await store.storeSignedPreKey(
      1,
      SignedPreKeyRecord(1, Int64(DateTime.now().millisecondsSinceEpoch), ecPreKeyPair, preKeySig),
    );

    // Armazena também como one-time pre-key ID=1, que é referenciada no PreKeyBundle
    // gerado por buildLocalBundle/buildPeerBundle. Sem isso, _cipher.decrypt() lança
    // InvalidKeyIdException ao tentar carregar preKeyId=1 da store.
    await store.storePreKey(
      1,
      PreKeyRecord(1, ecPreKeyPair),
    );

    return store;
  }

  /// Constrói a PreKeyBundle local para compartilhar com um novo peer durante o pareamento.
  static Future<PreKeyBundle> buildLocalBundle() async {
    final signalIdPair = await KeyManager.loadSignalIdentityKeyPair();
    final signalIdPrivBytes = Uint8List.fromList(await signalIdPair.extractPrivateKeyBytes());
    final signalIdPubBytes = Uint8List.fromList((await signalIdPair.extractPublicKey()).bytes);

    final preKeyPair = await KeyManager.loadSignedPreKeyPair();
    final preKeyPubBytes = Uint8List.fromList((await preKeyPair.extractPublicKey()).bytes);

    final ecPreKeyPub = Curve.decodePoint(_prefixed(preKeyPubBytes), 0);
    final ecSignalIdPriv = Curve.decodePrivatePoint(signalIdPrivBytes);
    final preKeySig = Curve.calculateSignature(ecSignalIdPriv, _prefixed(preKeyPubBytes));

    return PreKeyBundle(
      generateRegistrationId(false),
      1, // deviceId
      1, // preKeyId
      ecPreKeyPub,
      1, // signedPreKeyId
      ecPreKeyPub,
      preKeySig,
      IdentityKey(Curve.decodePoint(_prefixed(signalIdPubBytes), 0)),
    );
  }

  /// Constrói a PreKeyBundle do peer remoto a partir das chaves recebidas via QR/invite code.
  /// Usado pelo joiner (member) para iniciar a sessão X3DH com o criador do canal.
  static Future<PreKeyBundle> buildPeerBundle(
    Uint8List signalKey,
    Uint8List preKey,
    Uint8List preKeySig,
  ) async {
    final ecIdPub = Curve.decodePoint(_prefixed(signalKey), 0);
    final ecPrePub = Curve.decodePoint(_prefixed(preKey), 0);
    return PreKeyBundle(
      generateRegistrationId(false),
      1, // deviceId
      1, // preKeyId
      ecPrePub,
      1, // signedPreKeyId
      ecPrePub,
      preKeySig,
      IdentityKey(ecIdPub),
    );
  }
}
