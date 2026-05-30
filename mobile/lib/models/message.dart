import 'dart:convert';
import 'dart:typed_data';

import 'message_status.dart';
import 'message_type.dart';

class Message {
  final String id;
  final String channelId;
  final String senderId;
  final MessageType type;
  final Uint8List payload;
  final MessageMetadata? metadata;
  final DateTime timestamp;
  final Map<String, int> vectorClock;
  final Uint8List signature;
  final MessageStatus status;

  const Message({
    required this.id,
    required this.channelId,
    required this.senderId,
    required this.type,
    required this.payload,
    this.metadata,
    required this.timestamp,
    required this.vectorClock,
    required this.signature,
    required this.status,
  });

  Message copyWith({MessageStatus? status}) => Message(
        id: id,
        channelId: channelId,
        senderId: senderId,
        type: type,
        payload: payload,
        metadata: metadata,
        timestamp: timestamp,
        vectorClock: vectorClock,
        signature: signature,
        status: status ?? this.status,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'channel_id': channelId,
        'sender_id': senderId,
        'type': type.name,
        'payload': payload,
        'metadata': metadata != null ? jsonEncode(metadata!.toMap()) : null,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'vector_clock': jsonEncode(vectorClock),
        'signature': signature,
        'status': status.name,
      };

  factory Message.fromMap(Map<String, dynamic> m) => Message(
        id: m['id'] as String,
        channelId: m['channel_id'] as String,
        senderId: m['sender_id'] as String,
        type: MessageType.fromString(m['type'] as String),
        payload: m['payload'] as Uint8List,
        metadata: m['metadata'] != null
            ? MessageMetadata.fromMap(
                Map<String, dynamic>.from(jsonDecode(m['metadata'] as String) as Map))
            : null,
        timestamp: DateTime.fromMillisecondsSinceEpoch(m['timestamp'] as int),
        vectorClock: Map<String, int>.from(
          jsonDecode(m['vector_clock'] as String? ?? '{}') as Map,
        ),
        signature: m['signature'] as Uint8List,
        status: MessageStatus.fromString(m['status'] as String),
      );
}

class MessageMetadata {
  final String mimeType;
  final String? fileName;
  final int sizeBytes;
  final Uint8List? thumbnail;
  final int? durationMs;
  final int? width;
  final int? height;

  const MessageMetadata({
    required this.mimeType,
    this.fileName,
    required this.sizeBytes,
    this.thumbnail,
    this.durationMs,
    this.width,
    this.height,
  });

  Map<String, dynamic> toMap() => {
        'mime_type': mimeType,
        'file_name': fileName,
        'size_bytes': sizeBytes,
        'duration_ms': durationMs,
        'width': width,
        'height': height,
      };

  factory MessageMetadata.fromMap(Map<String, dynamic> m) => MessageMetadata(
        mimeType: m['mime_type'] as String,
        fileName: m['file_name'] as String?,
        sizeBytes: m['size_bytes'] as int,
        durationMs: m['duration_ms'] as int?,
        width: m['width'] as int?,
        height: m['height'] as int?,
      );
}
