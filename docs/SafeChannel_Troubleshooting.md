# SafeChannel — Base de Conhecimento: Problemas e Soluções

Registro técnico de todos os problemas encontrados durante o desenvolvimento e como foram resolvidos.
Útil para entender decisões de implementação e diagnosticar regressões futuras.

---

## BUG-01 — SYNC_REQUEST aparecia como bolha de chat

**Sintoma:** Ao member entrar no canal, a primeira coisa que aparecia no chat de ambos os lados era uma bolha com o texto `{"type":"SYNC_REQUEST","channel_id":"...","vc":{...}}`.

**Causa raiz:** Race condition no `_msgSub`. Quando o `DataChannelHandler` ainda não tinha sido criado no lado do admin (durante o `await session.receive()`), o `SyncManager` do member já enviava o SYNC_REQUEST como mensagem de **texto** no DataChannel. O `_msgSub` recebia essa mensagem, `_handler == null`, e chamava `_onRawMessage()` que a persistia como se fosse dado de usuário.

**Arquivos afetados:** `mobile/lib/ui/chat/chat_screen.dart`

**Solução:** Adicionar filtro no `_msgSub`:
```dart
_msgSub = _peerManager!.onMessage.listen((rtcMsg) {
  if (_handler != null) return;
  if (!rtcMsg.isBinary) return; // texto = sempre controle, nunca dado de usuário
  _onRawMessage(rtcMsg.binary);
});
```
Mensagens de texto no DataChannel são exclusivamente protocolo de controle (SYNC_REQUEST/RESPONSE/ACK). Dados de usuário sempre chegam como binário (Signal Protocol).

**Por que não reaparecerá:** O `DataChannelHandler._handleIncoming` já trata texto como controle via `onControlMessage`. O `_msgSub` é apenas um fallback para quando o handler ainda não existe — e nesse contexto texto nunca é dado de usuário.

---

## BUG-02 — InvalidKeyException ao admin tentar enviar primeiro

**Sintoma:** Log `Assertion failed: Instance of 'InvalidKeyException'` ao admin tentar enviar uma mensagem. A mensagem ficava com ícone de clock (pending) e nunca era entregue.

**Causa raiz:** Assimetria inerente ao Signal Protocol X3DH. O **member** (initiator) chama `session.initiate(peerBundle)` e pode criptografar imediatamente. O **admin** (responder) chama `session.receive()` que apenas prepara o store — o ratchet só é inicializado quando o admin **descriptografa** a primeira `PreKeySignalMessage` do member. Se o admin tenta `session.encrypt()` antes disso, `getSenderRatchetKey()` retorna null e lança `InvalidKeyException`.

**Arquivos afetados:** `mobile/lib/webrtc/data_channel_handler.dart`, `mobile/lib/ui/chat/chat_screen.dart`

**Solução em três partes:**

1. `send()` retorna `bool` em vez de `void`, capturando a exceção:
```dart
Future<bool> send(Message message) async {
  try {
    ...
    return true;
  } catch (e) {
    debugPrint('[DCH] send failed: $e');
    return false;
  }
}
```

2. `DataChannelHandler` expõe `_sessionReady` e `onSessionReady`:
```dart
bool _sessionReady = false;
void Function()? onSessionReady;
// Em _handleIncoming, após primeiro decrypt bem-sucedido:
if (!_sessionReady) { _sessionReady = true; onSessionReady?.call(); }
```

3. `ChatScreen` registra o callback e tenta reenviar pendentes quando o X3DH completar:
```dart
_handler!.onSessionReady = () { if (mounted) _retrySendPending(); };
```

**Comportamento resultante:** O admin pode tentar enviar antes do member. A mensagem é salva como pending. Quando o member enviar qualquer coisa (primeira `PreKeySignalMessage`), o X3DH completa, `onSessionReady` dispara, e os pending são reenviados automaticamente.

**Limitação conhecida:** O admin **nunca** pode ser o primeiro a ter sucesso em tempo real — sempre depende de receber primeiro do member. Para eliminar essa assimetria, seria necessário bidirectional key exchange (ambos os peers trocam signal keys na abertura do DataChannel e ambos chamam `initiate()`).

---

## BUG-03 — Signal keys ausentes no invite code de texto

**Sintoma:** Bob entrava via código de convite, mas os logs mostravam `[Chat] Signal keys absent — raw bytes fallback`. A comunicação acontecia sem criptografia Signal (raw bytes). Qualquer mensagem enviada pelo Bob chegava como bytes brutos que o admin não conseguia descriptografar.

**Causa raiz:** `InviteCodeService.generate()` construía o payload **sem** os campos `sik` (signal identity key) e `spksig` (pre-key signature), que são os campos necessários para o member construir a `PreKeyBundle` e iniciar o X3DH. O QR code (`QrPayload.encode()`) incluía esses campos, mas o invite code de texto não.

```dart
// ANTES (bugado) — faltavam sik e spksig
final inner = {
  'cid': qr.channelId,
  'name': qr.channelName,
  'pk': base64Encode(qr.creatorPublicKey),
  'spk': base64Encode(qr.signedPreKey),
  // SEM 'sik' e 'spksig'!
};
```

**Arquivo afetado:** `mobile/lib/webrtc/invite_code_service.dart`

**Solução:**
```dart
final inner = {
  'cid': qr.channelId,
  'name': qr.channelName,
  'pk': base64Encode(qr.creatorPublicKey),
  'spk': base64Encode(qr.signedPreKey),
  if (qr.signalIdentityKey != null) 'sik': base64Encode(qr.signalIdentityKey!),
  if (qr.preKeySignature != null) 'spksig': base64Encode(qr.preKeySignature!),
};
```
E em `decode()`, leitura dos campos opcionais:
```dart
signalIdentityKey: inner['sik'] != null ? base64Decode(inner['sik'] as String) : null,
preKeySignature: inner['spksig'] != null ? base64Decode(inner['spksig'] as String) : null,
```

**Impacto:** Todo invite code gerado antes deste fix deixa os membros em raw bytes fallback. É necessário regenerar o invite code após o fix.

---

## BUG-04 — signal_identity_v1 ausente em keystores antigos

**Sintoma:** Alice criava um canal e o invite code/QR não continha as signal keys (`sik`/`spksig` nulos). O log mostrava `[Chat] Signal role=MEMBER — peer signalKey=false sig=false` no lado do member.

**Causa raiz:** `KeyManager.hasKeys()` verifica apenas a presença de `identity_key_v1` (Ed25519). Se o usuário rodou o onboarding com uma versão anterior que não gerava `signal_identity_v1` (X25519 para Signal Protocol), o keystore ficava sem essa chave. Nas inicializações seguintes, `hasKeys()` retornava true (a Ed25519 existe) e o app pulava o onboarding — `signal_identity_v1` nunca era gerada. Ao criar um canal, `loadSignalIdentityKeyPair()` lançava exceção, capturada silenciosamente, e o QR/código ficava com `signalIdentityKey: null`.

**Arquivo afetado:** `mobile/lib/crypto/key_manager.dart`, `mobile/lib/main.dart`

**Solução — migração automática no startup:**
```dart
// KeyManager
static Future<void> ensureSignalIdentityKey() async {
  final existing = await _read(_kSignalIdentityKey);
  if (existing != null) return;
  final signalIdentityPair = await _x25519.newKeyPair();
  final privBytes = await signalIdentityPair.extractPrivateKeyBytes();
  await _write(_kSignalIdentityKey, base64Encode(privBytes));
}

// main.dart — _Loader._decide()
} else {
  await KeyManager.ensureSignalIdentityKey(); // migra keystores antigos
  if (!mounted) return;
  Navigator.of(context).pushReplacement(..._PinUnlockScreen()...);
}
```

**Nota:** Mesmo após a migração, canais criados com a chave antiga continuam sem signal keys no invite code armazenado localmente. É necessário criar um novo canal ou regenerar o invite code para que as signal keys sejam incluídas.

---

## BUG-05 — One-time pre-key não registrada na store Signal

**Sintoma:** O admin recebia a `PreKeySignalMessage` do member mas a descriptografia falhava silenciosamente. O log mostrava `[DCH] _handleIncoming binary (X bytes)` mas nunca `[DCH] decrypt ok`. As mensagens eram descartadas sem chegar à UI.

**Causa raiz:** `buildPeerBundle` e `buildLocalBundle` criavam a `PreKeyBundle` com `preKeyId=1` referenciando a signed pre-key como one-time pre-key. Quando o admin tentava descriptografar, o `SessionCipher.decrypt()` buscava a one-time pre-key com ID=1 no `InMemorySignalProtocolStore`, mas `_buildStore()` só chamava `storeSignedPreKey(1, ...)` — **nunca** registrava a one-time pre-key. A busca falhava com `InvalidKeyIdException`, capturada silenciosamente.

**Arquivo afetado:** `mobile/lib/crypto/signal_session.dart`

**Solução:**
```dart
// _buildStore() — adicionar após storeSignedPreKey
await store.storePreKey(1, PreKeyRecord(1, ecPreKeyPair));
```

**Contexto de design:** No Signal Protocol canônico, signed pre-key e one-time pre-key são chaves diferentes. Nesta implementação simplificada, a mesma chave é usada para ambas (IDs iguais, mesmo par de chaves). Isso é aceitável para o MVP mas deveria ser separado em produção — a one-time pre-key precisa ser descartada após uso (o que o `InMemorySignalProtocolStore` faz automaticamente; como o store é recriado a cada conexão, a chave é re-adicionada).

---

## BUG-06 — Ordem errada no decrypt() corrompendo estado do cipher

**Sintoma:** Em alguns cenários, mesmo com a one-time pre-key registrada, a descriptografia falhava. O `SessionCipher` ficava em estado inconsistente.

**Causa raiz:** `SignalSession.decrypt()` tentava parsear como `SignalMessage` primeiro:
```dart
// ANTES — ordem problemática
try {
  final msg = SignalMessage.fromSerialized(ciphertext); // pode modificar estado interno
  return await _cipher.decryptFromSignal(msg);          // falha na 1ª msg (sem sessão)
} catch (_) {
  final preKeyMsg = PreKeySignalMessage(ciphertext);    // tenta como PKM
  return await _cipher.decrypt(preKeyMsg);              // estado já corrompido
}
```

Se `_cipher.decryptFromSignal()` modificava estado interno antes de lançar a exceção (ausência de sessão), a tentativa subsequente com `PreKeySignalMessage` encontrava o cipher em estado inconsistente.

**Arquivo afetado:** `mobile/lib/crypto/signal_session.dart`

**Solução — inverter a ordem:**
```dart
// DEPOIS — PreKeySignalMessage primeiro (primeira mensagem após X3DH)
try {
  final preKeyMsg = PreKeySignalMessage(ciphertext);
  return Uint8List.fromList(await _cipher.decrypt(preKeyMsg));
} catch (_) {
  // Mensagem subsequente (Double Ratchet)
  final msg = SignalMessage.fromSerialized(ciphertext);
  return Uint8List.fromList(await _cipher.decryptFromSignal(msg));
}
```

**Por que funciona:** Parsear um `SignalMessage` como `PreKeySignalMessage` falha rapidamente (formato diferente) sem modificar estado. Parsear um `PreKeySignalMessage` como `SignalMessage` pode ter efeitos colaterais. A ordem PreKeySignalMessage-first é segura em ambos os cenários.

---

## PATTERN-01 — Mensagens binárias chegando antes do handler estar pronto

**Contexto:** O `DataChannelHandler` é criado de forma assíncrona em `_onDataChannelReady()`, após DB reads e `session.receive/initiate()`. O `PeerConnectionManager` seta `ch.onMessage = _messageController.add` inicialmente. Existe uma janela de tempo entre o DataChannel abrir e o handler tomar conta do `ch.onMessage`.

**Problema:** Se qualquer mensagem binária chegar durante essa janela, vai para `_messageController` → `_msgSub` → `_onRawMessage()` (corrupção de dados).

**Solução implementada:** No início de `_onDataChannelReady()` (antes de qualquer `await`), `ch.onMessage` é sobrescrito com um buffer local. Após o handler ser criado, todas as mensagens buffered são replayed via `DataChannelHandler.processRawMessage()`. Isso também viabiliza o SESSION_HELLO automático do member (ver BUG-09).

---

---

## BUG-07 — Member entra antes do owner: P2P nunca estabelece

**Sintoma:** Se Bob (member/offerer) entra no canal antes de Alice (admin/answerer), o indicador fica cinza para ambos indefinidamente. Alice entra depois mas a conexão não acontece.

**Causa raiz:** O papel é determinado pelo role no DB (admin=answerer, member=offerer), independente da ordem de chegada. Quando Bob entra primeiro:
1. Bob envia offer → servidor faz broadcast → `delivered_to=0` (Alice não está na room) → offer perdida
2. Alice entra depois → chama `startAsAnswerer()` → aguarda offer que nunca chega

O servidor **não notificava peers existentes quando um novo peer entrava**. A mensagem `join` era apenas registrada no hub sem broadcast para outros.

**Arquivos afetados:** `server/signaling/hub.go`, `mobile/lib/webrtc/peer_connection_manager.dart`, `mobile/lib/ui/chat/chat_screen.dart`

**Solução:** Servidor faz broadcast de `peer_joined` quando um peer entra na room:
```go
// hub.go — Join()
func (h *Hub) Join(roomID string, p *peer) {
    h.getOrCreateRoom(roomID).add(p)
    h.notifyPeers(roomID, p.pubKey, "peer_joined") // novo
}
```
O member (offerer) recebe `peer_joined` → reseta WebRTC → envia nova offer:
```dart
// chat_screen.dart
Future<void> _onPeerJoined() async {
  if (_isAdmin == true) return; // admin só aguarda offer
  await _peerManager?.resetWebRTC();
  await _peerManager?.startAsOfferer(); // nova offer para o admin recém-chegado
}
```

---

## BUG-08 — Reconexão parcial quebra P2P

**Sintoma:** Alice e Bob estão conectados. Um deles sai do canal e volta. A conexão P2P não se restabelece — é necessário os dois saírem, o owner entrar e o member entrar.

**Causa raiz:** Quando um peer faz `leave`, o servidor **não notificava o peer restante**. O peer restante ficava com `RTCPeerConnection` em estado morto. Quando o peer saído voltava, o peer restante ainda tinha o PC antigo em estado inconsistente.

**Arquivos afetados:** `server/signaling/hub.go`, `mobile/lib/webrtc/peer_connection_manager.dart`, `mobile/lib/ui/chat/chat_screen.dart`

**Solução:** Servidor faz broadcast de `peer_left` quando um peer sai:
```go
// hub.go — Leave()
func (h *Hub) Leave(roomID, pubKey string) {
    h.notifyPeers(roomID, pubKey, "peer_left") // notifica ANTES de remover
    r.remove(pubKey)
    h.cleanupRoom(roomID)
}
```
Peer restante recebe `peer_left` → fecha WebRTC (mantém WebSocket de sinalização):
```dart
Future<void> _onPeerLeft() async {
  await _peerManager?.resetWebRTC(); // fecha PC+DataChannel, mantém signaling
  if (_isAdmin == true) {
    await _peerManager?.startAsAnswerer(); // volta ao modo espera
  }
  // member apenas aguarda o próximo peer_joined
}
```
Quando o peer saído retorna: servidor envia `peer_joined` → member re-envia offer → conexão estabelecida.

**Detalhe:** `PeerConnectionManager.resetWebRTC()` fecha PC + DataChannel sem tocar no WebSocket. `_listenSignaling()` tem guard de single-subscription para que `startAsAnswerer()/startAsOfferer()` chamados múltiplas vezes não criem listeners duplicados.

---

## BUG-09 — Admin precisa aguardar mensagem do usuário para X3DH completar

**Sintoma:** Após conectar, o admin tenta enviar uma mensagem mas ela fica como pending indefinidamente — a não ser que o member envie algo primeiro.

**Causa raiz:** X3DH é assimétrico. O admin (responder) completa o ratchet **apenas ao descriptografar** a primeira `PreKeySignalMessage` do member. Sem uma mensagem automática do member ao conectar, o admin fica bloqueado até o usuário digitar.

**Tentativa anterior:** `sendSessionHello()` implementado mas falhou porque a mensagem chegava ao admin antes de `_handler` ser criado (janela de race condition) → consumida por `_msgSub → _onRawMessage` → ratchet do member avançava → mensagens subsequentes eram `SignalMessage` que o admin não conseguia descriptografar.

**Solução — early buffer + SESSION_HELLO:**
1. No início de `_onDataChannelReady()` (antes de qualquer await), `ch.onMessage` é sobrescrito para bufferizar mensagens
2. Após o handler ser criado, o buffer é replayed via `processRawMessage()`
3. Member chama `sendSessionHello()` que envia uma `PreKeySignalMessage` mínima (type=sessionInit)
4. Admin recebe via `_handleIncoming` → descriptografa → X3DH completa → `onSessionReady` → retry dos pending

**Arquivos afetados:** `mobile/lib/webrtc/data_channel_handler.dart`, `mobile/lib/ui/chat/chat_screen.dart`, `mobile/lib/models/message_type.dart`

---

## PATTERN-02 — Keystores compartilhados em testes locais

**Contexto:** Em Linux desktop, o `_FileKeyStore` usa `~/.local/share/safechannel/keystore.json`. Sem `INSTANCE_ID`, duas instâncias compartilham o mesmo arquivo e as mesmas chaves criptográficas.

**Por que é crítico:** Signal Protocol X3DH exige que iniciador e respondedor tenham identidades distintas. Com chaves idênticas, o DH produz resultado matematicamente inválido.

**Solução:** Sempre usar `--dart-define=INSTANCE_ID=alice` e `--dart-define=INSTANCE_ID=bob` ao rodar duas instâncias localmente. Isso isola:
- Keystore: `~/.local/share/safechannel_alice/keystore.json`
- Banco: `~/.local/share/safechannel_alice/safechannel.db`

**Ver também:** `docs/SafeChannel_Status.md` seção "Testar com dois peers no mesmo Linux".

---

## PATTERN-03 — Dados de canal antigo não são migrados automaticamente

**Contexto:** O `ChannelMember` armazena `signalKey`, `signalPreKey` e `signalPreKeySig` que vêm do invite code/QR no momento do join. Esses dados ficam no banco e **não são atualizados** quando o criador do canal atualiza suas chaves.

**Implicação:** Se Alice criar um canal sem signal keys (bug antigo) e Bob entrar, Bob fica com `signalKey=null` para sempre naquele canal — mesmo após Alice gerar as signal keys. O dado errado está no DB de Bob.

**Solução:** Regenerar o invite code após qualquer mudança nas signal keys do criador, e Bob re-entrar no canal com o novo código. Não há migração automática porque o criador não tem como "empurrar" atualizações de chave para membros existentes sem um mecanismo de renovação de chave (fora do escopo do MVP).

---

## Checklist de Diagnóstico — Comunicação P2P não funciona

Quando mensagens não cruzam entre peers, verificar nesta ordem:

```
1. [ ] Indicador P2P está verde? (se cinza → problema de sinalização/ICE)
2. [ ] Log: "[Chat] Signal role=MEMBER — peer signalKey=true sig=true"?
        → se false: usar RESET_ON_START=true + novo canal + novo invite code
3. [ ] Log: "[Chat] Signal X3DH initiated ✓" no member?
        → se ausente: verificar se o invite code foi gerado após o BUG-03 fix
4. [ ] Log: "[DCH] _handleIncoming binary" no admin quando member envia?
        → se ausente: DataChannel não está entregando mensagens (problema de rede/ICE)
5. [ ] Log: "[DCH] decrypt ok" aparece?
        → se ausente: Signal Protocol falhou — verificar BUG-05 e BUG-06
6. [ ] Log: "[DCH] message saved → emitting to stream"?
        → se ausente: mensagem já existia no DB (deduplicação) ou erro de DB
7. [ ] Log: "[Chat] received message via Signal ✓"?
        → se ausente: _handlerMsgSub não está recebendo (raro, verificar lifecycle do widget)
```
