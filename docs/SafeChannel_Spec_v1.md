# SPEC — SafeChannel

## Mensageiro P2P Seguro e Descentralizado

**Arquitetura, Segurança, Protocolo de Sincronização e Design**

Baseado na Spec WebRTC — Melhores Práticas v1.0 | Protocolo Signal (Double Ratchet / X3DH) | Briar P2P Architecture | NAT Traversal (ICE/STUN/TURN) | WebRTC Data Channels

**Versão 1.0 — Maio 2026**

Contexto: Aplicativo Mobile (Flutter/Dart) com servidor mínimo de sinalização (Go)

---

## Sumário

1. [Introdução e Visão do Produto](#1-introdução-e-visão-do-produto)
2. [Arquitetura do Sistema](#2-arquitetura-do-sistema)
3. [Sistema de Canais (Grupos)](#3-sistema-de-canais-grupos)
4. [Protocolo de Mensagens e Sincronização](#4-protocolo-de-mensagens-e-sincronização)
5. [Criptografia e Segurança](#5-criptografia-e-segurança)
6. [Modelo de Dados Local](#6-modelo-de-dados-local)
7. [Design e Interface do Usuário](#7-design-e-interface-do-usuário)
8. [Stack Tecnológica Recomendada](#8-stack-tecnológica-recomendada)
9. [Requisitos Não-Funcionais](#9-requisitos-não-funcionais)
10. [Roadmap de Desenvolvimento](#10-roadmap-de-desenvolvimento)

---

## 1. Introdução e Visão do Produto

SafeChannel é um aplicativo de mensagens instantâneas com arquitetura peer-to-peer, projetado para oferecer comunicação segura sem dependência de servidores centralizados para armazenamento de dados. Toda a persistência de mensagens, mídias e metadados ocorre exclusivamente nos dispositivos dos usuários, criptografada localmente.

O produto nasce da lacuna identificada no mercado: ferramentas P2P seguras existentes (Briar, Session, Tox) priorizam segurança técnica mas negligenciam a experiência do usuário. SafeChannel combina a robustez de segurança de um protocolo P2P com a familiaridade de interfaces como WhatsApp, Telegram e Discord.

### 1.1. Escopo deste Documento

Esta spec cobre toda a cadeia do produto SafeChannel: modelo de dados e armazenamento local, protocolo de comunicação P2P via WebRTC, sistema de canais com acesso por QR Code/senha, sincronização offline de mensagens, suporte a múltiplos tipos de mídia, e diretrizes de design de interface. Os princípios de WebRTC seguem a Spec WebRTC — Melhores Práticas v1.0.

### 1.2. Princípios Fundamentais

| Princípio | Descrição |
|---|---|
| **Zero Trust Server** | O servidor de sinalização nunca vê conteúdo. Existe apenas para conectar peers. |
| **Data Sovereignty** | Dados pertencem exclusivamente ao usuário. Armazenamento 100% local e criptografado. |
| **UX First Security** | Segurança não deve impor complexidade ao usuário. Interface intuitiva como WhatsApp/Telegram. |
| **Offline Resilient** | Sistema funciona offline. Sincronização automática quando peers reconectam. |
| **Open Standards** | Baseado em WebRTC, DTLS-SRTP, Signal Protocol. Sem protocolos proprietários. |

### 1.3. Público-Alvo

Jornalistas e fontes confidenciais, advogados em comunicação com clientes, profissionais de saúde trocando informações sensíveis (LGPD/HIPAA), ativistas em ambientes com vigilância, empresas preocupadas com espionagem industrial, e qualquer pessoa que valorize privacidade real em suas comunicações.

### 1.4. Fontes de Referência

| Documento | Fonte | Foco |
|---|---|---|
| Spec WebRTC — Melhores Práticas v1.0 | Documento interno | Arquitetura WebRTC |
| Signal Protocol Specs | signal.org/docs | Criptografia E2E |
| Briar Architecture | briarproject.org | P2P descentralizado |
| IETF RTCWEB Security Arch. | rtcweb-wg.github.io | Segurança formal |
| NAT Traversal Guide | pinggy.io / webrtc.link | ICE/STUN/TURN |

---

## 2. Arquitetura do Sistema

SafeChannel adota um modelo híbrido: servidor mínimo de sinalização (apenas para descoberta de peers) combinado com comunicação direta P2P via WebRTC para toda troca de dados. O servidor nunca armazena mensagens, mídias ou metadados de conversa.

### 2.1. Componentes da Arquitetura

| Componente | Tecnologia | Localização | Função |
|---|---|---|---|
| **App Cliente** | Flutter + flutter_webrtc | Dispositivo móvel | Interface, criptografia, storage local |
| **Sinalização** | Go + WebSocket (WSS) | Servidor cloud | Descoberta de peers, troca de SDP/ICE |
| **TURN/STUN** | Pion TURN / coturn | Servidor cloud | NAT traversal, relay de emergência |
| **Storage Local** | SQLCipher / ObjectBox | Dispositivo móvel | Persistência criptografada de dados |
| **Criptografia** | Signal Protocol (libsignal) | Dispositivo móvel | E2E encryption, Double Ratchet |

### 2.2. Fluxo de Comunicação

O fluxo completo de uma sessão de comunicação segue estas etapas:

1. **Autenticação local:** Usuário abre o app e autentica localmente (PIN/biometria). Nenhuma credencial é enviada ao servidor.
2. **Conexão ao sinalização:** App conecta ao servidor de sinalização via WSS, enviando apenas um identificador anônimo (chave pública).
3. **Troca de metadados:** Servidor de sinalização facilita troca de SDP offers/answers e ICE candidates entre peers.
4. **Conexão P2P:** Conexão direta P2P é estabelecida via WebRTC (DTLS-SRTP). Servidor sai da equação.
5. **Troca de mensagens:** Mensagens trafegam via RTCDataChannel, criptografadas com Signal Protocol (Double Ratchet).
6. **Persistência local:** Dados recebidos são persistidos localmente com criptografia (SQLCipher/ObjectBox).
7. **Fallback TURN:** Se conexão P2P falha, TURN relay retransmite pacotes criptografados (sem acesso ao conteúdo).

> **SPEC-ARCH-001: Servidor Zero-Knowledge** `[MUST]`
>
> O servidor de sinalização NÃO DEVE armazenar mensagens, mídias, metadados de conversa, ou qualquer dado que permita reconstituir o conteúdo da comunicação.
> O servidor DEVE manter em memória apenas o estado de presença (quem está online) e descartar tudo ao desconectar.
> Nenhum banco de dados é necessário no servidor.

### 2.3. Diagrama de Arquitetura Simplificado

```
+------------------+         WSS (SDP/ICE)         +------------------+
|   Dispositivo A  | <---------------------------> | Servidor Sinali- |
|   (Flutter App)  |                               | zação (Go + WSS) |
|                  |         WSS (SDP/ICE)         |   [Sem storage]  |
|  - SQLCipher     | <-----------+   +-----------> +------------------+
|  - Signal Proto  |             |   |
|  - WebRTC Stack  |             |   |             +------------------+
+--------+---------+             +---+-----------> |   STUN / TURN    |
         |                           |             |  (Pion / coturn) |
         | WebRTC P2P (DTLS-SRTP)    |             +------------------+
         | RTCDataChannel            |
         v                           v
+------------------+         +------------------+
|   Dispositivo B  |         |   Dispositivo C  |
|   (Flutter App)  |         |   (Flutter App)  |
|  - SQLCipher     |         |  - SQLCipher     |
|  - Signal Proto  |         |  - Signal Proto  |
|  - WebRTC Stack  |         |  - WebRTC Stack  |
+------------------+         +------------------+
```

---

## 3. Sistema de Canais (Grupos)

O conceito central do SafeChannel é o **Canal** — um grupo de comunicação com acesso controlado. Canais funcionam de forma análoga a grupos do WhatsApp ou servidores do Discord, mas sem qualquer registro central.

### 3.1. Criação de Canal

Qualquer usuário pode criar um canal. Ao criar, o app gera localmente:

- **Channel ID:** UUID v4 único, gerado criptograficamente.
- **Channel Key:** Chave simétrica AES-256 para criptografia do canal.
- **Invite Secret:** Segredo para geração de QR Code ou senha de convite.
- **Member List:** Lista local de chaves públicas dos membros do canal.

### 3.2. Métodos de Ingresso

| Método | Fluxo | Segurança |
|---|---|---|
| **QR Code (presencial)** | Criador exibe QR Code. Convidado escaneia. Troca de chaves imediata via canal local. | Máxima. Troca de chaves verificada presencialmente, sem intermediário. |
| **Senha/Código** | Criador define senha. Convidado insere senha no app. Derivação de chave via Argon2id. | Alta. Dependência da força da senha. Argon2id protege contra brute force. |
| **Link de Convite** | Criador gera link com token temporário. Convidado clica e faz handshake criptográfico. | Média-alta. Link pode ser interceptado. Token expira em minutos. |

> **SPEC-CHAN-001: QR Code como Método Preferencial** `[SHOULD]`
>
> O QR Code DEVE ser o método preferencial de ingresso, pois é o único que garante troca de chaves sem intermediário de rede.
> O QR Code DEVE conter: Channel ID, Channel Key (criptografada), chave pública do criador, e timestamp de expiração.
> QR Codes DEVEM expirar em no máximo 5 minutos.

> **SPEC-CHAN-002: Derivação de Chave por Senha** `[MUST]`
>
> Quando o método de ingresso for por senha, a Channel Key DEVE ser derivada usando Argon2id com parâmetros mínimos: memória 64MB, iterações 3, paralelismo 4.
> Senhas DEVEM ter no mínimo 8 caracteres.
> O app DEVE exibir um medidor de força da senha ao usuário.

### 3.3. Gestão de Membros

O criador do canal é o administrador inicial. Permissões podem ser delegadas. Cada membro armazena localmente a lista de chaves públicas de todos os outros membros do canal, permitindo verificar a identidade de cada peer durante a conexão WebRTC.

| Papel | Permissões | Restrições |
|---|---|---|
| **Admin** | Convidar/remover membros, alterar senha, excluir canal, promover outros a admin. | Mínimo 1 admin por canal. Não pode remover a si mesmo se for o único. |
| **Membro** | Enviar/receber mensagens, mídias e arquivos. Convidar novos membros (se permitido). | Não pode alterar configurações do canal ou remover membros. |

---

## 4. Protocolo de Mensagens e Sincronização

### 4.1. Estrutura de uma Mensagem

Cada mensagem é um pacote criptografado contendo os seguintes campos:

```json
{
  "id":           "uuid-v4",
  "channel_id":   "uuid-v4",
  "sender_pk":    "base64...",
  "timestamp":    1716912000,
  "type":         "text|image|audio|video|file",
  "payload":      "encrypted-base64",
  "metadata": {
    "mime_type":  "image/jpeg",
    "file_name":  "foto.jpg",
    "size_bytes": 245760,
    "thumbnail":  "base64...",
    "duration_ms": 15000
  },
  "vector_clock": { "A": 15, "B": 12 },
  "signature":    "base64..."
}
```

### 4.2. Tipos de Conteúdo Suportados

| Tipo | Formatos | Limite | Transferência |
|---|---|---|---|
| **Texto** | UTF-8 | 64 KB por mensagem | RTCDataChannel (confiável) |
| **Imagem** | JPEG, PNG, WebP, GIF | 25 MB por arquivo | RTCDataChannel (chunked) |
| **Áudio** | Opus, AAC, MP3 | 100 MB por arquivo | RTCDataChannel (chunked) |
| **Vídeo** | H.264, VP8, VP9 | 500 MB por arquivo | RTCDataChannel (chunked) |
| **Arquivo** | Qualquer | 500 MB por arquivo | RTCDataChannel (chunked) |

### 4.3. Transferência de Arquivos Grandes (Chunking)

Arquivos maiores que 16 KB são divididos em chunks para transmissão via RTCDataChannel. O protocolo de chunking garante integridade e permite retomada em caso de desconexão:

```
Chunk Structure:
+--------+----------+--------+-----------+------------------+
| msg_id | chunk_id | total  | checksum  |     payload      |
| 16 B   |  4 B     | 4 B    |  32 B     |  up to 16 KB     |
+--------+----------+--------+-----------+------------------+

- Chunk size: 16 KB (configurável, otimizado para RTCDataChannel)
- Checksum: SHA-256 por chunk para verificação de integridade
- Retransmissão: chunks faltantes são solicitados via NACK
- Progresso: receptor envia ACK a cada N chunks para feedback de progresso
```

> **SPEC-MSG-001: Integridade de Mensagens** `[MUST]`
>
> Toda mensagem DEVE ser assinada com Ed25519 usando a chave privada do remetente.
> O receptor DEVE verificar a assinatura antes de processar a mensagem.
> Mensagens com assinatura inválida DEVEM ser descartadas silenciosamente.

> **SPEC-MSG-002: Chunking para Mídias** `[MUST]`
>
> Arquivos acima de 16 KB DEVEM ser transmitidos em chunks via RTCDataChannel no modo confiável (reliable, ordered).
> Cada chunk DEVE incluir checksum SHA-256 para verificação de integridade.
> O receptor DEVE solicitar retransmissão de chunks corrompidos ou faltantes.

### 4.4. Sincronização Offline

O desafio central de um sistema P2P sem servidor: o que acontece quando o destinatário está offline? SafeChannel resolve isso com um protocolo de sincronização baseado em Vector Clocks (Relógios Vetoriais).

#### 4.4.1. Funcionamento

1. **Armazenamento local:** Quando o usuário envia uma mensagem e o destinatário está offline, a mensagem é persistida localmente com status "pendente".
2. **Reconexão e handshake:** Quando ambos ficam online, o handshake WebRTC inclui troca de Vector Clocks, indicando a última mensagem conhecida por cada peer.
3. **Delta sync:** Cada peer calcula o delta (mensagens que o outro não possui) e envia apenas as faltantes.
4. **Confirmação:** Receptor confirma recebimento (ACK). Remetente atualiza status de "pendente" para "entregue".
5. **Ordenação:** Vector Clocks garantem ordenação causal correta, mesmo com múltiplos peers sincronizando em momentos diferentes.

```
Sync Handshake Protocol:

Peer A (online)                    Peer B (reconectou)
     |                                    |
     |  <--- SYNC_REQUEST {vc_b} ------  |  (B envia seu Vector Clock)
     |                                    |
     |  --- SYNC_RESPONSE {delta_a} -->  |  (A calcula e envia msgs faltantes)
     |                                    |
     |  <--- SYNC_ACK {received_ids} --  |  (B confirma recebimento)
     |                                    |
     |  <--- SYNC_REQUEST_REVERSE ---    |  (B agora envia msgs pendentes de B)
     |                                    |
     |  --- SYNC_ACK {received_ids} -->  |  (A confirma)
     |                                    |
     [Ambos sincronizados - chat normal]
```

> **SPEC-SYNC-001: Sincronização Obrigatória no Handshake** `[MUST]`
>
> Toda conexão P2P DEVE iniciar com troca de Vector Clocks antes de permitir envio de novas mensagens.
> O delta sync DEVE ser bidirecional: ambos os peers enviam mensagens faltantes ao outro.
> Mensagens pendentes DEVEM ser reenviadas na ordem original (por timestamp + vector clock).

> **SPEC-SYNC-002: Canais com Múltiplos Membros** `[MUST]`
>
> Em canais com mais de 2 membros, cada peer online DEVE sincronizar com cada outro peer individualmente.
> Mensagens já conhecidas (mesmo ID) DEVEM ser ignoradas na sincronização (deduplicação por UUID).
> O Vector Clock DEVE conter uma entrada para cada membro do canal.

---

## 5. Criptografia e Segurança

SafeChannel implementa criptografia em três camadas complementares, garantindo proteção em trânsito, em repouso e na identidade dos participantes.

### 5.1. Camadas de Criptografia

| Camada | Protocolo | Protege Contra | Onde Opera |
|---|---|---|---|
| **Transporte** | DTLS-SRTP (WebRTC) | Interceptação de rede, MitM | Conexão P2P |
| **Conteúdo** | Signal Protocol (Double Ratchet + X3DH) | Servidor comprometido, replay attacks | Payload da mensagem |
| **Repouso** | AES-256-GCM (SQLCipher) | Acesso físico ao dispositivo | Storage local |

### 5.2. Signal Protocol — Double Ratchet

O Signal Protocol é o padrão da indústria para criptografia E2E em mensageiros. Cada mensagem usa uma chave diferente, derivada pelo Double Ratchet Algorithm. Isso garante forward secrecy (comprometer uma chave não revela mensagens anteriores) e post-compromise security (o sistema se recupera automaticamente após comprometimento).

- **Chaves por usuário:** Identity Key (Ed25519, permanente), Signed Pre-Key (rotacionado periodicamente), Ephemeral Keys (uma por sessão/mensagem).
- **Troca de chaves inicial:** PQXDH (Post-Quantum Extended Diffie-Hellman), evoluindo do X3DH para resistência quântica.
- **Ratchet:** Cada mensagem avança o ratchet, gerando nova chave. Chaves usadas são descartadas.

> **SPEC-CRYPTO-002: Signal Protocol para Conteúdo** `[MUST]`
>
> Todo payload de mensagem DEVE ser criptografado usando Signal Protocol (Double Ratchet) ANTES de ser transmitido pelo RTCDataChannel.
> Isso garante dupla criptografia: Signal Protocol (conteúdo) + DTLS-SRTP (transporte).
> A criptografia de transporte (DTLS) sozinha NÃO é suficiente, pois não protege contra servidor de sinalização comprometido.

### 5.3. Armazenamento Local Criptografado

> **SPEC-CRYPTO-003: Criptografia em Repouso** `[MUST]`
>
> O banco de dados local DEVE ser criptografado com AES-256-GCM.
> A chave de criptografia DEVE ser derivada de PIN/senha do usuário via Argon2id.
> Em dispositivos com hardware seguro (Keystore/Keychain), a chave DEVE ser armazenada no secure enclave.
> A chave NUNCA deve ser armazenada em texto claro no filesystem.

### 5.4. Troca de Chaves do Canal

A troca de chaves é o momento mais crítico de segurança. SafeChannel suporta três métodos, em ordem de preferência:

| Prioridade | Método | Risco MitM | Requisito |
|---|---|---|---|
| **1 (melhor)** | QR Code presencial | Zero (sem intermediário) | Proximidade física |
| **2** | Senha pré-combinada (out-of-band) | Baixo (depende do canal OOB) | Canal seguro alternativo |
| **3** | Link de convite (in-band) | Médio (link pode ser interceptado) | Verificação posterior |

---

## 6. Modelo de Dados Local

Todo o armazenamento é local ao dispositivo, sem sincronização com nuvem. O schema abaixo define as entidades persistidas:

### 6.1. Entidades Principais

```dart
// User (identidade local)
class User {
  String id;              // UUID v4
  String displayName;     // Local only
  KeyPair identityKey;    // Ed25519 — Permanente
  KeyPair signedPreKey;   // X25519 — Rotacionado
  DateTime createdAt;
}

// Channel (grupo de comunicação)
class Channel {
  String id;              // UUID v4
  String name;
  Uint8List channelKey;   // AES-256 Key — Chave simétrica do canal
  String inviteSecret;    // Hashed — Para geração de QR/senha
  String createdBy;       // User.id
  DateTime createdAt;
  ChannelSettings settings;
}

class ChannelSettings {
  Duration? autoDelete;   // Mensagens efêmeras (opcional)
  int maxMembers;         // Default: 50
  bool allowMedia;        // Default: true
}

// ChannelMember
class ChannelMember {
  String channelId;       // Channel.id
  String userId;          // User.id
  Uint8List publicKey;    // Ed25519 PublicKey — Verificação de identidade
  String role;            // "admin" | "member"
  DateTime joinedAt;
  Map<String, int> vectorClock;  // Estado de sincronização
}

// Message
class Message {
  String id;              // UUID v4
  String channelId;       // Channel.id
  String senderId;        // User.id
  String type;            // "text" | "image" | "audio" | "video" | "file"
  Uint8List payload;      // Encrypted
  MessageMetadata? metadata;
  DateTime timestamp;
  Map<String, int> vectorClock;
  Uint8List signature;    // Ed25519 Signature
  String status;          // "pending" | "sent" | "delivered" | "read"
}

// MessageMetadata
class MessageMetadata {
  String mimeType;
  String? fileName;
  int sizeBytes;
  Uint8List? thumbnail;   // Encrypted
  int? durationMs;
  int? width;
  int? height;
}
```

> **SPEC-DATA-001: Persistência Exclusivamente Local** `[MUST]`
>
> NENHUMA entidade acima DEVE existir em servidor remoto.
> Todas as chaves privadas DEVEM residir exclusivamente no secure enclave do dispositivo (Keystore/Keychain).
> Deleção de conta DEVE resultar em wipe criptográfico de todos os dados locais.

---

## 7. Design e Interface do Usuário

O diferencial competitivo do SafeChannel está na experiência do usuário. A interface deve ser tão intuitiva quanto WhatsApp/Telegram, sem expor complexidade técnica ao usuário final.

### 7.1. Princípios de Design

| Princípio | Implementação |
|---|---|
| **Familiaridade** | Layout de chat idêntico ao padrão WhatsApp/Telegram: lista de conversas à esquerda, chat à direita, barra de composição abaixo. |
| **Zero Config** | Criação de conta em 1 toque (apenas nome + PIN). Sem email, telefone ou verificação. |
| **Segurança Visível** | Indicadores visuais de status de criptografia: cadeado verde (P2P ativo), amarelo (via TURN), cinza (offline/pendente). |
| **Feedback Instantâneo** | Status de mensagem visível: enviando (⟳), enviada (✓), entregue (✓✓), lida (✓✓ azul). |
| **Responsivo** | UI adaptável a Android e iOS via Flutter. Respeitar padrões de plataforma (Material Design / Cupertino). |

### 7.2. Telas Principais

| Tela | Conteúdo | Referência de Design |
|---|---|---|
| **Onboarding** | Nome + PIN. Geração automática de chaves. Sem etapas desnecessárias. | Telegram (simplicidade de registro) |
| **Lista de Canais** | Lista de canais com última mensagem, horário, badge de não-lidas. FAB para criar/entrar. | WhatsApp (lista de conversas) |
| **Chat** | Balões de mensagem, preview de mídia, barra de composição com attach/áudio/texto. | WhatsApp + Telegram (experiência de chat) |
| **Detalhes do Canal** | Membros online/offline, QR de convite, configurações, mídia compartilhada. | Discord (info de servidor) |
| **Convidar / Entrar** | Exibir QR Code, escanear QR, inserir senha. Animação de handshake criptográfico. | Briar (troca de QR Code) |
| **Configurações** | Perfil, segurança (PIN/biometria), notificações, armazenamento, sobre. | Telegram (settings organizados) |

### 7.3. Indicadores de Status

| Indicador | Visual | Significado | Ação do Usuário |
|---|---|---|---|
| **P2P Direto** | 🟢 Cadeado verde | Conexão direta criptografada | Nenhuma necessária |
| **Via TURN** | 🟡 Cadeado amarelo | Criptografado via relay | Mudar de rede se possível |
| **Offline** | ⚪ Cadeado cinza | Peer desconectado. Msgs pendentes. | Mensagens serão sincronizadas |
| **Sincronizando** | 🔄 Animação de sync | Trocando mensagens pendentes | Aguardar conclusão |

> **SPEC-UI-001: Transparência de Segurança** `[MUST]`
>
> O app DEVE exibir indicadores visuais claros do estado da conexão (P2P direto, TURN relay, offline).
> O usuário DEVE poder verificar a identidade de qualquer membro do canal (comparar fingerprints).
> Erros de verificação de identidade DEVEM ser comunicados de forma clara e não-técnica.

---

## 8. Stack Tecnológica Recomendada

| Componente | Tecnologia | Justificativa | Alternativa |
|---|---|---|---|
| **App Mobile** | Flutter 3.x + Dart | Cross-platform, UI rica | Kotlin/Swift nativo |
| **WebRTC** | flutter_webrtc | Wrapper maduro, ativo | peerDart |
| **Criptografia E2E** | libsignal_protocol_dart | Signal Protocol oficial | olm/megolm (Matrix) |
| **Storage Local** | SQLCipher (sqflite_sqlcipher) | SQLite criptografado, maduro | ObjectBox + encryption |
| **WebSocket Client** | web_socket_channel | Pacote oficial Dart | socket_io_client |
| **QR Code** | qr_flutter + mobile_scanner | Geração e leitura de QR | qr_code_scanner |
| **Servidor Sinalização** | Go + nhooyr.io/websocket | Performance, baixo footprint | Node.js + ws |
| **TURN Server** | Pion TURN v2 ou coturn | Embarcado no Go / padrão indústria | Cloudflare TURN |
| **Key Derivation** | argon2 (pointycastle) | Resistência a GPU/ASIC | scrypt |
| **Biometria** | local_auth | Fingerprint/Face, oficial | flutter_biometrics |

---

## 9. Requisitos Não-Funcionais

| Requisito | Meta | Métrica |
|---|---|---|
| **Latência P2P** | Mensagem de texto entregue em < 200ms (P2P direto) | Medir via timestamps no RTCDataChannel |
| **Tempo de Conexão** | Handshake completo (ICE + DTLS + sync) em < 3 segundos | Medir do início do ICE ao primeiro DataChannel message |
| **Transferência Mídia** | Imagem de 5 MB transferida em < 10 segundos (rede 4G) | Throughput médio via RTCDataChannel |
| **Storage** | App base < 30 MB. Overhead de criptografia < 15% do tamanho original. | Tamanho do APK/IPA. Ratio encrypted/original. |
| **Bateria** | Conexão idle consome < 2% bateria/hora | Android Battery Stats / iOS Energy Log |
| **Conectividade** | Taxa de sucesso de conexão P2P > 80%. Com TURN: > 98%. | Logs de ICE candidate type selecionado |
| **Sincronização** | 100 mensagens pendentes sincronizadas em < 5 segundos | Medir tempo total do sync handshake |

---

## 10. Roadmap de Desenvolvimento

| Fase | Escopo | Entregas | Duração Est. |
|---|---|---|---|
| **MVP** | Chat 1:1 P2P básico | Conexão WebRTC, texto E2E, storage local criptografado, QR Code para parear | 6-8 semanas |
| **v0.2** | Canais (grupos) | Criação de canal, ingresso por QR/senha, chat em grupo, gestão de membros | 4-6 semanas |
| **v0.3** | Mídia e sincronização | Envio de imagens/áudio/vídeo, chunking, sincronização offline, vector clocks | 6-8 semanas |
| **v0.4** | UX e polish | Design system completo, notificações, mensagens efêmeras, biometria | 4-6 semanas |
| **v1.0** | Produção | Auditoria de segurança, testes de carga, publicação nas stores | 4-6 semanas |

---

## Apêndice A: Resumo de SPEC IDs

| ID | Título | Nível |
|---|---|---|
| SPEC-ARCH-001 | Servidor Zero-Knowledge | **MUST** |
| SPEC-CHAN-001 | QR Code como Método Preferencial de Ingresso | **SHOULD** |
| SPEC-CHAN-002 | Derivação de Chave por Senha (Argon2id) | **MUST** |
| SPEC-MSG-001 | Integridade de Mensagens (Ed25519) | **MUST** |
| SPEC-MSG-002 | Chunking para Transferência de Mídias | **MUST** |
| SPEC-SYNC-001 | Sincronização Obrigatória no Handshake | **MUST** |
| SPEC-SYNC-002 | Sincronização Multi-Membro (Vector Clocks) | **MUST** |
| SPEC-CRYPTO-002 | Signal Protocol para Conteúdo E2E | **MUST** |
| SPEC-CRYPTO-003 | Criptografia em Repouso (AES-256-GCM) | **MUST** |
| SPEC-DATA-001 | Persistência Exclusivamente Local | **MUST** |
| SPEC-UI-001 | Transparência de Segurança na Interface | **MUST** |

---

*Fim do Documento*
