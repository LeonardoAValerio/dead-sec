import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../webrtc/peer_connection_manager.dart';

/// Ícone de cadeado que reflete o estado da conexão P2P (SPEC-UI-001).
class ConnectionIndicatorWidget extends StatelessWidget {
  final ConnectionIndicator state;

  const ConnectionIndicatorWidget({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_icon, color: _color, size: 16),
        const SizedBox(width: 4),
        Text(_label, style: TextStyle(color: _color, fontSize: 12)),
      ],
    );
  }

  IconData get _icon => switch (state) {
        ConnectionIndicator.p2pDirect => Icons.lock,
        ConnectionIndicator.turnRelay => Icons.lock_outline,
        ConnectionIndicator.offline => Icons.lock_open,
      };

  Color get _color => switch (state) {
        ConnectionIndicator.p2pDirect => AppColors.p2pGreen,
        ConnectionIndicator.turnRelay => AppColors.turnYellow,
        ConnectionIndicator.offline => AppColors.offlineGrey,
      };

  String get _label => switch (state) {
        ConnectionIndicator.p2pDirect => 'P2P',
        ConnectionIndicator.turnRelay => 'Relay',
        ConnectionIndicator.offline => 'Offline',
      };
}
