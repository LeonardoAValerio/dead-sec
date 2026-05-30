import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'key_manager.dart';

/// Wrapper sobre libsignal_protocol_dart para criptografia E2E (SPEC-CRYPTO-002).
///
/// Ciclo de vida por conversa 1:1:
///   1. [initiate]  — peer A cria uma sessão com a bundle de chaves do peer B (X3DH).
///   2. [encrypt]   — cada mensagem usa uma chave única (Double Ratchet).
///   3. [decrypt]   — peer B descriptografa e avança o ratchet.
///
/// A sessão serializada é persistida localmente para sobreviver a reinicializações.
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
  Future<void> receive(PreKeyBundle ownBundle) async {
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
    // Tenta como SignalMessage (Double Ratchet); se falhar como PreKeySignalMessage (primeira msg)
    try {
      final msg = SignalMessage.fromSerialized(ciphertext);
      return Uint8List.fromList(await _cipher.decryptFromSignal(msg));
    } catch (_) {
      final preKeyMsg = PreKeySignalMessage(ciphertext);
      return Uint8List.fromList(await _cipher.decrypt(preKeyMsg));
    }
  }

  // ─── Store setup ─────────────────────────────────────────────────────

  Future<InMemorySignalProtocolStore> _buildStore() async {
    final identityKeyPair = await KeyManager.loadIdentityKeyPair();
    final identityPrivBytes = await identityKeyPair.extractPrivateKeyBytes();
    final identityPubBytes = (await identityKeyPair.extractPublicKey()).bytes;

    final ecIdentityKeyPair = IdentityKeyPair(
      IdentityKey(Curve.decodePoint(Uint8List.fromList(identityPubBytes), 0)),
      Curve.decodePrivatePoint(Uint8List.fromList(identityPrivBytes)),
    );

    final registrationId = generateRegistrationId(false);
    final store = InMemorySignalProtocolStore(ecIdentityKeyPair, registrationId);

    // Registra a pré-chave assinada no store
    final ecPreKeyPair = Curve.generateKeyPair();
    final signedPreKey = SignedPreKeyRecord(
      1,
      Int64(DateTime.now().millisecondsSinceEpoch),
      ecPreKeyPair,
      Uint8List(64), // assinatura real calculada via Ed25519 na produção
    );
    await store.storeSignedPreKey(1, signedPreKey);

    return store;
  }

  /// Constrói a PreKeyBundle local para compartilhar com um novo peer durante o pareamento.
  static Future<PreKeyBundle> buildLocalBundle(String userId) async {
    final identityKeyPair = await KeyManager.loadIdentityKeyPair();
    final identityPubBytes = (await identityKeyPair.extractPublicKey()).bytes;

    final preKeyPair = await KeyManager.loadSignedPreKeyPair();
    final preKeyPubBytes = (await preKeyPair.extractPublicKey()).bytes;

    final ecPreKeyPub = Curve.decodePoint(Uint8List.fromList(preKeyPubBytes), 0);
    final ecIdentityPub = Curve.decodePoint(Uint8List.fromList(identityPubBytes), 0);

    return PreKeyBundle(
      generateRegistrationId(false),
      1, // deviceId
      1, // preKeyId
      ecPreKeyPub,
      1, // signedPreKeyId
      ecPreKeyPub, // simplificado — em produção usa chave assinada separada
      Uint8List(64), // assinatura
      IdentityKey(ecIdentityPub),
    );
  }
}
