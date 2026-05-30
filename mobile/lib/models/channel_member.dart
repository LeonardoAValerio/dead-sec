import 'dart:convert';
import 'dart:typed_data';

enum MemberRole { admin, member }

class ChannelMember {
  final String channelId;
  final String userId;
  final Uint8List publicKey;
  final MemberRole role;
  final DateTime joinedAt;
  final Map<String, int> vectorClock;

  const ChannelMember({
    required this.channelId,
    required this.userId,
    required this.publicKey,
    required this.role,
    required this.joinedAt,
    required this.vectorClock,
  });

  Map<String, dynamic> toMap() => {
        'channel_id': channelId,
        'user_id': userId,
        'public_key': publicKey,
        'role': role.name,
        'joined_at': joinedAt.millisecondsSinceEpoch,
        'vector_clock': jsonEncode(vectorClock),
      };

  factory ChannelMember.fromMap(Map<String, dynamic> m) => ChannelMember(
        channelId: m['channel_id'] as String,
        userId: m['user_id'] as String,
        publicKey: m['public_key'] as Uint8List,
        role: m['role'] == 'admin' ? MemberRole.admin : MemberRole.member,
        joinedAt: DateTime.fromMillisecondsSinceEpoch(m['joined_at'] as int),
        vectorClock: Map<String, int>.from(
          jsonDecode(m['vector_clock'] as String? ?? '{}') as Map,
        ),
      );
}
