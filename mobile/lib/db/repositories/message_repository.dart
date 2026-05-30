import 'package:sqflite_common/sqlite_api.dart';

import '../../models/message.dart';
import '../../models/message_status.dart';

class MessageRepository {
  final Database _db;
  MessageRepository(this._db);

  Future<void> save(Message message) async {
    await _db.insert('messages', message.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Message>> getByChannel(String channelId, {int limit = 50, int offset = 0}) async {
    final rows = await _db.query(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'timestamp ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Message.fromMap).toList();
  }

  Future<List<Message>> getPending() async {
    final rows = await _db.query(
      'messages',
      where: 'status = ?',
      whereArgs: [MessageStatus.pending.name],
      orderBy: 'timestamp ASC',
    );
    return rows.map(Message.fromMap).toList();
  }

  /// Retorna mensagens enviadas após o estado descrito pelo [vectorClock] do peer.
  /// Usado no delta sync (SPEC-SYNC-001).
  Future<List<Message>> getMessagesSince(String channelId, Map<String, int> peerVectorClock) async {
    final all = await getByChannel(channelId, limit: 1000);
    return all.where((m) {
      final myCount = m.vectorClock[m.senderId] ?? 0;
      final peerCount = peerVectorClock[m.senderId] ?? 0;
      return myCount > peerCount;
    }).toList();
  }

  Future<void> updateStatus(String messageId, MessageStatus status) async {
    await _db.update(
      'messages',
      {'status': status.name},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<bool> exists(String messageId) async {
    final rows = await _db.query('messages', where: 'id = ?', whereArgs: [messageId], limit: 1);
    return rows.isNotEmpty;
  }
}
