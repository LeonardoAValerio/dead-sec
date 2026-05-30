import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../models/message_status.dart';

/// Ícone de status da mensagem: ⟳ ✓ ✓✓ ✓✓azul
class MessageStatusIcon extends StatelessWidget {
  final MessageStatus status;

  const MessageStatusIcon({super.key, required this.status});

  @override
  Widget build(BuildContext context) => switch (status) {
        MessageStatus.pending => const Icon(Icons.access_time, size: 14, color: AppColors.messageSent),
        MessageStatus.sent => const Icon(Icons.check, size: 14, color: AppColors.messageSent),
        MessageStatus.delivered => const Icon(Icons.done_all, size: 14, color: AppColors.messageDelivered),
        MessageStatus.read => const Icon(Icons.done_all, size: 14, color: AppColors.messageRead),
      };
}
