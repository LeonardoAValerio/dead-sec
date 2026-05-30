import 'dart:typed_data';

class User {
  final String id;
  final String displayName;
  final Uint8List identityPublicKey;
  final Uint8List signedPreKeyPublic;
  final DateTime createdAt;

  const User({
    required this.id,
    required this.displayName,
    required this.identityPublicKey,
    required this.signedPreKeyPublic,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'display_name': displayName,
        'identity_public_key': identityPublicKey,
        'signed_pre_key_public': signedPreKeyPublic,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory User.fromMap(Map<String, dynamic> m) => User(
        id: m['id'] as String,
        displayName: m['display_name'] as String,
        identityPublicKey: m['identity_public_key'] as Uint8List,
        signedPreKeyPublic: m['signed_pre_key_public'] as Uint8List,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
}
