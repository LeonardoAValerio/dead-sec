import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'key_manager.dart';

/// Assina e verifica mensagens com Ed25519 (SPEC-MSG-001).
///
/// - Todo payload é assinado com a identity key do remetente antes de transmitir.
/// - O receptor verifica a assinatura; mensagens com assinatura inválida são descartadas silenciosamente.
class MessageSigner {
  static final _ed25519 = Ed25519();

  static Future<Uint8List> sign(Uint8List payload) async {
    final keyPair = await KeyManager.loadIdentityKeyPair();
    final sig = await _ed25519.sign(payload, keyPair: keyPair);
    return Uint8List.fromList(sig.bytes);
  }

  /// Retorna true se a assinatura for válida para o payload e a chave pública do remetente.
  static Future<bool> verify({
    required Uint8List payload,
    required Uint8List signature,
    required Uint8List senderPublicKey,
  }) async {
    try {
      final pubKey = SimplePublicKey(senderPublicKey, type: KeyPairType.ed25519);
      final sig = Signature(signature, publicKey: pubKey);
      return await _ed25519.verify(payload, signature: sig);
    } catch (_) {
      return false;
    }
  }
}
