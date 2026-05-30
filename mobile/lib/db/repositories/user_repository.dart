import 'package:sqflite_common/sqlite_api.dart';

import '../../models/user.dart';

class UserRepository {
  final Database _db;
  UserRepository(this._db);

  Future<void> save(User user) async {
    await _db.insert('users', user.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<User?> findFirst() async {
    final rows = await _db.query('users', limit: 1);
    return rows.isEmpty ? null : User.fromMap(rows.first);
  }

  Future<User?> findById(String id) async {
    final rows = await _db.query('users', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : User.fromMap(rows.first);
  }
}
