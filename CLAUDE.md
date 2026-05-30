# CLAUDE.md — SafeChannel

## Visão do Projeto

SafeChannel é um mensageiro P2P seguro e descentralizado. Toda persistência de mensagens, mídias e metadados ocorre **exclusivamente nos dispositivos dos usuários**, criptografada localmente. O servidor existe apenas para sinalização WebRTC — nunca armazena conteúdo.

O diferencial do produto é combinar a robustez de segurança de um protocolo P2P (Briar/Signal) com a familiaridade de interfaces como WhatsApp/Telegram.

**Stack:** Flutter 3.x + Dart (mobile) · Go (servidor de sinalização + TURN) · SQLCipher (storage local) · Signal Protocol (E2E) · WebRTC (transporte P2P)

---

## Estrutura do Projeto

```
/
├── mobile/          # App Flutter (cliente)
│   ├── lib/
│   │   ├── crypto/  # Signal Protocol, Argon2id, Ed25519
│   │   ├── webrtc/  # flutter_webrtc, ICE, DataChannel
│   │   ├── db/      # SQLCipher (sqflite_sqlcipher)
│   │   ├── sync/    # Vector clocks, delta sync
│   │   ├── ui/      # Telas e componentes
│   │   └── models/  # Entidades locais
├── server/          # Backend Go
│   ├── signaling/   # WebSocket WSS, zero-storage
│   ├── turn/        # Pion TURN v2
│   └── auth/        # JWT + credenciais TURN temporárias
└── docs/
    ├── SafeChannel_Spec_v1.md
    └── WebRTC_Spec_Melhores_Praticas.md
```

---

## Princípios Inegociáveis

| Princípio | Regra |
|---|---|
| **Zero Trust Server** | O servidor NUNCA armazena mensagens, mídias ou metadados. Apenas estado de presença em memória, descartado ao desconectar. Sem banco de dados no servidor. |
| **Data Sovereignty** | Todas as chaves privadas residem no secure enclave do dispositivo (Android Keystore / iOS Keychain). Nunca em texto claro no filesystem. |
| **Double Encryption** | Todo payload usa Signal Protocol (Double Ratchet) **antes** de entrar no RTCDataChannel. DTLS-SRTP sozinho não é suficiente. |
| **Offline First** | Sistema funciona offline. Sincronização automática via Vector Clocks quando peers reconectam. |

---

## Specs Obrigatórias (MUST)

Estas specs definem comportamento que não pode ser ignorado:

| ID | Regra |
|---|---|
| **SPEC-ARCH-001** | Servidor zero-knowledge: sem storage, sem logs de conteúdo. |
| **SPEC-CHAN-002** | Argon2id para derivação de chave por senha: memória 64MB, iterações 3, paralelismo 4. Senha mínima 8 chars. |
| **SPEC-MSG-001** | Toda mensagem assinada com Ed25519. Receptor verifica antes de processar. Assinatura inválida → descarta silenciosamente. |
| **SPEC-MSG-002** | Arquivos >16 KB em chunks via RTCDataChannel (reliable, ordered). Cada chunk com SHA-256. Suporte a retransmissão por NACK. |
| **SPEC-SYNC-001** | Toda conexão P2P começa com troca de Vector Clocks. Delta sync bidirecional antes de qualquer nova mensagem. |
| **SPEC-SYNC-002** | Em canais com N membros, cada peer sincroniza individualmente com cada outro. Deduplicação por UUID. |
| **SPEC-CRYPTO-002** | Payload criptografado com Signal Protocol (Double Ratchet) antes de transmitir pelo DataChannel. |
| **SPEC-CRYPTO-003** | DB local criptografado AES-256-GCM. Chave derivada de PIN via Argon2id. Chave no secure enclave quando disponível. |
| **SPEC-DATA-001** | Nenhuma entidade do modelo de dados existe em servidor remoto. Deleção de conta = wipe criptográfico local. |
| **SPEC-UI-001** | Indicadores visuais de estado da conexão: P2P direto (verde), TURN relay (amarelo), offline (cinza). |

---

## Modelo de Dados Local

```dart
class User {
  String id;              // UUID v4
  String displayName;
  KeyPair identityKey;    // Ed25519 — permanente
  KeyPair signedPreKey;   // X25519 — rotacionado periodicamente
  DateTime createdAt;
}

class Channel {
  String id;              // UUID v4
  String name;
  Uint8List channelKey;   // AES-256 — chave simétrica do canal
  String inviteSecret;    // hashed — para QR/senha
  String createdBy;
  DateTime createdAt;
  ChannelSettings settings;
}

class ChannelSettings {
  Duration? autoDelete;
  int maxMembers;         // default: 50
  bool allowMedia;        // default: true
}

class ChannelMember {
  String channelId;
  String userId;
  Uint8List publicKey;    // Ed25519 — verificação de identidade
  String role;            // "admin" | "member"
  DateTime joinedAt;
  Map<String, int> vectorClock;
}

class Message {
  String id;              // UUID v4
  String channelId;
  String senderId;
  String type;            // "text" | "image" | "audio" | "video" | "file"
  Uint8List payload;      // encrypted (Signal Protocol)
  MessageMetadata? metadata;
  DateTime timestamp;
  Map<String, int> vectorClock;
  Uint8List signature;    // Ed25519
  String status;          // "pending" | "sent" | "delivered" | "read"
}
```

---

## Protocolo de Mensagens

### Estrutura do pacote (JSON → serializado → criptografado)

```json
{
  "id": "uuid-v4",
  "channel_id": "uuid-v4",
  "sender_pk": "base64...",
  "timestamp": 1716912000,
  "type": "text|image|audio|video|file",
  "payload": "encrypted-base64",
  "metadata": {
    "mime_type": "image/jpeg",
    "file_name": "foto.jpg",
    "size_bytes": 245760,
    "thumbnail": "base64...",
    "duration_ms": 15000
  },
  "vector_clock": { "A": 15, "B": 12 },
  "signature": "base64..."
}
```

### Limites de conteúdo

| Tipo | Formatos | Limite |
|---|---|---|
| Texto | UTF-8 | 64 KB |
| Imagem | JPEG, PNG, WebP, GIF | 25 MB |
| Áudio | Opus, AAC, MP3 | 100 MB |
| Vídeo | H.264, VP8, VP9 | 500 MB |
| Arquivo | Qualquer | 500 MB |

### Chunking (arquivos >16 KB)

```
+--------+----------+--------+-----------+------------------+
| msg_id | chunk_id | total  | checksum  |     payload      |
| 16 B   |  4 B     | 4 B    |  32 B     |  up to 16 KB     |
+--------+----------+--------+-----------+------------------+
```

Checksum: SHA-256 por chunk. Retransmissão via NACK. ACK a cada N chunks para feedback de progresso.

### Protocolo de sincronização offline

```
Peer A (online)                    Peer B (reconectou)
     |  <--- SYNC_REQUEST {vc_b} ------|
     |  --- SYNC_RESPONSE {delta_a} -->|
     |  <--- SYNC_ACK {received_ids} --|
     |  <--- SYNC_REQUEST_REVERSE -----|
     |  --- SYNC_ACK {received_ids} -->|
     [Ambos sincronizados]
```

---

## Sistema de Canais

### Métodos de ingresso (em ordem de preferência)

| Prioridade | Método | Risco MitM |
|---|---|---|
| 1 (melhor) | QR Code presencial | Zero |
| 2 | Senha pré-combinada (Argon2id) | Baixo |
| 3 | Link de convite (token temporário) | Médio |

QR Code contém: Channel ID + Channel Key (criptografada) + chave pública do criador + timestamp de expiração. **Expira em 5 minutos.**

---

## Arquitetura WebRTC — Base de Conhecimento

### Pilha de protocolos

```
┌─────────────────────────────────────────┐
│          App Flutter / Go SDK           │
├──────────────┬──────────────────────────┤
│  Audio/Video │     Dados (DataChannel)  │
│    (SRTP)    │     (SCTP sobre DTLS)    │
├──────────────┴──────────────────────────┤
│              DTLS (Criptografia)        │
├─────────────────────────────────────────┤
│          ICE (Traversal de NAT)         │
├──────────────┬──────────────┬───────────┤
│    STUN      │     TURN     │   UDP     │
└──────────────┴──────────────┴───────────┘
```

SafeChannel usa **apenas RTCDataChannel** (SCTP/DTLS) — sem áudio/vídeo por SRTP. Toda mídia trafega como dados binários criptografados pelo Signal Protocol.

### Fluxo de sessão WebRTC

1. App conecta ao servidor de sinalização via **WSS** com identificador anônimo (chave pública)
2. Troca de **SDP offer/answer** e **ICE candidates** pelo servidor
3. **Handshake DTLS** direto entre peers (servidor sai da equação)
4. **RTCDataChannel** estabelecido — mensagens trafegam com Double Ratchet + DTLS-SRTP
5. Fallback via **TURN relay** se conexão P2P direta falha — conteúdo permanece criptografado

### ICE candidates — tipos e prioridade

| Tipo | Origem | Custo |
|---|---|---|
| Host | IP local | Zero (P2P direto) |
| srflx | IP público via STUN | Baixo (P2P via NAT) |
| relay | Via TURN | Alto (relay no servidor) |

ICE tenta host → srflx → relay em paralelo, seleciona o melhor disponível.

### Credenciais TURN — fluxo obrigatório

**NUNCA** credenciais TURN fixas no app. Fluxo correto:

```go
// Backend Go — gera credenciais temporárias (validade 10min)
func GenerateTURNCredentials(username string) (string, string) {
    timestamp := time.Now().Add(10 * time.Minute).Unix()
    tempUser := fmt.Sprintf("%d:%s", timestamp, username)
    mac := hmac.New(sha1.New, []byte(turnSecret))
    mac.Write([]byte(tempUser))
    password := base64.StdEncoding.EncodeToString(mac.Sum(nil))
    return tempUser, password
}
```

```dart
// Flutter — busca credenciais antes de cada conexão
final creds = await fetchTurnCredentials(jwtToken);
final config = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {
      'urls': ['turn:servidor.com:3478'],
      'username': creds['username'],
      'credential': creds['password'],
    },
  ],
};
final pc = await createPeerConnection(config);
```

### Segurança de sinalização (obrigatório)

- Sinalização sempre via **WSS** (nunca WS em texto claro)
- Servidor autentica ambos os peers com **JWT de curta duração** antes de repassar mensagens
- Session IDs criptograficamente aleatórios (UUID v4)
- Servidor TURN com autenticação, rate limiting, bloqueio de relay para IPs privados (10.x, 192.168.x)

### Limitação conhecida do SRTP (não afeta SafeChannel diretamente)

Headers RTP não são criptografados pelo SRTP — expõem metadados de atividade de fala. Como SafeChannel não usa SRTP para áudio/vídeo (usa DataChannel), esta limitação não se aplica. Todo conteúdo vai pelo Signal Protocol antes de entrar no DataChannel.

---

## Stack Tecnológica

| Componente | Tecnologia |
|---|---|
| App Mobile | Flutter 3.x + Dart |
| WebRTC | `flutter_webrtc` |
| Criptografia E2E | `libsignal_protocol_dart` |
| Storage Local | `sqflite_sqlcipher` (SQLCipher) |
| WebSocket Client | `web_socket_channel` |
| QR Code | `qr_flutter` + `mobile_scanner` |
| Key Derivation | `argon2` (pointycastle) |
| Biometria | `local_auth` |
| Permissões | `permission_handler` |
| Servidor Sinalização | Go + `nhooyr.io/websocket` |
| TURN Server | Pion TURN v2 (`github.com/pion/turn/v2`) |
| JWT | `golang-jwt/jwt` |

---

## Requisitos Não-Funcionais

| Requisito | Meta |
|---|---|
| Latência P2P | Mensagem de texto < 200ms (P2P direto) |
| Tempo de Conexão | Handshake ICE + DTLS + sync < 3 segundos |
| Transferência de Mídia | Imagem 5 MB < 10s em 4G |
| Taxa de Sucesso P2P | >80% P2P direto, >98% com TURN |
| Sincronização | 100 msgs pendentes < 5 segundos |
| Bateria | Conexão idle < 2% bateria/hora |

---

## Roadmap

| Fase | Escopo |
|---|---|
| **MVP** | Chat 1:1 P2P: WebRTC, texto E2E, storage local criptografado, QR Code para parear |
| **v0.2** | Canais (grupos): criação, QR/senha, chat em grupo, gestão de membros |
| **v0.3** | Mídia e sincronização: imagens/áudio/vídeo, chunking, Vector Clocks offline |
| **v0.4** | UX: design system, notificações, mensagens efêmeras, biometria |
| **v1.0** | Produção: auditoria de segurança, testes de carga, publicação nas stores |

---

## Guias de Desenvolvimento

### Nunca faça

- Armazenar chaves privadas fora do secure enclave (Keystore/Keychain)
- Transmitir mensagens sem criptografia Signal Protocol (mesmo com DTLS ativo)
- Criar banco de dados no servidor de sinalização
- Embutir credenciais TURN fixas no app
- Usar sinalização sem TLS (WS em texto claro é proibido)
- Armazenar dados do usuário em servidor remoto (qualquer entidade do modelo de dados)

### Sempre faça

- Verificar assinatura Ed25519 antes de processar qualquer mensagem recebida
- Iniciar toda conexão P2P com troca de Vector Clocks (SPEC-SYNC-001)
- Usar chunking com SHA-256 para arquivos >16 KB (SPEC-MSG-002)
- Exibir indicadores visuais de estado da conexão (SPEC-UI-001)
- Derivar chaves de senha com Argon2id (memória 64MB, iter 3, paralelismo 4)
- Buscar credenciais TURN temporárias do backend antes de cada conexão

### Ao implementar criptografia

O Signal Protocol opera em duas fases:
1. **X3DH (ou PQXDH)** — troca de chaves inicial entre peers que nunca se comunicaram
2. **Double Ratchet** — criptografia de cada mensagem com chave única, fornecendo forward secrecy

Nunca implementar crypto manual. Usar `libsignal_protocol_dart` para o protocolo e `pointycastle` apenas para primitivas auxiliares (Argon2id, SHA-256 de chunks).

### Ao implementar WebRTC

- Sempre usar `RTCDataChannel` com `ordered: true` para mensagens e chunks de arquivos
- Monitorar `onConnectionState` para implementar lógica de reconexão
- Usar `getStats()` para coletar RTT, packet loss e tipo de candidato ICE selecionado
- Indicador visual muda baseado no tipo ICE selecionado: `host`/`srflx` → verde, `relay` → amarelo

### Ao implementar sincronização offline

- Vector Clock é um `Map<userId, int>` — cada mensagem enviada incrementa o contador do remetente
- Delta sync: comparar Vector Clocks e enviar apenas mensagens que o peer não possui
- Deduplicação por `message.id` (UUID v4) — ignorar mensagens já conhecidas
- Status da mensagem: `pending` → `sent` (DataChannel aberto) → `delivered` (ACK recebido) → `read`
