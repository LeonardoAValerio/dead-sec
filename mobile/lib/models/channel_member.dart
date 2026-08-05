import 'dart:convert';
import 'dart:typed_data';

enum MemberRole { admin, member }

class ChannelMember {
  final String channelId;
  final String userId;
  final String displayName;
  final Uint8List publicKey;
  final MemberRole role;
  final DateTime joinedAt;
  final Map<String, int> vectorClock;
  // Chaves Signal do peer — preenchidas ao ingressar via QR/invite code.
  final Uint8List? signalKey;        // X25519 signal identity key (para X3DH)
  final Uint8List? signalPreKey;     // X25519 signed pre-key
  final Uint8List? signalPreKeySig;  // Assinatura da pre-key — exigida pelo X3DH

  const ChannelMember({
    required this.channelId,
    required this.userId,
    this.displayName = '',
    required this.publicKey,
    required this.role,
    required this.joinedAt,
    required this.vectorClock,
    this.signalKey,
    this.signalPreKey,
    this.signalPreKeySig,
  });

  Map<String, dynamic> toMap() => {
        'channel_id': channelId,
        'user_id': userId,
        'display_name': displayName,
        'public_key': publicKey,
        'role': role.name,
        'joined_at': joinedAt.millisecondsSinceEpoch,
        'vector_clock': jsonEncode(vectorClock),
        'signal_key': signalKey,
        'signal_pre_key': signalPreKey,
        'signal_pre_key_sig': signalPreKeySig,
      };

  factory ChannelMember.fromMap(Map<String, dynamic> m) => ChannelMember(
        channelId: m['channel_id'] as String,
        userId: m['user_id'] as String,
        displayName: m['display_name'] as String? ?? '',
        publicKey: m['public_key'] as Uint8List,
        role: m['role'] == 'admin' ? MemberRole.admin : MemberRole.member,
        joinedAt: DateTime.fromMillisecondsSinceEpoch(m['joined_at'] as int),
        vectorClock: Map<String, int>.from(
          jsonDecode(m['vector_clock'] as String? ?? '{}') as Map,
        ),
        signalKey: m['signal_key'] as Uint8List?,
        signalPreKey: m['signal_pre_key'] as Uint8List?,
        signalPreKeySig: m['signal_pre_key_sig'] as Uint8List?,
      );
}
