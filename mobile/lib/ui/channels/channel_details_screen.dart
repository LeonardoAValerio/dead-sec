import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/app_colors.dart';
import '../../db/repositories/channel_repository.dart';
import '../../models/channel.dart';
import '../../models/channel_member.dart';
import '../../models/user.dart';
import '../shared/invite_qr_sheet.dart';

/// Tela de detalhes de um canal: informações gerais, lista de membros e convite.
/// Somente leitura — sem ações de gestão (v0.2).
class ChannelDetailsScreen extends StatefulWidget {
  final Database db;
  final User currentUser;
  final Channel channel;

  const ChannelDetailsScreen({
    super.key,
    required this.db,
    required this.currentUser,
    required this.channel,
  });

  @override
  State<ChannelDetailsScreen> createState() => _ChannelDetailsScreenState();
}

class _ChannelDetailsScreenState extends State<ChannelDetailsScreen> {
  List<ChannelMember>? _members;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final repo = ChannelRepository(widget.db);
    final members = await repo.getMembers(widget.channel.id);
    if (mounted) setState(() => _members = members);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('Detalhes do canal', style: TextStyle(color: AppColors.onSurface)),
        iconTheme: const IconThemeData(color: AppColors.onSurface),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _sectionHeader('CANAL'),
            _infoCard(),
            _sectionHeader('MEMBROS'),
            _membersSection(),
            _sectionHeader('CONVIDAR'),
            _inviteSection(),
          ],
        ),
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

  Widget _infoCard() {
    final channel = widget.channel;
    final createdDate = _formatDate(channel.createdAt);
    return Column(
      children: [
        ListTile(
          tileColor: AppColors.surface,
          leading: CircleAvatar(
            backgroundColor: AppColors.primary,
            child: Text(
              channel.name.isNotEmpty ? channel.name[0].toUpperCase() : '?',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          title: Text(channel.name, style: const TextStyle(color: AppColors.onSurface)),
          subtitle: Text(
            'Criado em $createdDate',
            style: const TextStyle(color: AppColors.subtle, fontSize: 12),
          ),
        ),
        const Divider(height: 1, color: AppColors.background),
        ListTile(
          tileColor: AppColors.surface,
          leading: const Icon(Icons.group_outlined, color: AppColors.subtle),
          title: Text(
            'Máx. ${channel.settings.maxMembers} membros',
            style: const TextStyle(color: AppColors.subtle, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _membersSection() {
    if (_members == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }
    if (_members!.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Nenhum membro encontrado.', style: TextStyle(color: AppColors.subtle)),
      );
    }
    return Column(
      children: _members!.map((m) => _memberTile(m)).toList(),
    );
  }

  Widget _memberTile(ChannelMember member) {
    final isMe = member.userId == widget.currentUser.id;
    String label;
    if (isMe) {
      label = widget.currentUser.displayName.isNotEmpty
          ? '${widget.currentUser.displayName} (você)'
          : 'Você';
    } else if (member.displayName.isNotEmpty) {
      label = member.displayName;
    } else {
      label = member.userId.substring(0, 8);
    }
    final fingerprint = _keyFingerprint(member.publicKey);
    final roleLabel = member.role == MemberRole.admin ? 'Admin' : 'Membro';
    final roleColor = member.role == MemberRole.admin ? AppColors.primary : AppColors.subtle;

    return Column(
      children: [
        ListTile(
          tileColor: AppColors.surface,
          leading: CircleAvatar(
            backgroundColor: AppColors.surface,
            child: Icon(
              isMe ? Icons.person : Icons.person_outline,
              color: isMe ? AppColors.primary : AppColors.subtle,
            ),
          ),
          title: Row(
            children: [
              Text(label, style: const TextStyle(color: AppColors.onSurface)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: roleColor.withAlpha(40),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  roleLabel,
                  style: TextStyle(color: roleColor, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          subtitle: Text(
            'Chave: $fingerprint',
            style: const TextStyle(color: AppColors.subtle, fontSize: 11, fontFamily: 'monospace'),
          ),
        ),
        const Divider(height: 1, color: AppColors.background),
      ],
    );
  }

  Widget _inviteSection() {
    return Column(
      children: [
        ListTile(
          tileColor: AppColors.surface,
          leading: const Icon(Icons.qr_code, color: AppColors.onSurface),
          title: const Text('Gerar convite', style: TextStyle(color: AppColors.onSurface)),
          subtitle: const Text(
            'QR Code (5 min) ou código de texto para compartilhar',
            style: TextStyle(color: AppColors.subtle, fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, color: AppColors.subtle),
          onTap: () => InviteQrSheet.show(context, widget.db, widget.currentUser, widget.channel),
        ),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/'
        '${dt.year}';
  }

  String _keyFingerprint(Uint8List key) {
    final b64 = base64Encode(key);
    return b64.length > 12 ? '${b64.substring(0, 12)}…' : b64;
  }
}
