# Changelog — SafeChannel

Todas as mudanças significativas do projeto são documentadas aqui.
Formato baseado em [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased] — Signal Protocol E2E + Correções de Protocolo

**Foco:** Tornar a comunicação criptografada de ponta a ponta funcional em P2P local.
Comunicação bidirecional via Signal Protocol (X3DH + Double Ratchet) validada com dois peers no mesmo Linux.

### Adicionado

#### App Flutter

- **`DataChannelHandler.onSessionReady`**: callback disparado quando o primeiro `decrypt()` bem-sucedido confirma que o X3DH completou no lado do admin. Permite retry automático de mensagens pending.
- **`DataChannelHandler._sessionReady`**: flag que rastreia o estado de prontidão da sessão Signal; exposto via getter `sessionReady`.
- **`DataChannelHandler.onControlMessage`**: callback para roteamento de mensagens de controle (SYNC_REQUEST/RESPONSE/ACK) sem passar pelo pipeline Signal.
- **`KeyManager.ensureSignalIdentityKey()`**: migração automática no startup — gera `signal_identity_v1` se ausente no keystore (keystores criados antes da adição desta chave são atualizados sem exigir reset).
- **`ChatScreen._onDataChannelReady()`**: orquestra a inicialização completa do Signal Protocol ao abrir o DataChannel — seleciona papel X3DH (admin=responder, member=initiator), cria `DataChannelHandler`, `SyncManager`, e registra callbacks.
- **`ChatScreen._tearDownConnection()`**: destrói todos os recursos WebRTC/Signal de forma limpa antes de reconectar, enviando `leave` ao servidor para evitar conflitos de room.
- **`ChatScreen._scheduleReconnect()`**: reconexão automática 3 segundos após queda, ativada apenas após a primeira conexão bem-sucedida.
- **`ChatScreen._onRawMessage()`**: fallback para mensagens brutas quando Signal Protocol não está disponível (canal sem signal keys).
- **Logs de diagnóstico** em `DataChannelHandler._handleIncoming`: rastreia recebimento binário, parse do wire format, resultado do decrypt, salvamento no DB e emissão no stream.
- **`docs/SafeChannel_Troubleshooting.md`**: base de conhecimento com 6 bugs documentados (sintoma, causa, solução), 3 patterns recorrentes e checklist de diagnóstico.

#### Servidor Go

- **Logs estruturados** em `signaling/handler.go` e `signaling/hub.go`: cada evento (connect, join, leave, offer, answer, ice-candidate, disconnect) é logado com chave pública curta, ID de room curto e `delivered_to=N` (número de peers que receberam a mensagem). Facilita diagnóstico de problemas de sinalização.
- **`hub.roomSize()`** e **`Room.broadcast()` retornando contagem**: servidor agora reporta quantos peers estão em cada room e quantos receberam cada mensagem.

### Corrigido

#### Signal Protocol — bugs críticos de comunicação

- **BUG-15 `InviteCodeService`**: `generate()` não incluía `sik` (signal identity key) e `spksig` (pre-key signature) no payload do código de convite. `decode()` também não lia esses campos. Consequência: todo member que entrava via código de texto ficava com `signalKey=null` no `ChannelMember` e caía em raw bytes fallback, independentemente de reset ou novo canal. Corrigido em `mobile/lib/webrtc/invite_code_service.dart`.

- **BUG-17 `_buildStore`**: `InMemorySignalProtocolStore` era populado apenas com `storeSignedPreKey(1, ...)`. Quando o admin tentava descriptografar uma `PreKeySignalMessage` com `preKeyId=1`, o `SessionCipher` buscava a one-time pre-key com ID=1, não encontrava, e lançava `InvalidKeyIdException` — capturada silenciosamente, descartando a mensagem. Corrigido adicionando `storePreKey(1, PreKeyRecord(1, ecPreKeyPair))` em `signal_session.dart`.

- **BUG-18 `SignalSession.decrypt()`**: tentativa de parsear `PreKeySignalMessage` como `SignalMessage` primeiro pode modificar estado interno do `SessionCipher` antes de lançar exceção, corrompendo a tentativa subsequente. Invertida a ordem: `PreKeySignalMessage` é tentada primeiro (primeira mensagem após X3DH), com fallback para `SignalMessage` (mensagens subsequentes do Double Ratchet).

- **BUG-13 `_msgSub`**: mensagens de texto do `SyncManager` (SYNC_REQUEST/RESPONSE/ACK) apareciam como bolhas de chat quando o `DataChannelHandler` ainda não estava criado. Corrigido filtrando texto no `_msgSub` — texto no DataChannel é sempre protocolo de controle, nunca dado de usuário.

- **BUG-14 X3DH assimétrico**: `InvalidKeyException` ao admin tentar enviar antes de receber qualquer mensagem do member (X3DH incompleto no responder). `send()` agora retorna `bool` com try-catch, mensagem salva como `pending`, e retry automático via `onSessionReady` quando o X3DH completar.

- **BUG-16 keystore antigo**: `hasKeys()` verificava apenas `identity_key_v1` (Ed25519). Usuários com keystore pré-Signal Protocol não tinham `signal_identity_v1`, fazendo Alice criar canais com `signalIdentityKey=null`. Corrigido com `ensureSignalIdentityKey()` chamado no startup de usuários existentes.

#### Persistência e banco

- **`channel_members`**: adicionadas colunas `signal_key BLOB`, `signal_pre_key BLOB`, `signal_pre_key_sig BLOB` ao schema — necessárias para armazenar as chaves Signal do admin durante o join via QR/código.
- **`database.dart`**: corrigido `_desktopDbPath()` para incluir `INSTANCE_ID` no sufixo do diretório, isolando o banco entre instâncias de teste local (antes, apenas o keyring era isolado).

#### Modelo de dados

- **`ChannelMember`**: adicionados campos `signalKey`, `signalPreKey`, `signalPreKeySig` (nullable) ao modelo Dart e ao `toMap`/`fromMap`.

#### Pairing e invite code

- **`PairingService.createChannel()`**: `signalIdentityKey` e `preKeySignature` agora incluídos no `QrPayload` quando `signal_identity_v1` está disponível no keystore.
- **`PeerConnectionManager`**: adicionado callback `onDataChannelReady` para notificar o `ChatScreen` quando o DataChannel abre, em vez de processar tudo dentro do PCM.

### Alterado

- **`DataChannelHandler.send()`**: assinatura alterada de `Future<void>` para `Future<bool>` — retorna `false` em caso de falha de criptografia (ex: X3DH incompleto) em vez de lançar exceção não tratada.
- **`ChatScreen._retrySendPending()`**: agora verifica o retorno `bool` de `send()` antes de atualizar o status para `sent` — mensagens que falharam permanecem `pending`.
- **`ChatScreen._sendText()`**: ao `send()` retornar `false`, o status da mensagem na UI e no DB é revertido para `pending` imediatamente, com indicador visual correto para o usuário.
- **`SignalSession.decrypt()`**: ordem de tentativa invertida (PreKeySignalMessage antes de SignalMessage) para evitar corrupção de estado do cipher.
- **`docs/SafeChannel_Status.md`**: atualizado com data, estado de funcionamento validado, novos itens resolvidos (L-13 a L-18) e novas entradas na tabela de componentes.

---

## [0.1.0] — 2026-05-29 — Fase 1: MVP Base

**Foco:** Implementação completa da base do projeto — servidor de sinalização Go, app Flutter com todas as camadas de criptografia, banco local e UI funcional. Comunicação P2P estabelecida; Signal Protocol integrado mas não validado end-to-end.

### Adicionado

#### Servidor Go (`server/`)

- **Servidor de sinalização WebSocket** (`signaling/hub.go`, `signaling/handler.go`): roteamento de offer/answer/ice-candidate entre peers na mesma room. Zero storage — estado apenas em memória, descartado ao desconectar. (SPEC-ARCH-001)
- **JWT anônimo** (`auth/jwt.go`): identidade do peer = chave pública Ed25519. Token de curta duração gerado pelo servidor.
- **Credenciais TURN temporárias** (`auth/turn_credentials.go`): HMAC-SHA1 com validade de 10 minutos, geradas sob demanda. Nunca credenciais fixas no app. (SPEC-TURN-002)
- **TURN server embarcado** (`turn/server.go`): Pion TURN v2, relay para peers atrás de NAT simétrico. Bloqueia relay para IPs privados.

#### App Flutter (`mobile/`)

**Criptografia (`lib/crypto/`)**
- **`KeyManager`**: geração e persistência de três chaves criptográficas — `identity_key_v1` (Ed25519, assinatura), `signed_pre_key_v1` (X25519, DH), `signal_identity_v1` (X25519, Signal Protocol). Desktop: arquivo JSON com chmod 600. Mobile: flutter_secure_storage → Keystore/Keychain.
- **`MessageSigner`**: assinatura Ed25519 de cada payload antes de criptografar. Verificação no recebimento. (SPEC-MSG-001)
- **`SignalSession`**: wrapper sobre `libsignal_protocol_dart` — `initiate()` (X3DH pelo member), `receive()` (prepara store no admin), `encrypt()`/`decrypt()` (Double Ratchet). (SPEC-CRYPTO-002)

**Banco de dados (`lib/db/`)**
- **`database.dart`**: SQLCipher no mobile (chave Argon2id via PIN, SPEC-CRYPTO-003). sqflite_common_ffi no desktop com path persistente em `~/.local/share/safechannel/`. Schema com tabelas `users`, `channels`, `channel_members`, `messages`.
- **Repositórios**: `UserRepository`, `ChannelRepository`, `MessageRepository` com operações CRUD e queries por canal/status.

**Modelos (`lib/models/`)**
- `User`, `Channel`, `ChannelSettings`, `ChannelMember`, `Message`, `MessageMetadata`, `MessageStatus`, `MessageType` — implementação completa do modelo de dados local definido na spec.

**Sincronização (`lib/sync/`)**
- **`VectorClock`**: `Map<userId, int>` com `increment()`, `merge()`, `happensBefore()`, `isConcurrentWith()`. (SPEC-SYNC-001)
- **`SyncManager`**: protocolo bidirecional SYNC_REQUEST → SYNC_RESPONSE → SYNC_ACK sobre DataChannel. Delta sync baseado em vector clocks.

**WebRTC (`lib/webrtc/`)**
- **`PeerConnectionManager`**: ciclo de vida completo da conexão P2P — ICE gathering, buffering de candidatos, DTLS handshake, DataChannel (reliable+ordered). Indicador visual derivado de `getStats()` (host/srflx=verde, relay=amarelo). (SPEC-UI-001)
- **`SignalingClient`**: WebSocket WSS com JWT. Mensagens tipadas (offer/answer/ice-candidate/join/leave).
- **`DataChannelHandler`**: pipeline de envio (plaintext → Ed25519 sign → Signal encrypt → wire format → DataChannel) e recebimento (wire → Signal decrypt → verify → persist DB → stream).
- **`TurnCredentialsService`**: busca credenciais TURN temporárias do backend antes de cada conexão.
- **`PairingService`**: criação de canais com QrPayload (canal ID, chaves públicas, signal keys, assinatura, expiração 5min). Join via QR e via código de convite.
- **`InviteCodeService`**: geração e decodificação de códigos de convite de texto. Sem senha: base64url. Com senha: AES-256-GCM com chave Argon2id (SPEC-CHAN-002).

**UI (`lib/ui/`)**
- **Onboarding** (`onboarding_screen.dart`): criação de identidade local com PIN, geração das três chaves criptográficas.
- **PIN unlock** (`main.dart → _PinUnlockScreen`): desbloqueio da sessão existente com derivação Argon2id.
- **Lista de canais** (`contacts_screen.dart`): exibe canais locais. FAB para criar canal ou entrar com código. Navegação automática ao chat após join.
- **Criação de canal** (`create_channel_screen.dart`): nome do canal, geração de invite code, exibição de QR.
- **Join por código** (`join_code_screen.dart`): cola o código, senha opcional, join e navegação ao chat.
- **QR scanner** (`qr_scan_screen.dart`): mobile_scanner para iOS/Android; fallback texto no desktop.
- **Chat** (`chat_screen.dart`): conexão WebRTC, indicador de status P2P/TURN/offline, envio Signal-criptografado, status de mensagem (pending/sent/delivered/read), scroll automático.
- **Indicadores compartilhados**: `ConnectionIndicatorWidget` (cadeado colorido), `MessageStatusIcon` (⏱/✓/✓✓/✓✓azul).

**Testes automatizados (`mobile/test/`)**
- `signal_session_test.dart`: X3DH two-party, Double Ratchet bidirecional, forward secrecy (3 testes)
- `message_signer_test.dart`: sign/verify Ed25519, payload alterado, chave errada (4 testes)
- `vector_clock_test.dart`: increment, merge, happensBefore, isConcurrentWith (5 testes)
- `sync_manager_test.dart`: protocolo completo SYNC_REQUEST→RESPONSE→ACK (3 testes)
- `invite_code_service_test.dart`: encode/decode, senha, expiração (7 testes)
- **Total: 22 testes passando**

#### Documentação (`docs/`)

- `SafeChannel_Spec_v1.md`: especificação completa do produto
- `SafeChannel_Status.md`: status de implementação com tabelas de componentes e débito técnico
- `WebRTC_Spec_Melhores_Praticas.md`: referência técnica de WebRTC
- `CLAUDE.md`: instruções de desenvolvimento, specs obrigatórias e guias de implementação

---

[Unreleased]: https://github.com/LeonardoAValerio/dead-sec/compare/main...HEAD
[0.1.0]: https://github.com/LeonardoAValerio/dead-sec/releases/tag/v0.1.0
