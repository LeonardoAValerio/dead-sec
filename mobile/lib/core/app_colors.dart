import 'package:flutter/material.dart';

abstract final class AppColors {
  static const primary = Color(0xFF1A73E8);
  static const surface = Color(0xFF1E1E2E);
  static const background = Color(0xFF13131F);
  static const onSurface = Color(0xFFE8E8F0);
  static const subtle = Color(0xFF6B6B80);

  // Indicadores de conexão (SPEC-UI-001)
  static const p2pGreen = Color(0xFF34A853);
  static const turnYellow = Color(0xFFFBBC04);
  static const offlineGrey = Color(0xFF9AA0A6);

  // Status de mensagem
  static const messageSent = Color(0xFF9AA0A6);
  static const messageDelivered = Color(0xFF9AA0A6);
  static const messageRead = Color(0xFF1A73E8);
}
