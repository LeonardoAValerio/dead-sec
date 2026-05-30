import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../db/repositories/channel_repository.dart';
import '../../models/channel.dart';
import '../../models/user.dart';
import '../../webrtc/pairing_service.dart';

/// Tela para criar um canal e obter o código de convite de texto.
class CreateChannelScreen extends StatefulWidget {
  final Database db;
  final User currentUser;
  final void Function(Channel channel) onCreated;

  const CreateChannelScreen({
    super.key,
    required this.db,
    required this.currentUser,
    required this.onCreated,
  });

  @override
  State<CreateChannelScreen> createState() => _CreateChannelScreenState();
}

class _CreateChannelScreenState extends State<CreateChannelScreen> {
  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _showPassword = false;
  bool _loading = false;
  String? _error;

  // Estado pós-criação
  Channel? _createdChannel;
  String? _inviteCode;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(
          _createdChannel == null ? 'Criar canal' : 'Canal criado',
          style: const TextStyle(color: AppColors.onSurface),
        ),
        iconTheme: const IconThemeData(color: AppColors.onSurface),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _createdChannel == null ? _buildForm() : _buildCode(),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        TextField(
          controller: _nameCtrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.onSurface),
          decoration: _inputDecoration('Nome do canal'),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _passCtrl,
          obscureText: !_showPassword,
          style: const TextStyle(color: AppColors.onSurface),
          decoration: _inputDecoration('Senha (opcional)').copyWith(
            suffixIcon: IconButton(
              icon: Icon(
                _showPassword ? Icons.visibility_off : Icons.visibility,
                color: AppColors.subtle,
              ),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Com senha, apenas quem souber a senha pode usar o código.',
          style: TextStyle(color: AppColors.subtle, fontSize: 12),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const Spacer(),
        FilledButton(
          onPressed: _loading ? null : _create,
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          child: _loading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Criar canal'),
        ),
      ],
    );
  }

  Widget _buildCode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle_outline, size: 56, color: AppColors.primary),
        const SizedBox(height: 12),
        Text(
          _createdChannel!.name,
          style: const TextStyle(
            color: AppColors.onSurface,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Text(
          'Código de convite',
          style: TextStyle(color: AppColors.subtle, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            _inviteCode!,
            style: const TextStyle(
              color: AppColors.onSurface,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
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
        const SizedBox(height: 8),
        Text(
          _passCtrl.text.isNotEmpty
              ? 'Compartilhe o código e a senha separadamente.'
              : 'Compartilhe este código com quem quiser convidar.',
          style: TextStyle(color: AppColors.subtle, fontSize: 12),
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        FilledButton(
          onPressed: _done,
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          child: const Text('Pronto'),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.subtle),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      );

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Nome deve ter pelo menos 2 caracteres.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final service = PairingService(channelRepo: ChannelRepository(widget.db));
      final password = _passCtrl.text.isEmpty ? null : _passCtrl.text;
      final result = await service.createChannelWithCode(name, widget.currentUser.id, password: password);
      setState(() {
        _createdChannel = result.channel;
        _inviteCode = result.inviteCode;
      });
    } catch (_) {
      setState(() => _error = 'Erro ao criar canal. Tente novamente.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: _inviteCode!));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  void _done() {
    widget.onCreated(_createdChannel!);
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }
}
