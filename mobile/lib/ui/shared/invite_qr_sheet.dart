import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../db/repositories/channel_repository.dart';
import '../../models/channel.dart';
import '../../models/user.dart';
import '../../webrtc/invite_code_service.dart';
import '../../webrtc/pairing_service.dart';

/// Bottom sheet que exibe QR de convite + código de texto para um canal existente.
/// QR expira em 5 minutos; código de texto não tem expiração.
class InviteQrSheet extends StatefulWidget {
  final Database db;
  final User currentUser;
  final Channel channel;

  const InviteQrSheet({
    super.key,
    required this.db,
    required this.currentUser,
    required this.channel,
  });

  static Future<void> show(BuildContext context, Database db, User user, Channel channel) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => InviteQrSheet(db: db, currentUser: user, channel: channel),
    );
  }

  @override
  State<InviteQrSheet> createState() => _InviteQrSheetState();
}

class _InviteQrSheetState extends State<InviteQrSheet> {
  static const _totalSeconds = 300;

  String? _qrData;
  String? _inviteCode;
  int _secondsLeft = _totalSeconds;
  Timer? _timer;
  bool _loading = true;
  String? _error;
  bool _copied = false;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    _timer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _secondsLeft = _totalSeconds;
    });

    try {
      final service = PairingService(channelRepo: ChannelRepository(widget.db));
      final qr = await service.generateInviteQr(widget.channel);
      final code = InviteCodeService.generate(qr);

      setState(() {
        _qrData = qr.encode();
        _inviteCode = code;
        _loading = false;
      });

      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _secondsLeft--;
          if (_secondsLeft <= 0) {
            t.cancel();
            _qrData = null;
          }
        });
      });
    } catch (e) {
      setState(() {
        _error = 'Erro ao gerar convite: $e';
        _loading = false;
      });
    }
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: _inviteCode!));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  String _formatTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => ListView(
        controller: scrollCtrl,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: AppColors.subtle,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            'Convidar para ${widget.channel.name}',
            style: const TextStyle(
              color: AppColors.onSurface,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            )
          else if (_error != null)
            Center(
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            )
          else if (_qrData == null)
            _buildExpired()
          else
            _buildContent(),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final expired = _secondsLeft <= 0;
    final timeColor = _secondsLeft < 60 ? Colors.redAccent : AppColors.subtle;

    return Column(
      children: [
        if (!_isDesktop) ...[
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: _qrData!, size: 220),
          ),
          const SizedBox(height: 12),
          Text(
            expired ? 'QR expirado' : 'QR expira em ${_formatTime(_secondsLeft)}',
            style: TextStyle(color: timeColor, fontSize: 13),
          ),
          const SizedBox(height: 24),
        ],
        const Text(
          'Código de convite',
          style: TextStyle(color: AppColors.subtle, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            _inviteCode!,
            style: const TextStyle(
              color: AppColors.onSurface,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _copyCode,
            icon: Icon(
              _copied ? Icons.check : Icons.content_copy,
              size: 18,
              color: _copied ? AppColors.primary : AppColors.onSurface,
            ),
            label: Text(
              _copied ? 'Copiado!' : 'Copiar código',
              style: TextStyle(color: _copied ? AppColors.primary : AppColors.onSurface),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: _copied ? AppColors.primary : AppColors.subtle),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _isDesktop
              ? 'Compartilhe o código acima com quem quiser convidar.'
              : 'Compartilhe o QR presencialmente ou o código à distância.',
          style: const TextStyle(color: AppColors.subtle, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildExpired() {
    return Column(
      children: [
        const Icon(Icons.qr_code_2, size: 80, color: AppColors.subtle),
        const SizedBox(height: 12),
        const Text('QR expirado', style: TextStyle(color: AppColors.onSurface, fontSize: 16)),
        const SizedBox(height: 8),
        const Text(
          'QR codes expiram em 5 minutos por segurança.\nO código de texto não expira.',
          style: TextStyle(color: AppColors.subtle, fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _generate,
          icon: const Icon(Icons.refresh),
          label: const Text('Gerar novo QR'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
        ),
      ],
    );
  }
}
