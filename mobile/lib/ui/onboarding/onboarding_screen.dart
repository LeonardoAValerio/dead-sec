import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../crypto/key_manager.dart';
import '../../db/database.dart';
import '../../db/repositories/user_repository.dart';
import '../../models/user.dart';
import '../contacts/contacts_screen.dart';

/// Tela de criação de conta: nome + PIN.
/// Ao confirmar: gera chaves Ed25519/X25519 → deriva chave do banco → salva User local.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _nameCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(Icons.lock, size: 64, color: AppColors.primary),
              const SizedBox(height: 24),
              Text(
                'SafeChannel',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(color: AppColors.onSurface, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Mensagens P2P sem servidor.',
                style: TextStyle(color: AppColors.subtle),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              _field(_nameCtrl, 'Seu nome', false),
              const SizedBox(height: 16),
              _field(_pinCtrl, 'PIN (mín. 6 dígitos)', true),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _loading ? null : _submit,
                style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Criar conta'),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String hint, bool obscure) => TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: obscure ? TextInputType.number : TextInputType.text,
        style: const TextStyle(color: AppColors.onSurface),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: AppColors.subtle),
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      );

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final pin = _pinCtrl.text.trim();

    if (name.isEmpty) {
      setState(() => _error = 'Informe seu nome.');
      return;
    }
    if (pin.length < 6) {
      setState(() => _error = 'PIN deve ter ao menos 6 dígitos.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final dbKey = await KeyManager.deriveDbKey(pin);
      final db = await openAppDatabase(dbKey);
      final bundle = await KeyManager.generateAndStoreKeys();

      final user = User(
        id: bundle.userId,
        displayName: name,
        identityPublicKey: bundle.identityPublicKey,
        signedPreKeyPublic: bundle.signedPreKeyPublic,
        createdAt: DateTime.now(),
      );

      await UserRepository(db).save(user);

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => ContactsScreen(db: db, currentUser: user)),
        );
      }
    } catch (e, st) {
      debugPrint('Onboarding error: $e\n$st');
      setState(() => _error = 'Erro ao criar conta. Tente novamente.');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }
}
