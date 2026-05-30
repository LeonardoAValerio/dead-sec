import 'dart:typed_data';

class Channel {
  final String id;
  final String name;
  final Uint8List channelKey;
  final String inviteSecretHash;
  final String createdBy;
  final DateTime createdAt;
  final ChannelSettings settings;

  const Channel({
    required this.id,
    required this.name,
    required this.channelKey,
    required this.inviteSecretHash,
    required this.createdBy,
    required this.createdAt,
    required this.settings,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'channel_key': channelKey,
        'invite_secret_hash': inviteSecretHash,
        'created_by': createdBy,
        'created_at': createdAt.millisecondsSinceEpoch,
        'auto_delete_seconds': settings.autoDeleteSeconds,
        'max_members': settings.maxMembers,
        'allow_media': settings.allowMedia ? 1 : 0,
      };

  factory Channel.fromMap(Map<String, dynamic> m) => Channel(
        id: m['id'] as String,
        name: m['name'] as String,
        channelKey: m['channel_key'] as Uint8List,
        inviteSecretHash: m['invite_secret_hash'] as String,
        createdBy: m['created_by'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        settings: ChannelSettings(
          autoDeleteSeconds: m['auto_delete_seconds'] as int?,
          maxMembers: m['max_members'] as int? ?? 50,
          allowMedia: (m['allow_media'] as int? ?? 1) == 1,
        ),
      );
}

class ChannelSettings {
  final int? autoDeleteSeconds;
  final int maxMembers;
  final bool allowMedia;

  const ChannelSettings({
    this.autoDeleteSeconds,
    this.maxMembers = 50,
    this.allowMedia = true,
  });
}
