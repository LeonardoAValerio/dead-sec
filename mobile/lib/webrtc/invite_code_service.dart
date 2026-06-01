import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import 'pairing_service.dart';

/// Gera e decodifica códigos de convite de texto para ingresso em canais.
///
/// Alternativa ao QR Code (CLAUDE.md prioridade 2 — "Senha pré-combinada").
/// Sem senha: payload JSON base64url simples.
/// Com senha: payload interno criptografado AES-256-GCM, chave via Argon2id (SPEC-CHAN-002).
class InviteCodeService {
  static const _argon2Memory = 65536; // 64 MB
  static const _argon2Iterations = 3;
  static const _argon2Lanes = 4;

  /// Gera um código de convite a partir de um [QrPayload].
  /// O código não tem expiração (diferente do QR de 5 min).
  static String generate(QrPayload qr, {String? password}) {
    final inner = {
      'cid': qr.channelId,
      'name': qr.channelName,
      'pk': base64Encode(qr.creatorPublicKey),
      'spk': base64Encode(qr.signedPreKey),
      if (qr.signalIdentityKey != null) 'sik': base64Encode(qr.signalIdentityKey!),
      if (qr.preKeySignature != null) 'spksig': base64Encode(qr.preKeySignature!),
    };

    if (password == null || password.isEmpty) {
      return base64Url.encode(utf8.encode(jsonEncode({'v': 1, 'enc': false, ...inner})));
    }

    final rng = Random.secure();
    final salt = Uint8List(16);
    final iv = Uint8List(12);
    for (var i = 0; i < 16; i++) { salt[i] = rng.nextInt(256); }
    for (var i = 0; i < 12; i++) { iv[i] = rng.nextInt(256); }

    final key = _deriveKey(password, salt);
    final ciphertext = _encryptGcm(key, iv, Uint8List.fromList(utf8.encode(jsonEncode(inner))));

    return base64Url.encode(utf8.encode(jsonEncode({
      'v': 1,
      'enc': true,
      'salt': base64Encode(salt),
      'iv': base64Encode(iv),
      'data': base64Encode(ciphertext),
    })));
  }

  /// Decodifica um código de convite. Retorna null se inválido ou senha errada.
  static Future<QrPayload?> decode(String code, {String? password}) async {
    try {
      final outer = jsonDecode(utf8.decode(base64Url.decode(code))) as Map<String, dynamic>;
      if (outer['v'] != 1) return null;

      final Map<String, dynamic> inner;
      if (outer['enc'] == true) {
        if (password == null || password.isEmpty) return null;
        final salt = base64Decode(outer['salt'] as String);
        final iv = base64Decode(outer['iv'] as String);
        final ciphertext = base64Decode(outer['data'] as String);
        final key = _deriveKey(password, Uint8List.fromList(salt));
        final plaintext = _decryptGcm(key, Uint8List.fromList(iv), Uint8List.fromList(ciphertext));
        inner = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      } else {
        inner = outer;
      }

      return QrPayload(
        channelId: inner['cid'] as String,
        channelName: inner['name'] as String,
        creatorPublicKey: base64Decode(inner['pk'] as String),
        signedPreKey: base64Decode(inner['spk'] as String),
        expiresAt: 0, // códigos de convite não expiram
        signalIdentityKey: inner['sik'] != null
            ? base64Decode(inner['sik'] as String)
            : null,
        preKeySignature: inner['spksig'] != null
            ? base64Decode(inner['spksig'] as String)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _encryptGcm(Uint8List key, Uint8List iv, Uint8List plaintext) {
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(true, pc.AEADParameters(pc.KeyParameter(key), 128, iv, Uint8List(0)));
    final output = Uint8List(cipher.getOutputSize(plaintext.length));
    final len = cipher.processBytes(plaintext, 0, plaintext.length, output, 0);
    // doFinal retorna quantos bytes adicionais foram escritos (bloco final + tag GCM).
    // Retornar sublist para não incluir bytes zerados além do que foi realmente escrito.
    final remaining = cipher.doFinal(output, len);
    return output.sublist(0, len + remaining);
  }

  static Uint8List _decryptGcm(Uint8List key, Uint8List iv, Uint8List ciphertext) {
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(false, pc.AEADParameters(pc.KeyParameter(key), 128, iv, Uint8List(0)));
    final output = Uint8List(cipher.getOutputSize(ciphertext.length));
    final len = cipher.processBytes(ciphertext, 0, ciphertext.length, output, 0);
    final remaining = cipher.doFinal(output, len);
    return output.sublist(0, len + remaining);
  }

  static Uint8List _deriveKey(String password, Uint8List salt) {
    final params = pc.Argon2Parameters(
      pc.Argon2Parameters.ARGON2_id,
      salt,
      desiredKeyLength: 32,
      iterations: _argon2Iterations,
      memory: _argon2Memory,
      lanes: _argon2Lanes,
    );
    final generator = pc.Argon2BytesGenerator()..init(params);
    final key = Uint8List(32);
    generator.deriveKey(Uint8List.fromList(utf8.encode(password)), 0, key, 0);
    return key;
  }
}
