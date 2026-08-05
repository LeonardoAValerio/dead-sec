import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../crypto/key_manager.dart';
import '../../db/database.dart';
import '../../models/user.dart';
import '../../services/biometric_service.dart';
import '../../services/notification_service.dart';
import '../onboarding/onboarding_screen.dart';

class SettingsScreen extends StatefulWidget {
  final Database db;
  final User currentUser;

  const SettingsScreen({super.key, required this.db, required this.currentUser});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true;
  bool _biometricsEnabled = false;
  bool _biometricsAvailable = false;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final notif = await NotificationService.isEnabled();
    final bioEnabled = await BiometricService.isEnabled();
    final bioAvailable = await BiometricService.isAvailable();
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = notif;
      _biometricsEnabled = bioEnabled;
      _biometricsAvailable = bioAvailable;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('Configurações', style: TextStyle(color: AppColors.onSurface)),
        iconTheme: const IconThemeData(color: AppColors.onSurface),
      ),
      body: ListView(
        children: [
          _sectionHeader('CONTA'),
          ListTile(
            tileColor: AppColors.surface,
            leading: const Icon(Icons.person_outline, color: AppColors.onSurface),
            title: const Text('Usuário', style: TextStyle(color: AppColors.onSurface)),
            subtitle: Text(
              widget.currentUser.displayName,
              style: const TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
          ),
          const Divider(height: 1, color: AppColors.background),
          ListTile(
            tileColor: AppColors.surface,
            leading: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
            title: const Text('Limpar conta', style: TextStyle(color: Colors.redAccent)),
            subtitle: const Text(
              'Apaga todos os dados locais e volta ao início',
              style: TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
            onTap: () => _confirmWipe(context),
          ),
          _sectionHeader('SEGURANÇA'),
          if (_biometricsAvailable) ...[
            SwitchListTile(
              tileColor: AppColors.surface,
              secondary: const Icon(Icons.fingerprint, color: AppColors.onSurface),
              title: const Text('Biometria', style: TextStyle(color: AppColors.onSurface)),
              subtitle: const Text(
                'Use impressão digital ou rosto para desbloquear',
                style: TextStyle(color: AppColors.subtle, fontSize: 13),
              ),
              value: _biometricsEnabled,
              activeThumbColor: AppColors.primary,
              onChanged: (val) => val ? _enableBiometrics() : _disableBiometrics(),
            ),
            const Divider(height: 1, color: AppColors.background),
          ],
          ListTile(
            tileColor: AppColors.surface,
            leading: const Icon(Icons.lock_reset_outlined, color: AppColors.onSurface),
            title: const Text('Trocar PIN', style: TextStyle(color: AppColors.onSurface)),
            subtitle: const Text(
              'Redefine o PIN de desbloqueio',
              style: TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
            trailing: const Icon(Icons.chevron_right, color: AppColors.subtle),
            onTap: () => _showChangePinDialog(context),
          ),
          _sectionHeader('NOTIFICAÇÕES'),
          SwitchListTile(
            tileColor: AppColors.surface,
            secondary: const Icon(Icons.notifications_outlined, color: AppColors.onSurface),
            title: const Text('Notificações', style: TextStyle(color: AppColors.onSurface)),
            subtitle: const Text(
              'Peer entrou no canal ou nova mensagem',
              style: TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
            value: _notificationsEnabled,
            activeThumbColor: AppColors.primary,
            onChanged: (val) async {
              await NotificationService.setEnabled(val);
              setState(() => _notificationsEnabled = val);
            },
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          title,
          style: const TextStyle(
            color: AppColors.subtle,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
          ),
        ),
      );

  // ─── Biometria ────────────────────────────────────────────────────────────

  Future<void> _enableBiometrics() async {
    final pin = await _promptPin(context, title: 'Confirmar PIN', subtitle:
        'Digite seu PIN para habilitar a biometria');
    if (pin == null || !mounted) return;

    final scaffoldMsg = ScaffoldMessenger.of(context);
    try {
      final dbKey = await KeyManager.deriveDbKey(pin);
      await BiometricService.enable(dbKey);
      setState(() => _biometricsEnabled = true);
      scaffoldMsg.showSnackBar(
        const SnackBar(content: Text('Biometria habilitada')),
      );
    } catch (_) {
      scaffoldMsg.showSnackBar(
        const SnackBar(content: Text('Erro ao habilitar biometria. Verifique o PIN.')),
      );
    }
  }

  Future<void> _disableBiometrics() async {
    await BiometricService.disable();
    setState(() => _biometricsEnabled = false);
  }

  // ─── Trocar PIN ───────────────────────────────────────────────────────────

  Future<void> _showChangePinDialog(BuildContext context) async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? error;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Trocar PIN', style: TextStyle(color: AppColors.onSurface)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _pinField(oldCtrl, 'PIN atual'),
              const SizedBox(height: 12),
              _pinField(newCtrl, 'Novo PIN (mín. 6 dígitos)'),
              const SizedBox(height: 12),
              _pinField(confirmCtrl, 'Confirmar novo PIN'),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar', style: TextStyle(color: AppColors.subtle)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: () async {
                final oldPin = oldCtrl.text;
                final newPin = newCtrl.text;
                final confirm = confirmCtrl.text;

                if (newPin.length < 6) {
                  setDialogState(() => error = 'O novo PIN deve ter pelo menos 6 dígitos.');
                  return;
                }
                if (newPin != confirm) {
                  setDialogState(() => error = 'Os PINs não coincidem.');
                  return;
                }

                setDialogState(() => error = null);
                Navigator.of(ctx).pop();

                await _changePin(oldPin: oldPin, newPin: newPin);
              },
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ),
    );

    oldCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();
  }

  Future<void> _changePin({required String oldPin, required String newPin}) async {
    final scaffoldMsg = ScaffoldMessenger.of(context);
    try {
      // Verifica PIN antigo derivando a chave e abrindo o banco.
      final oldKey = await KeyManager.deriveDbKey(oldPin);
      final verifyDb = await openAppDatabase(oldKey);
      final rows = await verifyDb.query('users', limit: 1);
      await verifyDb.close();

      if (rows.isEmpty) {
        scaffoldMsg.showSnackBar(
          const SnackBar(content: Text('PIN atual incorreto.')),
        );
        return;
      }

      // Gera novo salt e deriva nova chave.
      final newKey = await KeyManager.rotateSalt(newPin);

      // Reencripta o banco (no-op no desktop).
      await rekeyDatabase(widget.db, newKey);

      // Atualiza chave biométrica se habilitada.
      if (_biometricsEnabled) {
        await BiometricService.updateStoredKey(newKey);
      }

      if (!mounted) return;
      scaffoldMsg.showSnackBar(
        const SnackBar(content: Text('PIN alterado com sucesso.')),
      );
    } catch (e) {
      scaffoldMsg.showSnackBar(
        SnackBar(content: Text('Erro ao trocar PIN: $e')),
      );
    }
  }

  // ─── Wipe ─────────────────────────────────────────────────────────────────

  void _confirmWipe(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Limpar conta?', style: TextStyle(color: AppColors.onSurface)),
        content: const Text(
          'Todos os canais, mensagens e chaves criptográficas serão apagados permanentemente. Esta ação não pode ser desfeita.',
          style: TextStyle(color: AppColors.subtle),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar', style: TextStyle(color: AppColors.subtle)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _wipe(context);
            },
            child: const Text('Apagar tudo'),
          ),
        ],
      ),
    );
  }

  Future<void> _wipe(BuildContext context) async {
    await widget.db.delete('messages');
    await widget.db.delete('channel_members');
    await widget.db.delete('channels');
    await widget.db.delete('users');
    await KeyManager.deleteAllKeys();
    await BiometricService.disable();
    if (_isDesktop) await resetDesktopDatabase();

    if (context.mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
        (_) => false,
      );
    }
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  /// Mostra dialog pedindo PIN e retorna o valor digitado, ou null se cancelado.
  Future<String?> _promptPin(BuildContext context, {required String title, required String subtitle}) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(title, style: const TextStyle(color: AppColors.onSurface)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subtitle, style: const TextStyle(color: AppColors.subtle, fontSize: 13)),
            const SizedBox(height: 12),
            _pinField(ctrl, 'PIN'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancelar', style: TextStyle(color: AppColors.subtle)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Widget _pinField(TextEditingController ctrl, String hint) => TextField(
        controller: ctrl,
        obscureText: true,
        keyboardType: TextInputType.number,
        style: const TextStyle(color: AppColors.onSurface),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: AppColors.subtle),
          filled: true,
          fillColor: AppColors.background,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      );
}
