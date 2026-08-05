import 'dart:convert';
import 'dart:typed_data';

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

  /// Remove registros de channel_members com a mesma [publicKey] mas [userId] diferente.
  /// Usado para limpar o placeholder 'peer-<channelId>' criado no join via QR antes de
  /// persistir o registro com o userId real recebido via MEMBER_INFO.
  Future<void> deleteMemberByPublicKey(
    String channelId,
    Uint8List publicKey, {
    String? exceptUserId,
  }) async {
    final where = exceptUserId != null
        ? 'channel_id = ? AND public_key = ? AND user_id != ?'
        : 'channel_id = ? AND public_key = ?';
    final args = exceptUserId != null
        ? [channelId, publicKey, exceptUserId]
        : [channelId, publicKey];
    await _db.delete('channel_members', where: where, whereArgs: args);
  }

  Future<void> deleteChannel(String id) async {
    await _db.delete('channels', where: 'id = ?', whereArgs: [id]);
  }
}
