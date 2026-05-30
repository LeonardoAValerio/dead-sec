import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../../models/channel.dart';
import '../../models/channel_member.dart';

class ChannelRepository {
  final Database _db;
  ChannelRepository(this._db);

  Future<void> saveChannel(Channel channel) async {
    await _db.insert('channels', channel.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Channel?> findById(String id) async {
    final rows = await _db.query('channels', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Channel.fromMap(rows.first);
  }

  Future<List<Channel>> getAll() async {
    final rows = await _db.query('channels', orderBy: 'created_at ASC');
    return rows.map(Channel.fromMap).toList();
  }

  Future<void> saveMember(ChannelMember member) async {
    await _db.insert('channel_members', member.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ChannelMember>> getMembers(String channelId) async {
    final rows = await _db.query('channel_members', where: 'channel_id = ?', whereArgs: [channelId]);
    return rows.map(ChannelMember.fromMap).toList();
  }

  Future<ChannelMember?> getMember(String channelId, String userId) async {
    final rows = await _db.query(
      'channel_members',
      where: 'channel_id = ? AND user_id = ?',
      whereArgs: [channelId, userId],
    );
    return rows.isEmpty ? null : ChannelMember.fromMap(rows.first);
  }

  Future<void> updateMemberVectorClock(String channelId, String userId, Map<String, int> vc) async {
    await _db.update(
      'channel_members',
      {'vector_clock': jsonEncode(vc)},
      where: 'channel_id = ? AND user_id = ?',
      whereArgs: [channelId, userId],
    );
  }
}
