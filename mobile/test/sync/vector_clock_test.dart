import 'package:flutter_test/flutter_test.dart';
import 'package:safechannel/sync/vector_clock.dart';

void main() {
  group('VectorClock', () {
    test('increment retorna novo clock com contador incrementado', () {
      final vc = VectorClock({'a': 1, 'b': 2});
      final next = vc.increment('a');
      expect(next.toMap(), equals({'a': 2, 'b': 2}));
      // original imutável
      expect(vc.toMap(), equals({'a': 1, 'b': 2}));
    });

    test('increment cria entrada para userId ausente', () {
      final next = VectorClock({}).increment('x');
      expect(next['x'], equals(1));
    });

    test('merge retorna novo clock com maior valor por userId', () {
      final local = VectorClock({'a': 3, 'b': 1});
      final remote = VectorClock({'a': 1, 'b': 5, 'c': 2});
      final merged = local.merge(remote);
      expect(merged.toMap(), equals({'a': 3, 'b': 5, 'c': 2}));
    });

    test('happensBefore retorna true quando A < B em todos os campos', () {
      final a = VectorClock({'a': 1, 'b': 2});
      final b = VectorClock({'a': 3, 'b': 4});
      expect(a.happensBefore(b), isTrue);
      expect(b.happensBefore(a), isFalse);
    });

    test('happensBefore retorna false para clocks iguais', () {
      final a = VectorClock({'a': 1, 'b': 1});
      final b = VectorClock({'a': 1, 'b': 1});
      expect(a.happensBefore(b), isFalse);
    });

    test('isConcurrentWith retorna true para clocks concorrentes', () {
      final a = VectorClock({'a': 2, 'b': 1});
      final b = VectorClock({'a': 1, 'b': 2});
      expect(a.isConcurrentWith(b), isTrue);
    });
  });
}
