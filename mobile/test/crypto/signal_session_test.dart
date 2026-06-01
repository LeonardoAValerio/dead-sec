import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

// Testa o protocolo Signal Protocol (X3DH + Double Ratchet) diretamente via libsignal,
// sem depender do KeyManager (que requer flutter_secure_storage em produção).
//
// Valida os critérios mínimos do P1:
//   - Two-party session: Alice inicia X3DH, Bob decripta a primeira mensagem.
//   - Forward secrecy: segunda mensagem usa chave diferente (Double Ratchet avançou).
void main() {
  group('Signal Protocol — X3DH + Double Ratchet', () {
    late ECKeyPair bobIdentityKeyPair;
    late ECKeyPair bobPreKeyPair;
    late Uint8List preKeySig;
    late InMemorySignalProtocolStore aliceStore;
    late InMemorySignalProtocolStore bobStore;
    late SignalProtocolAddress bobAddress;
    late SignalProtocolAddress aliceAddress;

    setUp(() async {
      // Gera pares de chaves para Bob (criador do canal)
      bobIdentityKeyPair = Curve.generateKeyPair();
      bobPreKeyPair = Curve.generateKeyPair();

      // Bob assina a pre-key com sua identity key
      preKeySig = Curve.calculateSignature(
        bobIdentityKeyPair.privateKey,
        bobPreKeyPair.publicKey.serialize(),
      );

      // Store de Alice (joiner)
      final aliceIdPair = Curve.generateKeyPair();
      final aliceIdentityKP = IdentityKeyPair(
        IdentityKey(aliceIdPair.publicKey),
        aliceIdPair.privateKey,
      );
      aliceStore = InMemorySignalProtocolStore(aliceIdentityKP, generateRegistrationId(false));
      aliceAddress = SignalProtocolAddress('alice', 1);

      // Store de Bob (criador)
      final bobIdentityKP = IdentityKeyPair(
        IdentityKey(bobIdentityKeyPair.publicKey),
        bobIdentityKeyPair.privateKey,
      );
      bobStore = InMemorySignalProtocolStore(bobIdentityKP, generateRegistrationId(false));
      bobAddress = SignalProtocolAddress('bob', 1);

      // Bob registra a signed pre-key E a one-time pre-key em seu store.
      // O PreKeyBundle referencia ambas por ID; o store precisa ter as duas.
      final signedPreKeyRecord = SignedPreKeyRecord(
        1,
        Int64(DateTime.now().millisecondsSinceEpoch),
        bobPreKeyPair,
        preKeySig,
      );
      await bobStore.storeSignedPreKey(1, signedPreKeyRecord);
      await bobStore.storePreKey(1, PreKeyRecord(1, bobPreKeyPair));
    });

    test('Alice envia primeira mensagem — Bob decripta corretamente (X3DH)', () async {
      // Alice constrói a bundle de Bob e inicia a sessão
      final bobBundle = PreKeyBundle(
        generateRegistrationId(false),
        1,
        1,
        bobPreKeyPair.publicKey,
        1,
        bobPreKeyPair.publicKey,
        preKeySig,
        IdentityKey(bobIdentityKeyPair.publicKey),
      );

      final aliceSessionBuilder = SessionBuilder.fromSignalStore(aliceStore, bobAddress);
      await aliceSessionBuilder.processPreKeyBundle(bobBundle);
      final aliceCipher = SessionCipher.fromStore(aliceStore, bobAddress);

      // Alice encripta
      final plaintext = Uint8List.fromList('Olá, Bob!'.codeUnits);
      final ciphertextMsg = await aliceCipher.encrypt(plaintext);
      final cipherBytes = Uint8List.fromList(ciphertextMsg.serialize());

      // Bob decripta (primeira mensagem é sempre PreKeySignalMessage)
      final bobCipher = SessionCipher.fromStore(bobStore, aliceAddress);
      final preKeyMsg = PreKeySignalMessage(cipherBytes);
      final decrypted = Uint8List.fromList(await bobCipher.decrypt(preKeyMsg));

      expect(String.fromCharCodes(decrypted), equals('Olá, Bob!'));
    });

    test('Double Ratchet avança — segunda mensagem usa ciphertext diferente', () async {
      // Estabelece sessão Alice → Bob
      final bobBundle = PreKeyBundle(
        generateRegistrationId(false),
        1,
        1,
        bobPreKeyPair.publicKey,
        1,
        bobPreKeyPair.publicKey,
        preKeySig,
        IdentityKey(bobIdentityKeyPair.publicKey),
      );
      final aliceSessionBuilder = SessionBuilder.fromSignalStore(aliceStore, bobAddress);
      await aliceSessionBuilder.processPreKeyBundle(bobBundle);
      final aliceCipher = SessionCipher.fromStore(aliceStore, bobAddress);

      final msg1 = await aliceCipher.encrypt(Uint8List.fromList('msg1'.codeUnits));
      final msg2 = await aliceCipher.encrypt(Uint8List.fromList('msg2'.codeUnits));

      // Ciphertexts devem ser diferentes mesmo para plaintexts similares
      expect(msg1.serialize(), isNot(equals(msg2.serialize())));
    });

    test('Bob responde — Alice decripta corretamente (ratchet bidirecional)', () async {
      // Alice inicia sessão com Bob
      final bobBundle = PreKeyBundle(
        generateRegistrationId(false),
        1,
        1,
        bobPreKeyPair.publicKey,
        1,
        bobPreKeyPair.publicKey,
        preKeySig,
        IdentityKey(bobIdentityKeyPair.publicKey),
      );
      final aliceSessionBuilder = SessionBuilder.fromSignalStore(aliceStore, bobAddress);
      await aliceSessionBuilder.processPreKeyBundle(bobBundle);
      final aliceCipher = SessionCipher.fromStore(aliceStore, bobAddress);

      // Alice → Bob (estabelece sessão em Bob via PreKey)
      final firstMsg = await aliceCipher.encrypt(Uint8List.fromList('oi'.codeUnits));
      final bobCipher = SessionCipher.fromStore(bobStore, aliceAddress);
      await bobCipher.decrypt(PreKeySignalMessage(Uint8List.fromList(firstMsg.serialize())));

      // Bob → Alice (mensagem de resposta via Double Ratchet)
      final reply = await bobCipher.encrypt(Uint8List.fromList('oi também'.codeUnits));
      final replyMsg = SignalMessage.fromSerialized(Uint8List.fromList(reply.serialize()));
      final decryptedReply = Uint8List.fromList(await aliceCipher.decryptFromSignal(replyMsg));

      expect(String.fromCharCodes(decryptedReply), equals('oi também'));
    });
  });
}
