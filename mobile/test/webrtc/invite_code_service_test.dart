import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safechannel/webrtc/invite_code_service.dart';
import 'package:safechannel/webrtc/pairing_service.dart';

QrPayload _fakePayload({int expiresAt = 0}) => QrPayload(
      channelId: 'channel-123',
      channelName: 'Teste',
      creatorPublicKey: Uint8List(32),
      signedPreKey: Uint8List(32),
      expiresAt: expiresAt,
      signalIdentityKey: Uint8List(32),
      preKeySignature: Uint8List(64),
    );

void main() {
  group('InviteCodeService — encode/decode', () {
    test('encode e decode sem senha retorna payload original', () async {
      final original = _fakePayload();
      final code = InviteCodeService.generate(original);
      final decoded = await InviteCodeService.decode(code);

      expect(decoded, isNotNull);
      expect(decoded!.channelId, equals(original.channelId));
      expect(decoded.channelName, equals(original.channelName));
    });

    test('encode e decode com senha correta retorna payload original', () async {
      final original = _fakePayload();
      final code = InviteCodeService.generate(original, password: 'senha_segura_123');
      final decoded = await InviteCodeService.decode(code, password: 'senha_segura_123');

      expect(decoded, isNotNull);
      expect(decoded!.channelId, equals(original.channelId));
    });

    test('decode com senha errada retorna null', () async {
      final code = InviteCodeService.generate(_fakePayload(), password: 'correta');
      final decoded = await InviteCodeService.decode(code, password: 'errada');
      expect(decoded, isNull);
    });

    test('decode sem senha quando código é protegido retorna null', () async {
      final code = InviteCodeService.generate(_fakePayload(), password: 'tem_senha');
      final decoded = await InviteCodeService.decode(code);
      expect(decoded, isNull);
    });

    test('invite codes nunca expiram (diferente dos QR codes de 5min)', () async {
      // QrPayload com expiresAt passado → invite code ignora expiração por design.
      // Isso permite compartilhar o código por mensagem sem prazo de validade.
      final withPastExpiry = _fakePayload(
        expiresAt: DateTime.now().subtract(const Duration(minutes: 10)).millisecondsSinceEpoch,
      );
      final code = InviteCodeService.generate(withPastExpiry);
      final decoded = await InviteCodeService.decode(code);
      expect(decoded, isNotNull); // invite code não expira — expiresAt=0 no decode
    });

    test('expiresAt == 0 nunca expira', () async {
      final noExpiry = _fakePayload(expiresAt: 0);
      final code = InviteCodeService.generate(noExpiry);
      final decoded = await InviteCodeService.decode(code);
      expect(decoded, isNotNull);
    });

    test('código inválido (texto aleatório) retorna null', () async {
      final decoded = await InviteCodeService.decode('nao_e_um_codigo_valido!!!');
      expect(decoded, isNull);
    });
  });

  group('Validação de senha (SPEC-CHAN-002)', () {
    // A regra de senha mínima de 8 chars é aplicada na camada de UI
    // (CreateChannelScreen e JoinCodeScreen) antes de chamar InviteCodeService.
    // Estes testes verificam a lógica da regra isolada.

    bool isSenhaValida(String senha) => senha.isEmpty || senha.length >= 8;

    test('senha vazia é válida (campo opcional)', () {
      expect(isSenhaValida(''), isTrue);
    });

    test('senha com 7 chars é inválida', () {
      expect(isSenhaValida('1234567'), isFalse);
    });

    test('senha com 8 chars é válida', () {
      expect(isSenhaValida('12345678'), isTrue);
    });

    test('senha com mais de 8 chars é válida', () {
      expect(isSenhaValida('minha_senha_segura'), isTrue);
    });
  });
}
