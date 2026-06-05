# SafeChannel — Status de Implementação

**Versão:** MVP + P1/P2  
**Data:** 2026-06-01  
**Estado:** Signal Protocol E2E funcionando em P2P local, comunicação bidirecional validada

---

## 1. O Que Está Implementado e Funcionando

### Servidor Go (`server/`)

| Componente | Arquivo | Status |
|---|---|---|
| Servidor de sinalização WebSocket | `signaling/hub.go`, `signaling/handler.go` | ✅ Funcionando |
| JWT anônimo (identidade = pubkey) | `auth/jwt.go` | ✅ Funcionando |
| Credenciais TURN temporárias (HMAC-SHA1, 10min) | `auth/turn_credentials.go` | ✅ Funcionando |
| TURN server embarcado (Pion) | `turn/server.go` | ✅ Funcionando |
| Arquitetura zero-storage (zero banco de dados) | `main.go` | ✅ SPEC-ARCH-001 |

### App Flutter (`mobile/lib/`)

| Área | Componentes | Status |
|---|---|---|
| **Identidade / Chaves** | `KeyManager` (Ed25519 + X25519 DH + X25519 Signal identity) | ✅ 3 chaves geradas |
| **Signal Protocol X3DH** | `SignalSession.initiate/receive/buildPeerBundle` | ✅ SPEC-CRYPTO-002 |
| **Double Ratchet** | `SignalSession.encrypt/decrypt` | ✅ SPEC-CRYPTO-002 |
| **Assinatura Ed25519** | `MessageSigner` wired em `DataChannelHandler.send` | ✅ SPEC-MSG-001 |
| **Banco local — Mobile** | `database.dart` → SQLCipher com chave Argon2id | ✅ Android/iOS |
| **Banco local — Desktop** | `database.dart` → sqflite_common_ffi com path real | ✅ Linux/macOS/Windows |
| **Multi-instância local** | `INSTANCE_ID` via `--dart-define` (chaves + banco separados) | ✅ Para testes |
| **Onboarding** | `ui/onboarding/onboarding_screen.dart` | ✅ Funcionando |
| **PIN unlock** | `main.dart` → `_PinUnlockScreen` | ✅ Funcionando |
| **Criação de canal** | `pairing_service.dart` + `create_channel_screen.dart` | ✅ Funcionando |
| **Ingresso por código** | `invite_code_service.dart` + `join_code_screen.dart` | ✅ Funcionando (sik+spksig incluídos) |
| **Ingresso por QR Code** | `pairing_service.dart` + `qr_scan_screen.dart` | ✅ Mobile; ⚠️ desktop sem câmera |
| **Lista de canais** | `ui/contacts/contacts_screen.dart` | ✅ Funcionando |
| **Chat — mensagens locais** | `ui/chat/chat_screen.dart` + `MessageRepository` | ✅ Funcionando |
| **Chat — conexão WebRTC** | `_initConnection()` em `chat_screen.dart` | ✅ Conecta ao servidor |
| **Chat — Signal Protocol** | `DataChannelHandler` wired no `_onDataChannelReady` | ✅ SPEC-CRYPTO-002 — E2E validado |
| **Chat — X3DH assimétrico** | `_sessionReady` + `onSessionReady` + retry automático | ✅ Admin envia pending ao receber 1ª msg |
| **Chat — SESSION_HELLO** | Member envia PreKeySignalMessage automática ao conectar | ✅ Admin completa X3DH sem depender do usuário |
| **Chat — early buffer** | `ch.onMessage` buffered no início de `_onDataChannelReady` | ✅ Evita SESSION_HELLO ser consumida antes do handler |
| **Chat — reenvio de pendentes** | `_retrySendPending()` ao conectar e ao X3DH completar | ✅ SPEC-MSG pendentes |
| **Chat — peer_joined/peer_left** | Reconexão automática por eventos de presença do servidor | ✅ Member-antes-do-admin + reconexão parcial |
| **Indicador de conexão** | `ConnectionIndicatorWidget` + `PeerConnectionManager` | ✅ SPEC-UI-001 |
| **Status de mensagem** | `MessageStatusIcon` (⏱ ✓ ✓✓ ✓✓blue) | ✅ Funcionando |
| **Vector Clocks** | `sync/vector_clock.dart` | ✅ Implementado |
| **Sync Manager** | `sync/sync_manager.dart` — disparado ao DataChannel abrir | ✅ SPEC-SYNC-001 |
| **Navegação pós-join** | Auto-navegar ao chat após entrar via código | ✅ P2-C |

### Testes automatizados (`mobile/test/`)

| Arquivo | Cobertura | Status |
|---|---|---|
| `test/crypto/signal_session_test.dart` | X3DH two-party, Double Ratchet, bidirecional | ✅ 3 testes |
| `test/crypto/message_signer_test.dart` | Ed25519 sign/verify, payload alterado, chave errada | ✅ 4 testes |
| `test/sync/vector_clock_test.dart` | increment, merge, happensBefore, isConcurrentWith | ✅ 5 testes |
| `test/sync/sync_manager_test.dart` | SYNC_REQUEST → RESPONSE → ACK | ✅ 3 testes |
| `test/webrtc/invite_code_service_test.dart` | encode/decode, senha, expiração | ✅ 7 testes |
| **Total** | | **✅ 22 testes passando** |

---

## 2. Limitações Conhecidas e Débito Técnico

### Baixo (melhorias de UX)

| ID | Problema |
|---|---|
| **L-09** | QR Code scanner indisponível no Linux desktop (mobile_scanner não suporta) — já tratado com mensagem de fallback |
| **L-10** | Senha de convite mínima de 8 chars (SPEC-CHAN-002) não validada na UI |
| **L-11** | Sem tela de detalhes do canal (membros, QR de convite a partir do chat) |
| **L-12** | Sem suporte a mídia (imagens, áudio, vídeo) |

### Resolvidos nesta iteração

| ID | Era | Resolvido por |
|---|---|---|
| **L-01** | Signal Protocol não wired | P1-6: `DataChannelHandler` + `_onDataChannelReady` |
| **L-02** | Ed25519 não aplicado nas msgs | P1-6: `MessageSigner.sign` em `DataChannelHandler.send` |
| **L-03** | `Curve.decodePoint` com 32 bytes | P1-3: helper `_prefixed()` + X25519 identity key |
| **L-04** | `buildLocalBundle` com chaves erradas | P1-3: `buildPeerBundle` a partir do QrPayload |
| **L-05** | Banco in-memory (dados perdidos ao reiniciar) | P2-D: path real em `~/.local/share/safechannel/` |
| **L-06** | SyncManager não disparado | P2-A: `_syncManager.startSync()` em `_onDataChannelReady` |
| **L-07** | Mensagens pending ficam ⏱ para sempre | P2-B: `_retrySendPending()` ao conectar |
| **L-08** | Sem navegação automática após join | P2-C: push `ChatScreen` no callback `onJoined` |
| **L-13** | SYNC_REQUEST aparecia como bolha de chat | `_msgSub` filtra texto; controle vai só via `onControlMessage` |
| **L-14** | `InvalidKeyException` ao admin enviar primeiro | X3DH assimétrico: `send()` retorna bool + retry via `onSessionReady` |
| **L-15** | Signal keys ausentes no invite code | `InviteCodeService.generate/decode` não incluía `sik`/`spksig` |
| **L-16** | `signal_identity_v1` ausente em keystores antigos | `KeyManager.ensureSignalIdentityKey()` no startup |
| **L-17** | One-time pre-key não registrada na store Signal | `_buildStore` agora chama `storePreKey(1, ...)` além de `storeSignedPreKey` |
| **L-18** | `decrypt()` tentava `SignalMessage` antes de `PreKeySignalMessage` | Ordem invertida: PreKeySignalMessage first (evita corrupção de estado) |
| **L-19** | Member entra antes do owner → P2P nunca estabelece | Servidor faz broadcast `peer_joined`; member re-envia offer ao receber evento |
| **L-20** | Reconexão parcial quebra P2P (um peer sai e volta) | Servidor broadcast `peer_left`; peer restante reseta WebRTC e aguarda nova offer |
| **L-21** | Admin precisa aguardar usuário enviar mensagem para X3DH completar | `sendSessionHello()` + early buffer: member envia PreKeySignalMessage automática |

---

## 3. Guia de Desenvolvimento Local

### Pré-requisitos

```bash
# Flutter (Linux desktop)
sudo apt install libsecret-1-dev  # flutter_secure_storage no Linux
flutter config --enable-linux-desktop

# Go (caminho do binário nesta máquina)
# /home/usuario/Documentos/go/bin/go
```

### Iniciar o servidor

```bash
cd server
/home/usuario/Documentos/go/bin/go run main.go
# Saída esperada:
# TURN server listening on UDP :3478 (realm=localhost)
# SafeChannel signaling server on :8000
# WARNING: running without TLS — use only for local development
```

### Testar com dois peers no mesmo Linux

```bash
# Terminal 2 — Peer Alice (cria o canal)
cd mobile
flutter run -d linux --dart-define=INSTANCE_ID=alice

# Terminal 3 — Peer Bob (entra via código)
flutter run -d linux --dart-define=INSTANCE_ID=bob
```

**Importante:** cada `INSTANCE_ID` tem chaves e banco de dados separados em:
- Keyring: prefixo `alice_` ou `bob_` nas chaves do keyring do sistema
- Banco: `~/.local/share/safechannel_alice/safechannel.db`

### Resetar uma instância (refazer onboarding)

```bash
flutter run -d linux \
  --dart-define=INSTANCE_ID=alice \
  --dart-define=RESET_ON_START=true
```

Isso limpa as chaves do keyring E deleta o arquivo de banco de dados da instância.

### Executar os testes automatizados

```bash
cd mobile
flutter test test/crypto/ test/sync/ test/webrtc/
# Esperado: All tests passed! (22 testes)
```

### Fluxo completo de teste P2P

1. Iniciar servidor Go
2. **Alice:** criar conta → abrir lista de canais → FAB → "Criar canal" → copiar código de convite
3. **Bob:** criar conta → FAB → "Entrar com código" → colar o código → UI navega direto ao chat
4. **Alice:** abrir o canal na lista → aguardar conexão (indicador deve ficar 🟢)
5. **Bob:** indicador 🟢 (P2P direto via loopback) → Signal Protocol handshake automático
6. Trocar mensagens — trafegam com Double Ratchet (SPEC-CRYPTO-002)

---

## 4. Próximas Implementações (Priorizadas)

### Prioridade 1 — v0.2 (Grupos + UX)

- Tela de detalhes do canal (membros, QR de convite a partir do chat)
- QR generator acessível do chat (não só na criação)
- Validação de senha mínima 8 chars (SPEC-CHAN-002)
- Biometria como alternativa ao PIN
- Notificações locais

### Prioridade 2 — v0.3 (Mídia)

- Envio de imagens (JPEG/PNG/WebP)
- Chunking com SHA-256 por chunk (SPEC-MSG-002)
- Preview/thumbnail
- Áudio (Opus/AAC)

### Prioridade 3 — v1.0 (Produção)

- Auditoria de segurança externa
- TLS real no servidor (Let's Encrypt)
- Rotação de signed pre-key (atualmente permanente)
- One-time pre-keys (OPK pool no servidor de sinalização)
- Publicação nas stores

---

## 5. Arquitetura de Arquivos Atual

```
mobile/lib/
├── core/
│   └── app_colors.dart
├── crypto/
│   ├── key_manager.dart         # Ed25519 (signing) + X25519 (DH) + X25519 (Signal identity)
│   ├── message_signer.dart      # Ed25519 sign/verify (SPEC-MSG-001) ✅ wired
│   └── signal_session.dart      # X3DH + Double Ratchet (SPEC-CRYPTO-002) ✅ wired
├── db/
│   ├── database.dart            # SQLCipher (mobile) / FFI path real (desktop)
│   └── repositories/
│       ├── channel_repository.dart
│       ├── message_repository.dart
│       └── user_repository.dart
├── models/
│   ├── channel.dart, channel_member.dart  # + signalKey, signalPreKey, signalPreKeySig
│   ├── message.dart, message_status.dart, message_type.dart
│   └── user.dart
├── sync/
│   ├── vector_clock.dart        # Map<String,int> causal ordering
│   └── sync_manager.dart        # Delta sync protocol ✅ disparado ao conectar
├── ui/
│   ├── chat/
│   │   └── chat_screen.dart     # Signal wired + SyncManager + pending retry
│   ├── contacts/
│   │   └── contacts_screen.dart # Auto-navega após join
│   ├── onboarding/
│   │   └── onboarding_screen.dart
│   ├── pairing/
│   │   ├── create_channel_screen.dart
│   │   ├── join_code_screen.dart
│   │   ├── qr_generate_screen.dart
│   │   └── qr_scan_screen.dart
│   └── shared/
│       ├── connection_indicator.dart
│       └── message_status_icon.dart
└── webrtc/
    ├── data_channel_handler.dart    # Signal encrypt/sign + onControlMessage ✅ wired
    ├── invite_code_service.dart     # AES-256-GCM corrigido
    ├── pairing_service.dart         # QrPayload com sik + spksig
    ├── peer_connection_manager.dart # + onDataChannelReady callback
    ├── signaling_client.dart
    └── turn_credentials_service.dart

mobile/test/
├── crypto/
│   ├── signal_session_test.dart    # X3DH + Double Ratchet ✅
│   └── message_signer_test.dart    # Ed25519 sign/verify ✅
├── sync/
│   ├── vector_clock_test.dart      # Causal ordering ✅
│   └── sync_manager_test.dart      # Sync protocol ✅
└── webrtc/
    └── invite_code_service_test.dart  # AES-256-GCM + Argon2id ✅

server/
├── main.go
├── auth/
│   ├── jwt.go
│   └── turn_credentials.go
├── signaling/
│   ├── hub.go
│   └── handler.go
└── turn/
    └── server.go
```

---

## 6. Decisões Técnicas Tomadas

| Decisão | Alternativa Considerada | Razão |
|---|---|---|
| `signal_identity_v1` (X25519) separada da `identity_key_v1` (Ed25519) | Usar Ed25519 para tudo | libsignal usa Montgomery curve (X25519) para DH; Ed25519 é Edwards curve — incompatíveis sem conversão |
| `_prefixed()` helper para chaves libsignal | Importar libsignal em todo lugar | Encapsula a peculiaridade do `0x05` prefix em um único ponto |
| `preKeySignature` salva no `ChannelMember` | Recalcular na hora de conectar | Criador não está online quando joiner conecta — precisa da assinatura local |
| `onDataChannelReady` callback no `PeerConnectionManager` | Polling de estado | Callback garante que Signal e Sync iniciam exatamente quando o DataChannel abre |
| `openTestDatabase()` para testes | `openAppDatabase` com flag de teste | Testes não devem tocar no banco de produção (`~/.local/share/safechannel/`) |
| GCM `sublist(0, l1+l2)` em vez de buffer completo | `getOutputSize` oversized | pointycastle 4.x aloca mais espaço que o escrito; bytes extras zerados corrompiam o MAC |
| `context.Background()` no broadcast do Go | Context com timeout | Mensagens de sinalização são curtas; timeout adicionaria complexidade sem benefício real |
