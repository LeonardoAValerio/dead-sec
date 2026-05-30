import 'dart:convert';

import 'package:http/http.dart' as http;

class TurnCredentials {
  final String username;
  final String password;
  final int ttlSeconds;

  const TurnCredentials({
    required this.username,
    required this.password,
    required this.ttlSeconds,
  });
}

/// Busca credenciais TURN temporárias do servidor (SPEC-TURN-002).
/// Credenciais expiram em ~10 minutos — nunca embutidas no app.
class TurnCredentialsService {
  final String serverUrl;
  final String jwtToken;

  TurnCredentials? _cached;
  DateTime? _cachedAt;

  TurnCredentialsService({required this.serverUrl, required this.jwtToken});

  Future<TurnCredentials> fetch() async {
    // Reusa credenciais se ainda têm mais de 2 minutos de vida
    if (_cached != null && _cachedAt != null) {
      final age = DateTime.now().difference(_cachedAt!).inSeconds;
      if (age < (_cached!.ttlSeconds - 120)) return _cached!;
    }

    final resp = await http.get(
      Uri.parse('$serverUrl/turn/credentials'),
      headers: {'Authorization': 'Bearer $jwtToken'},
    );

    if (resp.statusCode != 200) {
      throw Exception('Failed to fetch TURN credentials: ${resp.statusCode}');
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    _cached = TurnCredentials(
      username: json['username'] as String,
      password: json['password'] as String,
      ttlSeconds: int.tryParse(json['ttl'] as String? ?? '600') ?? 600,
    );
    _cachedAt = DateTime.now();
    return _cached!;
  }
}
