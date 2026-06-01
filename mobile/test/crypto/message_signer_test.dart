import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// Testa sign/verify de MessageSigner diretamente via pacote cryptography,
// sem depender do KeyManager (que requer flutter_secure_storage).
void main() {
  final ed25519 = Ed25519();

  group('MessageSigner — Ed25519 sign/verify', () {
    late SimpleKeyPair keyPair;

    setUp(() async {
      keyPair = await ed25519.newKeyPair();
    });

    test('sign → verify retorna true para payload original', () async {
      final payload = Uint8List.fromList('mensagem segura'.codeUnits);
      final sig = await ed25519.sign(payload, keyPair: keyPair);

      final valid = await ed25519.verify(payload, signature: sig);
      expect(valid, isTrue);
    });

    test('verify retorna false quando payload foi alterado', () async {
      final payload = Uint8List.fromList('mensagem original'.codeUnits);
      final sig = await ed25519.sign(payload, keyPair: keyPair);

      final altered = Uint8List.fromList('mensagem alterada'.codeUnits);
      final valid = await ed25519.verify(altered, signature: sig);
      expect(valid, isFalse);
    });

    test('verify retorna false com chave pública errada', () async {
      final payload = Uint8List.fromList('teste'.codeUnits);
      final sig = await ed25519.sign(payload, keyPair: keyPair);

      // Chave diferente
      final otherKey = await ed25519.newKeyPair();
      final otherPub = await otherKey.extractPublicKey();
      final wrongSig = Signature(sig.bytes, publicKey: otherPub);

      final valid = await ed25519.verify(payload, signature: wrongSig);
      expect(valid, isFalse);
    });

    test('assinaturas distintas para payloads distintos', () async {
      final p1 = Uint8List.fromList('msg1'.codeUnits);
      final p2 = Uint8List.fromList('msg2'.codeUnits);
      final s1 = await ed25519.sign(p1, keyPair: keyPair);
      final s2 = await ed25519.sign(p2, keyPair: keyPair);
      expect(s1.bytes, isNot(equals(s2.bytes)));
    });
  });
}
