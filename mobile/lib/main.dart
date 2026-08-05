import 'package:flutter/material.dart';

import 'core/app_colors.dart';
import 'crypto/key_manager.dart';
import 'db/database.dart';
import 'db/repositories/user_repository.dart';
import 'services/biometric_service.dart';
import 'services/notification_service.dart';
import 'ui/contacts/contacts_screen.dart';
import 'ui/onboarding/onboarding_screen.dart';

const _kResetOnStart = bool.fromEnvironment('RESET_ON_START');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_kResetOnStart) {
    await KeyManager.deleteAllKeys();
    await resetDesktopDatabase();
  }
  await NotificationService.initialize();
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
  // true enquanto biometria está habilitada e ainda não foi descartada
  bool _showBiometric = false;

  @override
  void initState() {
    super.initState();
    _checkBiometrics();
  }

  Future<void> _checkBiometrics() async {
    final enabled = await BiometricService.isEnabled();
    if (!enabled || !mounted) return;
    setState(() => _showBiometric = true);
    _tryBiometric();
  }

  Future<void> _tryBiometric() async {
    final dbKey = await BiometricService.authenticate();
    if (!mounted) return;
    if (dbKey == null) {
      // Falhou ou foi cancelado → mostrar PIN
      setState(() => _showBiometric = false);
      return;
    }
    await _openWithKey(dbKey);
  }

  Future<void> _openWithKey(String dbKey) async {
    setState(() { _loading = true; _error = null; });
    try {
      final db = await openAppDatabase(dbKey);
      final user = await UserRepository(db).findFirst();
      if (user == null) {
        setState(() => _error = 'Dados corrompidos. Use o PIN.');
        return;
      }
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => ContactsScreen(db: db, currentUser: user)),
        );
      }
    } catch (_) {
      setState(() => _error = 'Falha ao desbloquear. Verifique o PIN.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _showBiometric ? _buildBiometricView() : _buildPinView(context),
        ),
      ),
    );
  }

  Widget _buildBiometricView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        const Icon(Icons.fingerprint, size: 72, color: AppColors.primary),
        const SizedBox(height: 20),
        Text(
          'SafeChannel',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: AppColors.onSurface,
                fontWeight: FontWeight.bold,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        const Text(
          'Autentique-se para continuar',
          style: TextStyle(color: AppColors.subtle),
          textAlign: TextAlign.center,
        ),
        if (_loading) ...[
          const SizedBox(height: 24),
          const Center(child: CircularProgressIndicator(color: AppColors.primary)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
        ],
        const Spacer(),
        FilledButton(
          onPressed: _loading ? null : _tryBiometric,
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          child: const Text('Tentar novamente'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => setState(() { _showBiometric = false; _error = null; }),
          child: const Text('Usar PIN', style: TextStyle(color: AppColors.subtle)),
        ),
      ],
    );
  }

  Widget _buildPinView(BuildContext context) {
    return Column(
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
            hintStyle: const TextStyle(color: AppColors.subtle),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (_) => _unlockWithPin(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _loading ? null : _unlockWithPin,
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          child: _loading
              ? const SizedBox(
                  height: 20, width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Desbloquear'),
        ),
        const Spacer(),
      ],
    );
  }

  Future<void> _unlockWithPin() async {
    final pin = _pinCtrl.text.trim();
    if (pin.length < 6) {
      setState(() => _error = 'PIN inválido.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final dbKey = await KeyManager.deriveDbKey(pin);
      await _openWithKey(dbKey);
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
