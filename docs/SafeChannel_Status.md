# SafeChannel — Status de Implementação

**Versão:** MVP  
**Data:** 2026-05-29  
**Estado:** Funcional para testes locais em Linux desktop

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

**Bug corrigido nesta sessão:** `hub.go` broadcast passava `nil` como `context.Context` para `nhooyr.io/websocket.Write`, causando panic. Corrigido para `context.Background()`.

### App Flutter (`mobile/lib/`)

| Área | Componentes | Status |
|---|---|---|
| **Identidade / Chaves** | `KeyManager` (Ed25519 + X25519, flutter_secure_storage) | ✅ Funcionando |
| **Banco local — Mobile** | `database.dart` → SQLCipher com chave Argon2id | ✅ Android/iOS |
| **Banco local — Desktop** | `database.dart` → sqflite_common_ffi in-memory | ✅ Linux/Web (dev) |
| **Multi-instância local** | `INSTANCE_ID` via `--dart-define` em `KeyManager` | ✅ Para testes |
| **Onboarding** | `ui/onboarding/onboarding_screen.dart` | ✅ Funcionando |
| **PIN unlock** | `main.dart` → `_PinUnlockScreen` | ✅ Funcionando |
| **Criação de canal** | `pairing_service.dart` + `ui/pairing/create_channel_screen.dart` | ✅ Funcionando |
| **Ingresso por código** | `invite_code_service.dart` + `ui/pairing/join_code_screen.dart` | ✅ Funcionando |
| **Ingresso por QR Code** | `pairing_service.dart` + `ui/pairing/qr_scan_screen.dart` | ✅ Mobile; ⚠️ indisponível no desktop |
| **Lista de canais** | `ui/contacts/contacts_screen.dart` | ✅ Funcionando |
| **Chat — mensagens locais** | `ui/chat/chat_screen.dart` + `MessageRepository` | ✅ Funcionando |
| **Chat — conexão WebRTC** | `_initConnection()` em `chat_screen.dart` | ✅ Conecta ao servidor |
| **Chat — envio/recepção P2P** | DataChannel raw bytes no ChatScreen | ✅ Funcional (sem Signal Protocol) |
| **Indicador de conexão** | `ConnectionIndicatorWidget` + `PeerConnectionManager` | ✅ SPEC-UI-001 |
| **Status de mensagem** | `MessageStatusIcon` (⏱ ✓ ✓✓ ✓✓blue) | ✅ Funcionando |
| **Vector Clocks** | `sync/vector_clock.dart` | ✅ Implementado |
| **Sync Manager** | `sync/sync_manager.dart` | ✅ Implementado, ⚠️ não disparado |

---

## 2. Limitações Conhecidas e Débito Técnico

### Crítico (bloqueia requisitos de segurança)

| ID | Problema | Arquivo | Spec |
|---|---|---|---|
| **L-01** | Signal Protocol **não wired** ao ChatScreen — mensagens trafegam como raw UTF-8 | `chat_screen.dart` | SPEC-CRYPTO-002 |
| **L-02** | Assinatura Ed25519 **não aplicada** nas mensagens enviadas | `chat_screen.dart` | SPEC-MSG-001 |
| **L-03** | `Curve.decodePoint` do libsignal espera prefixo `0x05` (33 bytes), mas `cryptography` package retorna 32 bytes — `SignalSession` falha ao tentar iniciar sessão X3DH | `signal_session.dart` | SPEC-CRYPTO-002 |
| **L-04** | `SignalSession.buildLocalBundle` usa chaves locais como se fossem do peer — conceitualmente errado para X3DH | `signal_session.dart` | SPEC-CRYPTO-002 |

### Médio (limita experiência de desenvolvimento)

| ID | Problema | Impacto |
|---|---|---|
| **L-05** | Banco de dados in-memory no Linux → dados perdidos ao reiniciar | A cada restart, usuário precisa refazer onboarding (se chaves já existem no keyring, a tela de PIN falha) |
| **L-06** | Sync protocol (SyncManager) implementado mas não disparado quando DataChannel abre | SPEC-SYNC-001 pendente |
| **L-07** | Status de mensagens não atualiza: `pending → sent` quando peer conecta e mensagens são reenviadas | Mensagens enviadas offline ficam com ⏱ para sempre |
| **L-08** | Sem navegação automática para o canal após ingressar via código | Usuário precisa voltar à lista manualmente |

### Baixo (melhorias de UX)

| ID | Problema |
|---|---|
| **L-09** | QR Code scanner indisponível no Linux desktop (mobile_scanner não suporta) — já tratado com mensagem de fallback |
| **L-10** | Senha de convite mínima de 8 chars (SPEC-CHAN-002) não validada na UI |
| **L-11** | Sem tela de detalhes do canal (membros, QR de convite a partir do chat) |
| **L-12** | Sem suporte a mídia (imagens, áudio, vídeo) |

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
# SafeChannel signaling server on :8080
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

**Importante:** cada `INSTANCE_ID` tem chaves separadas no keyring do sistema. Na primeira execução de cada instância, o app vai para o Onboarding. Nas seguintes, vai para o PIN unlock.

### Resetar uma instância (refazer onboarding)

```bash
flutter run -d linux \
  --dart-define=INSTANCE_ID=alice \
  --dart-define=RESET_ON_START=true
```

### Problema: "PIN incorreto ou dados corrompidos" após reiniciar

O banco é in-memory no Linux — esvazia a cada restart. Se as chaves já existem no keyring mas o banco está vazio, a tela de PIN falha mesmo com o PIN correto. **Solução:** rodar com `RESET_ON_START=true` para limpar as chaves e refazer o onboarding.

### Fluxo completo de teste P2P

1. Iniciar servidor Go
2. **Alice:** criar conta → abrir lista de canais → FAB → "Criar canal" → inserir nome → copiar código de convite
3. **Bob:** criar conta → FAB → "Entrar com código" → colar o código → entrar
4. **Alice:** abrir o canal na lista → aguardar conexão (indicador deve ficar 🟢)
5. **Bob:** abrir o mesmo canal → indicador 🟢 (P2P direto via loopback)
6. Trocar mensagens em tempo real

---

## 4. Próximas Implementações (Priorizadas)

### Prioridade 1 — Fechar débitos de segurança do MVP

#### P1-A: Corrigir `SignalSession` para usar chaves no formato libsignal

**Problema:** `Curve.decodePoint` exige 33 bytes com prefixo `0x05`. Chaves do pacote `cryptography` têm 32 bytes.

**Solução:** em `signal_session.dart`, adicionar prefixo ao construir `ECPublicKey`:
```dart
final prefixed = Uint8List(33);
prefixed[0] = 0x05;
prefixed.setRange(1, 33, rawPubKeyBytes);
final ecPub = Curve.decodePoint(prefixed, 0);
```
Para `ECPrivateKey`: `Curve.decodePrivatePoint` aceita 32 bytes diretamente — verificar se precisa clamp.

#### P1-B: Corrigir X3DH — `buildLocalBundle` deve usar chaves do PEER, não locais

**Problema:** `joinViaQr`/`joinViaCode` chama `buildLocalBundle(payload.channelId)` e usa o resultado como se fosse a bundle do peer remoto. Errado — deve construir a bundle a partir das chaves que vieram no payload (QR ou invite code).

**Solução:** em `_joinWithPayload`, construir a `PreKeyBundle` do criador usando `payload.creatorPublicKey` e `payload.signedPreKey`:
```dart
// Construir bundle do criador a partir das chaves do payload
final ecCreatorPub = Curve.decodePoint(prefixed(payload.creatorPublicKey), 0);
final ecPreKey = Curve.decodePoint(prefixed(payload.signedPreKey), 0);
// Calcular assinatura com chave de identidade local (XEdDSA)
// ou usar assinatura do payload se o QR a incluir
final bundle = PreKeyBundle(regId, 1, 1, ecPreKey, 1, ecPreKey, signature, IdentityKey(ecCreatorPub));
```
O QR payload e o invite code precisarão incluir a assinatura da signed pre-key para que `processPreKeyBundle` passe na verificação.

#### P1-C: Wire Signal Protocol no ChatScreen

Após corrigir P1-A e P1-B, substituir o envio/recepção raw no `ChatScreen` pelo pipeline completo:

**Envio:** `plaintext → Ed25519 sign → Signal Protocol encrypt → DataChannel`  
**Recepção:** `DataChannel → Signal Protocol decrypt → verify Ed25519 → persist`

Usar `DataChannelHandler` (já implementado em `webrtc/data_channel_handler.dart`) em vez de acesso direto ao `PeerConnectionManager.onMessage`.

### Prioridade 2 — Qualidade de vida do MVP

#### P2-A: Sync protocol ao conectar

Em `ChatScreen._initConnection`, após DataChannel abrir, disparar `SyncManager.startSync(channelId, localUserId)`. O `SyncManager` já está implementado — só precisa ser instanciado e conectado ao DataChannel.

#### P2-B: Atualizar status pending → sent ao conectar

Quando DataChannel abre e peer está online, buscar mensagens pendentes do DB e reenviá-las, atualizando status para `sent`.

#### P2-C: Navegar automaticamente para o canal após ingressar

Em `JoinCodeScreen`, após `onJoined`, navegar diretamente para `ChatScreen` em vez de apenas fechar a tela.

#### P2-D: Persistência no Linux (dev)

Substituir `inMemoryDatabasePath` por um path real em `~/.local/share/safechannel/` no Linux. Dados persistem entre restarts. Ainda sem criptografia SQLCipher no desktop — aceitável para dev.

### Prioridade 3 — v0.2 (Canais grupos + UX)

- Tela de detalhes do canal (membros, QR de convite a partir do chat)
- QR generator acessível do chat (não só na criação)
- Validação de senha mínima 8 chars (SPEC-CHAN-002)
- Biometria como alternativa ao PIN
- Notificações locais

### Prioridade 4 — v0.3 (Mídia)

- Envio de imagens (JPEG/PNG/WebP)
- Chunking com SHA-256 por chunk (SPEC-MSG-002)
- Preview/thumbnail
- Áudio (Opus/AAC)

---

## 5. Arquitetura de Arquivos Atual

```
mobile/lib/
├── core/
│   └── app_colors.dart                    # Paleta Material3 dark
├── crypto/
│   ├── key_manager.dart                   # Ed25519/X25519, INSTANCE_ID prefix
│   ├── message_signer.dart                # Ed25519 sign/verify (⚠️ não wired)
│   └── signal_session.dart                # Signal Protocol wrapper (⚠️ X3DH quebrado)
├── db/
│   ├── database.dart                      # SQLCipher (mobile) / FFI in-memory (desktop)
│   └── repositories/
│       ├── channel_repository.dart
│       ├── message_repository.dart
│       └── user_repository.dart
├── models/
│   ├── channel.dart, channel_member.dart
│   ├── message.dart, message_status.dart, message_type.dart
│   └── user.dart
├── sync/
│   ├── vector_clock.dart                  # Map<String,int> causal ordering
│   └── sync_manager.dart                  # Delta sync protocol (⚠️ não disparado)
├── ui/
│   ├── chat/
│   │   └── chat_screen.dart              # WebRTC wired, raw bytes (sem Signal)
│   ├── contacts/
│   │   └── contacts_screen.dart          # Lista canais + BottomSheet (criar/código/QR)
│   ├── onboarding/
│   │   └── onboarding_screen.dart
│   ├── pairing/
│   │   ├── create_channel_screen.dart    # Criar canal + gerar invite code
│   │   ├── join_code_screen.dart         # Entrar via código de convite
│   │   ├── qr_generate_screen.dart       # QR Code com countdown 5min
│   │   └── qr_scan_screen.dart          # Câmera (mobile) / fallback (desktop)
│   └── shared/
│       ├── connection_indicator.dart
│       └── message_status_icon.dart
└── webrtc/
    ├── data_channel_handler.dart          # Pipeline Signal+Ed25519 (⚠️ não wired)
    ├── invite_code_service.dart           # Encode/decode invite codes (AES-256-GCM opcional)
    ├── pairing_service.dart               # createChannel, joinViaQr, joinViaCode
    ├── peer_connection_manager.dart       # WebRTC ICE/DTLS/DataChannel
    ├── signaling_client.dart              # WebSocket WSS client
    └── turn_credentials_service.dart      # Fetch TURN creds do backend

server/
├── main.go                               # HTTP routes, config, startup
├── auth/
│   ├── jwt.go                            # JWT anônimo HS256
│   └── turn_credentials.go              # HMAC-SHA1 temp credentials
├── signaling/
│   ├── hub.go                            # In-memory rooms, broadcast
│   └── handler.go                        # WebSocket handler + JWT validation
└── turn/
    └── server.go                         # Pion TURN embedded
```

---

## 6. Decisões Técnicas Tomadas

| Decisão | Alternativa Considerada | Razão |
|---|---|---|
| `InviteCodeService` usa `QrPayload` como estrutura compartilhada | Novo tipo `InvitePayload` | Reutilização; diff entre QR e code é só expiração (exp=0) |
| `joinViaCode`/`joinViaQr` retornam `Channel?` (sem sessão Signal) | Retornar `({Channel, SignalSession})` | Signal quebrado em L-03/L-04; callers só usam `Channel` mesmo |
| `ChatScreen` cria seu próprio `PeerConnectionManager` | Receber como parâmetro externo | Encapsulamento; lifecycle ligado à tela |
| DB in-memory no Linux em vez de SQLite com path real | Arquivo em `~/.local/share/` | Evita problema de estado sujo entre testes; trocar em P2-D |
| `INSTANCE_ID` via `--dart-define` em vez de config file | `SharedPreferences` com ID | Isolamento em compile-time; sem estado extra no app |
| `context.Background()` no broadcast do Go | Context com timeout | Mensagens de sinalização são curtas; timeout adicionaria complexidade sem benefício real |
