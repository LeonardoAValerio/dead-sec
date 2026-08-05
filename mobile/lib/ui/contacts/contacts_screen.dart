import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../db/repositories/channel_repository.dart';
import '../../models/channel.dart';
import '../../models/user.dart';
import '../chat/chat_screen.dart';
import '../pairing/create_channel_screen.dart';
import '../pairing/join_code_screen.dart';
import '../pairing/qr_generate_screen.dart';
import '../pairing/qr_scan_screen.dart';
import '../settings/settings_screen.dart';

/// Lista de canais (conversas) do usuário.
class ContactsScreen extends StatefulWidget {
  final Database db;
  final User currentUser;

  const ContactsScreen({super.key, required this.db, required this.currentUser});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  late final ChannelRepository _repo;
  List<Channel> _channels = [];

  bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  @override
  void initState() {
    super.initState();
    _repo = ChannelRepository(widget.db);
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    final channels = await _repo.getAll();
    setState(() => _channels = channels);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('SafeChannel', style: TextStyle(color: AppColors.onSurface)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: AppColors.onSurface),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(db: widget.db, currentUser: widget.currentUser),
              ),
            ),
          ),
        ],
      ),
      body: _channels.isEmpty ? _empty() : _list(),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        onPressed: () => _showAddMenu(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _empty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.forum_outlined, size: 64, color: AppColors.subtle),
            SizedBox(height: 16),
            Text('Nenhuma conversa ainda.',
                style: TextStyle(color: AppColors.subtle)),
            SizedBox(height: 8),
            Text('Toque em + para criar ou entrar em um canal.',
                style: TextStyle(color: AppColors.subtle, fontSize: 13)),
          ],
        ),
      );

  Widget _list() => ListView.builder(
        itemCount: _channels.length,
        itemBuilder: (context, i) {
          final ch = _channels[i];
          return ListTile(
            tileColor: AppColors.surface,
            title: Text(ch.name, style: const TextStyle(color: AppColors.onSurface)),
            subtitle: Text(
              ch.createdAt.toLocal().toString().substring(0, 16),
              style: const TextStyle(color: AppColors.subtle, fontSize: 12),
            ),
            leading: CircleAvatar(
              backgroundColor: AppColors.primary,
              child: Text(
                ch.name.isNotEmpty ? ch.name[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  db: widget.db,
                  currentUser: widget.currentUser,
                  channel: ch,
                ),
              ),
            ),
            onLongPress: () => _confirmDeleteChannel(ch),
          );
        },
      );

  void _confirmDeleteChannel(Channel ch) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Excluir canal?', style: TextStyle(color: AppColors.onSurface)),
        content: Text(
          'O canal "${ch.name}" e todas as suas mensagens serão removidos permanentemente.',
          style: const TextStyle(color: AppColors.subtle),
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
              await _repo.deleteChannel(ch.id);
              _loadChannels();
            },
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
  }

  void _showAddMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.add_comment_outlined, color: AppColors.primary),
              title: const Text('Criar canal', style: TextStyle(color: AppColors.onSurface)),
              subtitle: const Text(
                'Gera um código de convite para compartilhar',
                style: TextStyle(color: AppColors.subtle, fontSize: 12),
              ),
              onTap: () {
                Navigator.of(context).pop();
                _openCreateChannel();
              },
            ),
            ListTile(
              enabled: !_isDesktop,
              leading: Icon(
                Icons.qr_code_2,
                color: _isDesktop ? AppColors.subtle : AppColors.primary,
              ),
              title: Text(
                'Criar canal via QR Code',
                style: TextStyle(
                  color: _isDesktop ? AppColors.subtle : AppColors.onSurface,
                ),
              ),
              subtitle: _isDesktop
                  ? const Text(
                      'Não disponível no desktop',
                      style: TextStyle(color: AppColors.subtle, fontSize: 12),
                    )
                  : const Text(
                      'Gera um QR Code para o peer escanear',
                      style: TextStyle(color: AppColors.subtle, fontSize: 12),
                    ),
              onTap: _isDesktop
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      _openCreateQr();
                    },
            ),
            ListTile(
              leading: const Icon(Icons.content_paste_outlined, color: AppColors.primary),
              title: const Text('Entrar com código',
                  style: TextStyle(color: AppColors.onSurface)),
              subtitle: const Text(
                'Cole o código recebido de outro usuário',
                style: TextStyle(color: AppColors.subtle, fontSize: 12),
              ),
              onTap: () {
                Navigator.of(context).pop();
                _openJoinCode();
              },
            ),
            ListTile(
              enabled: !_isDesktop,
              leading: Icon(
                Icons.qr_code_scanner,
                color: _isDesktop ? AppColors.subtle : AppColors.primary,
              ),
              title: Text(
                'Escanear QR Code',
                style: TextStyle(
                  color: _isDesktop ? AppColors.subtle : AppColors.onSurface,
                ),
              ),
              subtitle: _isDesktop
                  ? const Text(
                      'Não disponível no desktop',
                      style: TextStyle(color: AppColors.subtle, fontSize: 12),
                    )
                  : null,
              onTap: _isDesktop
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      _openScanner();
                    },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _openCreateChannel() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CreateChannelScreen(
          db: widget.db,
          currentUser: widget.currentUser,
          onCreated: (_) => _loadChannels(),
        ),
      ),
    );
  }

  Future<void> _openCreateQr() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Nome do canal', style: TextStyle(color: AppColors.onSurface)),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.onSurface),
          decoration: InputDecoration(
            hintText: 'Ex: Amigos, Projeto...',
            hintStyle: const TextStyle(color: AppColors.subtle),
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar', style: TextStyle(color: AppColors.subtle)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('Criar'),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QrGenerateScreen(
          db: widget.db,
          currentUser: widget.currentUser,
          channelName: name,
        ),
      ),
    );
    _loadChannels();
  }

  Future<void> _openJoinCode() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => JoinCodeScreen(
          db: widget.db,
          currentUser: widget.currentUser,
          onJoined: (ch) {
            _loadChannels();
            if (mounted) {
              // Fecha JoinCodeScreen e abre ChatScreen diretamente.
              // JoinCodeScreen não deve chamar Navigator.pop() — este callback assume a navegação.
              Navigator.of(context)
                ..pop()  // fecha JoinCodeScreen
                ..push(MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    db: widget.db,
                    currentUser: widget.currentUser,
                    channel: ch,
                  ),
                ));
            }
          },
        ),
      ),
    );
  }

  Future<void> _openScanner() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QrScanScreen(
          db: widget.db,
          currentUser: widget.currentUser,
          onJoined: (_) => _loadChannels(),
        ),
      ),
    );
  }
}
