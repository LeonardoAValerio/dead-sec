/// Relógio vetorial para ordenação causal de mensagens (SPEC-SYNC-002).
///
/// Cada entrada mapeia userId → contador de mensagens enviadas por aquele peer.
/// Permite determinar se uma mensagem é nova, antiga ou concorrente.
class VectorClock {
  final Map<String, int> _clock;

  VectorClock([Map<String, int>? initial]) : _clock = Map.from(initial ?? {});

  /// Incrementa o contador do peer local ao enviar uma mensagem.
  VectorClock increment(String userId) {
    final next = Map<String, int>.from(_clock);
    next[userId] = (_clock[userId] ?? 0) + 1;
    return VectorClock(next);
  }

  /// Merge: para cada peer, mantém o maior contador conhecido.
  VectorClock merge(VectorClock other) {
    final merged = Map<String, int>.from(_clock);
    for (final entry in other._clock.entries) {
      final current = merged[entry.key] ?? 0;
      if (entry.value > current) merged[entry.key] = entry.value;
    }
    return VectorClock(merged);
  }

  int operator [](String userId) => _clock[userId] ?? 0;

  Map<String, int> toMap() => Map.unmodifiable(_clock);

  /// Retorna true se este clock está estritamente antes do [other].
  bool happensBefore(VectorClock other) {
    bool atLeastOneLess = false;
    for (final userId in {..._clock.keys, ...other._clock.keys}) {
      final a = _clock[userId] ?? 0;
      final b = other._clock[userId] ?? 0;
      if (a > b) return false;
      if (a < b) atLeastOneLess = true;
    }
    return atLeastOneLess;
  }

  /// Retorna true se os clocks são concorrentes (nenhum acontece antes do outro).
  bool isConcurrentWith(VectorClock other) =>
      !happensBefore(other) && !other.happensBefore(this) && _clock != other._clock;

  @override
  String toString() => _clock.toString();
}
