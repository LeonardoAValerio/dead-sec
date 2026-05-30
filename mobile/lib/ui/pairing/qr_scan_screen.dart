import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../db/repositories/channel_repository.dart';
import '../../models/channel.dart';
import '../../models/user.dart';
import '../../webrtc/pairing_service.dart';

/// Tela de escaneamento de QR Code para entrar em um canal.
class QrScanScreen extends StatefulWidget {
  final Database db;
  final User currentUser;
  final void Function(Channel channel) onJoined;

  const QrScanScreen({
    super.key,
    required this.db,
    required this.currentUser,
    required this.onJoined,
  });

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _processing = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('Escanear QR Code', style: TextStyle(color: AppColors.onSurface)),
        iconTheme: const IconThemeData(color: AppColors.onSurface),
      ),
      body: Platform.isLinux || Platform.isMacOS || Platform.isWindows
          ? const Center(
              child: Text(
                'Escaneamento de QR Code não disponível no desktop.\nUse a opção de digitar a senha do canal.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.subtle),
              ),
            )
          : Stack(
        children: [
          MobileScanner(
            onDetect: _onDetect,
          ),
          // Overlay de scan
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.primary, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          if (_processing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: AppColors.primary),
                    SizedBox(height: 16),
                    Text('Conectando...', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          if (_error != null)
            Positioned(
              bottom: 32,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_error!, style: const TextStyle(color: Colors.white)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;

    setState(() {
      _processing = true;
      _error = null;
    });

    try {
      final service = PairingService(channelRepo: ChannelRepository(widget.db));
      final result = await service.joinViaQr(raw, widget.currentUser.id);

      if (result == null) {
        setState(() => _error = 'QR Code inválido ou expirado.');
        return;
      }

      widget.onJoined(result);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      setState(() => _error = 'Erro ao processar QR Code.');
    } finally {
      setState(() => _processing = false);
    }
  }
}
