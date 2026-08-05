import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../db/repositories/channel_repository.dart';
import '../../models/channel.dart';
import '../../models/user.dart';
import '../../webrtc/pairing_service.dart';

/// Tela para entrar em um canal colando o código de convite de texto.
class JoinCodeScreen extends StatefulWidget {
  final Database db;
  final User currentUser;
  final void Function(Channel channel) onJoined;

  const JoinCodeScreen({
    super.key,
    required this.db,
    required this.currentUser,
    required this.onJoined,
  });

  @override
  State<JoinCodeScreen> createState() => _JoinCodeScreenState();
}

class _JoinCodeScreenState extends State<JoinCodeScreen> {
  final _codeCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _showPassword = false;
  bool _loading = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('Entrar com código', style: TextStyle(color: AppColors.onSurface)),
        iconTheme: const IconThemeData(color: AppColors.onSurface),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: _codeCtrl,
                autofocus: true,
                maxLines: 4,
                minLines: 3,
                style: const TextStyle(
                  color: AppColors.onSurface,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
                decoration: _inputDecoration('Cole o código de convite aqui'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passCtrl,
                obscureText: !_showPassword,
                style: const TextStyle(color: AppColors.onSurface),
                decoration: _inputDecoration('Senha (se o código for protegido)').copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                      color: AppColors.subtle,
                    ),
                    onPressed: () => setState(() => _showPassword = !_showPassword),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withAlpha(180),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!, style: const TextStyle(color: Colors.white, fontSize: 13)),
                ),
              ],
              const Spacer(),
              FilledButton(
                onPressed: _loading ? null : _join,
                style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Entrar no canal'),
              ),
            ],
          ),
        ),
      ),
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

  Future<void> _join() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Cole o código de convite antes de continuar.');
      return;
    }
    final pass = _passCtrl.text;
    if (pass.isNotEmpty && pass.length < 8) {
      setState(() => _error = 'A senha deve ter pelo menos 8 caracteres.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final service = PairingService(channelRepo: ChannelRepository(widget.db));
      final password = _passCtrl.text.isEmpty ? null : _passCtrl.text;
      final result = await service.joinViaCode(code, widget.currentUser.id, password: password);

      if (result == null) {
        setState(() => _error = 'Código inválido ou senha incorreta.');
        return;
      }

      // A navegação (fechar esta tela + abrir ChatScreen) é responsabilidade
      // do callback onJoined em contacts_screen.dart via Navigator cascade.
      widget.onJoined(result);
    } catch (e, stack) {
      debugPrint('joinViaCode error: $e\n$stack');
      setState(() => _error = 'Erro: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }
}
