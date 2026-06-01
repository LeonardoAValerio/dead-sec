import 'package:flutter/material.dart';

import 'core/app_colors.dart';
import 'crypto/key_manager.dart';
import 'db/database.dart';
import 'db/repositories/user_repository.dart';
import 'ui/contacts/contacts_screen.dart';
import 'ui/onboarding/onboarding_screen.dart';

const _kResetOnStart = bool.fromEnvironment('RESET_ON_START');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_kResetOnStart) {
    await KeyManager.deleteAllKeys();
    await resetDesktopDatabase();
  }
  runApp(const SafeChannelApp());
}

class SafeChannelApp extends StatelessWidget {
  const SafeChannelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeChannel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          surface: AppColors.surface,
        ),
        scaffoldBackgroundColor: AppColors.background,
        useMaterial3: true,
      ),
      home: const _Loader(),
    );
  }
}

/// Decide entre onboarding e tela principal com base na existência de chaves locais.
class _Loader extends StatefulWidget {
  const _Loader();

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> {
  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final hasKeys = await KeyManager.hasKeys();
    if (!mounted) return;

    if (!hasKeys) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
      );
    } else {
      // Migração: gera signal_identity_v1 se o keystore foi criado antes dessa chave existir.
      await KeyManager.ensureSignalIdentityKey();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const _PinUnlockScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: Center(child: CircularProgressIndicator(color: AppColors.primary)),
    );
  }
}

/// Tela de desbloqueio por PIN para sessões subsequentes.
class _PinUnlockScreen extends StatefulWidget {
  const _PinUnlockScreen();

  @override
  State<_PinUnlockScreen> createState() => _PinUnlockScreenState();
}

class _PinUnlockScreenState extends State<_PinUnlockScreen> {
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
              const Icon(Icons.lock, size: 56, color: AppColors.primary),
              const SizedBox(height: 20),
              Text(
                'SafeChannel',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: AppColors.onSurface,
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _pinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                autofocus: true,
                style: const TextStyle(color: AppColors.onSurface),
                decoration: InputDecoration(
                  hintText: 'PIN',
                  hintStyle: TextStyle(color: AppColors.subtle),
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _unlock(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _loading ? null : _unlock,
                style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Desbloquear'),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _unlock() async {
    final pin = _pinCtrl.text.trim();
    if (pin.length < 6) {
      setState(() => _error = 'PIN inválido.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final dbKey = await KeyManager.deriveDbKey(pin);
      final db = await openAppDatabase(dbKey);
      final user = await UserRepository(db).findFirst();

      if (user == null) {
        setState(() => _error = 'PIN incorreto ou dados corrompidos.');
        return;
      }

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ContactsScreen(db: db, currentUser: user),
          ),
        );
      }
    } catch (_) {
      setState(() => _error = 'Falha ao desbloquear. Verifique o PIN.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }
}
