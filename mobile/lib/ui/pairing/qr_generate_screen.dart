import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../db/repositories/channel_repository.dart';
import '../../models/channel.dart';
import '../../models/user.dart';
import '../../webrtc/pairing_service.dart';

/// Tela que exibe o QR Code de convite para um canal.
/// O QR expira em 5 minutos (SPEC-CHAN-001).
class QrGenerateScreen extends StatefulWidget {
  final Database db;
  final User currentUser;
  final String channelName;

  const QrGenerateScreen({
    super.key,
    required this.db,
    required this.currentUser,
    required this.channelName,
  });

  @override
  State<QrGenerateScreen> createState() => _QrGenerateScreenState();
}

class _QrGenerateScreenState extends State<QrGenerateScreen> {
  Channel? _channel;
  String? _qrData;
  int _secondsLeft = 300; // 5 minutos
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    final service = PairingService(channelRepo: ChannelRepository(widget.db));
    final result = await service.createChannel(widget.channelName, widget.currentUser.id);

    setState(() {
      _channel = result.channel;
      _qrData = result.qr.encode();
      _secondsLeft = 300;
    });

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        t.cancel();
        setState(() => _qrData = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('Convidar por QR Code', style: TextStyle(color: AppColors.onSurface)),
        iconTheme: const IconThemeData(color: AppColors.onSurface),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_qrData != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(data: _qrData!, size: 220),
                ),
                const SizedBox(height: 20),
                Text(
                  'Expira em ${_secondsLeft}s',
                  style: TextStyle(
                    color: _secondsLeft < 60 ? Colors.redAccent : AppColors.subtle,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _channel?.name ?? '',
                  style: const TextStyle(color: AppColors.onSurface, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ] else ...[
                const Icon(Icons.qr_code_2, size: 80, color: AppColors.subtle),
                const SizedBox(height: 16),
                const Text('QR expirado.', style: TextStyle(color: AppColors.subtle)),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _generate,
                  style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
                  child: const Text('Gerar novo QR'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
