# SPEC: WebRTC — Melhores Práticas para Projetos com Web Real-Time Communication

**Versão:** 1.0  
**Data:** Maio 2026  
**Contexto:** Projetos Flutter/Dart com backend Go  
**Classificação:** Arquitetura, Segurança, Implementação e Operação

---

## Fontes de Referência

| Documento | Fonte | Foco |
|-----------|-------|------|
| IETF RTCWEB Security Architecture | rtcweb-wg.github.io/security-arch | Arquitetura de segurança formal |
| A Study of WebRTC Security | webrtc-security.github.io | Análise acadêmica de segurança |
| Understanding the WebRTC Protocol | voipmonitor.org | Protocolos e monitoramento |
| WebRTC Security Best Practices | digitalsamba.com | Boas práticas em produção |

---

## 1. Introdução e Visão Geral

WebRTC (Web Real-Time Communication) é um conjunto de protocolos e APIs open-source que permite comunicação em tempo real — áudio, vídeo e dados arbitrários — diretamente entre navegadores ou aplicações nativas, sem necessidade de plugins.

Este documento especifica as melhores práticas para projetar, implementar e operar sistemas baseados em WebRTC, com foco em segurança, desempenho e confiabilidade.

### 1.1. Escopo

Esta spec cobre toda a cadeia de uma implementação WebRTC: desde a arquitetura de protocolos e modelo de confiança, passando por sinalização, traversal de NAT, criptografia obrigatória, até boas práticas operacionais e monitoramento. O contexto alvo é um app Flutter/Dart com backend Go, mas os princípios se aplicam a qualquer stack.

### 1.2. Principais Casos de Uso

- Chamadas de áudio e vídeo em tempo real (1:1 e grupo)
- Videoconferência e salas de aula virtuais
- Transferência direta de dados entre peers (chat, arquivos)
- Streaming de baixa latência (jogos, colaboração em tempo real)
- Telemedicina, atendimento jurídico remoto, suporte técnico

---

## 2. Arquitetura de Protocolos

WebRTC opera em um modelo peer-to-peer, onde cada agente atua simultaneamente como cliente e servidor. A comunicação direta entre peers minimiza latência e uso de banda, mas exige coordenação prévia (sinalização) e mecanismos de traversal de NAT.

### 2.1. Pilha de Protocolos (Protocol Stack)

```
┌─────────────────────────────────────────┐
│          Aplicação (JS API / SDK)       │
├──────────────┬──────────────────────────┤
│  Audio/Video │     Dados Arbitrários    │
│    (SRTP)    │     (SCTP sobre DTLS)    │
├──────────────┴──────────────────────────┤
│              DTLS (Criptografia)        │
├─────────────────────────────────────────┤
│          ICE (Traversal de NAT)         │
├──────────────┬──────────────┬───────────┤
│    STUN      │     TURN     │   UDP     │
└──────────────┴──────────────┴───────────┘
```

| Camada | Protocolo | Função |
|--------|-----------|--------|
| Aplicação | JS API / Native SDK | Captura de mídia, controle de sessão |
| Mídia | SRTP (Secure RTP) | Transporte criptografado de áudio/vídeo |
| Dados | SCTP sobre DTLS | Canal de dados arbitrários criptografado |
| Segurança | DTLS 1.2+ | Handshake criptográfico, troca de chaves |
| Conectividade | ICE (STUN + TURN) | Descoberta de rota e traversal de NAT |
| Transporte | UDP (preferencialmente) | Transporte de baixa latência |

### 2.2. As Três APIs Fundamentais

**getUserMedia** — API do HTML5 que captura áudio e vídeo do dispositivo do usuário. É o ponto de entrada para qualquer aplicação WebRTC que envolva mídia. O navegador DEVE solicitar permissão explícita do usuário antes de conceder acesso à câmera ou microfone.

**RTCPeerConnection** — API central do WebRTC. Representa a conexão peer-to-peer e gerencia todo o ciclo de vida: negociação SDP, ICE candidates, handshake DTLS, streaming de mídia. Opera preferencialmente sobre UDP para minimizar latência, aceitando perda de pacotes em troca de velocidade.

**RTCDataChannel** — Canal de dados arbitrários entre peers, usando SCTP sobre DTLS. Suporta entrega confiável (como TCP) ou parcialmente confiável (como UDP). Ideal para chat, transferência de arquivos, sincronização de estado em jogos, etc.

### 2.3. Fluxo Completo de uma Sessão

1. **Sinalização:** Peers trocam ofertas/respostas SDP e candidatos ICE via servidor intermediário (WebSocket, HTTP, etc.)
2. **Descoberta de rede (ICE):** Cada peer coleta candidatos (host, server-reflexive via STUN, relay via TURN) e testa conectividade
3. **Verificação de consentimento:** ICE checks confirmam que ambos os peers desejam se comunicar
4. **Handshake DTLS:** Negociação criptográfica direta entre peers, gerando chaves de sessão
5. **Troca de mídia/dados:** Áudio/vídeo via SRTP, dados via SCTP/DTLS — tudo criptografado end-to-end
6. **Consent freshness:** Keepalives periódicos (RFC 7675) garantem que o peer remoto ainda está ativo

```
Alice (App)                  Servidor Sinalização           Bob (App)
      │                                │                        │
      │  1. getUserMedia()             │                        │
      │  (pede permissão câmera/mic)   │                        │
      │                                │                        │
      │  2. createOffer() ──────────>  │  ───────────────────>  │
      │     (SDP + fingerprint DTLS)   │     (repassa oferta)   │
      │                                │                        │
      │                                │                        │  3. getUserMedia()
      │                                │                        │  4. createAnswer()
      │  <───────────────────────────  │  <──────────────────── │
      │     (repassa resposta)         │     (SDP + fingerprint) │
      │                                │                        │
      │  5. Troca de candidatos ICE <──────────────────────────>│
      │     (STUN descobre IPs)        │                        │
      │                                │                        │
      │  6. DTLS Handshake (direto P2P, sem servidor) <──────> │
      │     (estabelece chaves criptográficas)                  │
      │                                                         │
      │  7. SRTP (áudio/vídeo criptografado) <────────────────>│
      │  8. SCTP/DTLS (dados criptografados) <────────────────>│
      │                                                         │
      │  SERVIDOR NÃO VÊ O CONTEÚDO DA MÍDIA                  │
```

> **🔑 Princípio Fundamental:** O servidor de sinalização NUNCA vê o conteúdo da mídia ou dados. A criptografia é negociada diretamente entre os peers via DTLS. Mesmo que o servidor de sinalização seja comprometido, o conteúdo permanece protegido.

---

## 3. Modelo de Confiança

A arquitetura de segurança WebRTC define uma hierarquia de confiança clara, conforme especificado no IETF RTCWEB Security Architecture (draft-ietf-rtcweb-security-arch).

### 3.1. Hierarquia de Confiança

O navegador (ou SDK nativo) é a raiz de toda confiança no sistema (Trusted Computing Base). Todas as garantias de segurança derivam dele. Se o navegador estiver comprometido, nenhuma garantia é possível.

| Entidade | Nível de Confiança | Como é Verificada |
|----------|--------------------|--------------------|
| Navegador/SDK | Confiança total (TCB) | Usuário escolhe navegador confiável |
| Serviço de chamada (web server) | Autenticado via HTTPS | Certificado TLS, verificação de origin |
| Peer remoto | Autenticado via DTLS-SRTP | Fingerprint no SDP + handshake DTLS |
| Identity Provider (IdP) | Autenticado via HTTPS | Asserções criptográficas (OpenID, OAuth) |
| Servidor STUN | Não confiável (minimal trust) | Apenas reflete IP público |
| Servidor TURN | Confiança operacional | Autenticação obrigatória, não vê conteúdo |
| Rede (ISP, Wi-Fi, etc.) | Não confiável | Criptografia protege contra observadores |

### 3.2. Entidades Autenticadas vs. Não Autenticadas

**Autenticadas:** Serviços de chamada (verificáveis via HTTPS/TLS) e peers remotos (verificáveis via DTLS-SRTP e opcionalmente via IdP). Autenticação não implica confiança — apenas permite ao usuário decidir se deseja confiar.

**Não autenticadas:** Todos os demais elementos de rede (ISPs, routers, firewalls). O sistema DEVE ser projetado assumindo que essas entidades podem agir maliciosamente.

> **⚠️ Regra de Ouro:** Autenticar uma entidade NÃO a torna confiável automaticamente. Exemplo: verificar que um site pertence a um atacante não significa que devemos dar acesso à câmera. A autenticação permite ao usuário DECIDIR se confia, com base em informação verificada.

---

## 4. Sinalização (Signaling)

### 4.1. Princípios

WebRTC intencionalmente NÃO define um protocolo de sinalização. A sinalização é responsável por trocar metadados (SDP offers/answers, candidatos ICE) entre peers antes da conexão direta ser estabelecida. O desenvolvedor escolhe o transporte: WebSocket, HTTP, SIP, XMPP, ou qualquer outro.

### 4.2. Protocolos de Transporte para Sinalização

| Protocolo | Modelo | Latência | Recomendado |
|-----------|--------|----------|-------------|
| WebSocket Secure (WSS) | Bidirecional persistente | Baixíssima (ms) | **SIM** |
| HTTP Long Polling | Semi-bidirecional | Média (100-500ms) | Aceitável |
| HTTP Polling | Request-response | Alta (até intervalo) | **NÃO** |
| SIP sobre TLS | Bidirecional | Baixa | Para interop VoIP |

### 4.3. Requisitos Obrigatórios de Sinalização

#### SPEC-SIG-001: Transporte Seguro OBRIGATÓRIO

- Toda sinalização DEVE usar transporte criptografado (WSS ou HTTPS)
- Sinalização em texto claro (WS sem TLS, HTTP sem TLS) é PROIBIDA em produção
- Razão: o SDP contém fingerprints DTLS. Interceptação permite ataques MitM na negociação

#### SPEC-SIG-002: Autenticação de Peers

- O servidor de sinalização DEVE autenticar ambos os peers antes de repassar mensagens
- Usar tokens JWT com tempo de expiração curto (minutos, não horas)
- IDs de sessão DEVEM ser criptograficamente aleatórios (UUID v4 ou superior)

#### SPEC-SIG-003: WebSocket Secure como Padrão

- Para aplicações WebRTC, WSS é o transporte RECOMENDADO para sinalização
- WSS suporta o padrão bidirecional necessário para Trickle ICE (envio incremental de candidatos)
- HTTP pode ser usado como complemento (auth, geração de credenciais TURN), mas não como canal principal de sinalização

### 4.4. Session Description Protocol (SDP)

O SDP descreve as capacidades de mídia, endereços de transporte e parâmetros de negociação. Um SDP WebRTC típico contém:

- Capacidades de mídia e codecs suportados (VP8, VP9, AV1, Opus, etc.)
- Endereço IP e porta para conexão
- Fingerprint DTLS (hash do certificado para verificação criptográfica)
- Candidatos ICE (host, server-reflexive, relay)
- Parâmetros de segurança (DTLS-SRTP obrigatório)
- Atributo identity (asserção de identidade via IdP, quando disponível)

---

## 5. NAT Traversal (ICE, STUN, TURN)

### 5.1. O Problema do NAT

A maioria dos dispositivos está atrás de NAT (Network Address Translation), sem IP público direto. O ICE (Interactive Connectivity Establishment) resolve isso tentando múltiplas rotas em paralelo e selecionando a mais eficiente.

### 5.2. Tipos de Candidatos ICE

| Tipo | Origem | Prioridade | Custo |
|------|--------|------------|-------|
| Host | IP local do dispositivo | Mais alta | Zero (P2P direto) |
| Server-reflexive (srflx) | IP público via STUN | Alta | Baixo (P2P via NAT) |
| Relay | Via servidor TURN | Mais baixa | Alto (servidor retransmite) |

### 5.3. STUN — Session Traversal Utilities for NAT

STUN é um protocolo simples: o peer envia um pacote UDP ao servidor STUN, que responde com o IP público e porta observados. Não carrega dados sensíveis e não toca na mídia.

#### SPEC-STUN-001: Uso de STUN

- STUN públicos (ex: `stun:stun.l.google.com:19302`) são aceitáveis para a maioria dos cenários
- STUN próprio é recomendado apenas se: requisitos regulatórios proíbem envio de dados para servidores estrangeiros, ambiente air-gapped, ou necessidade de controle total de disponibilidade
- Um STUN malicioso pode apenas mentir sobre o IP (causando falha na conexão) ou registrar IPs consultantes (risco de privacidade). Não compromete o conteúdo

### 5.4. TURN — Traversal Using Relays around NAT

TURN é o fallback quando conexão P2P direta falha. O servidor TURN retransmite todo o tráfego entre peers. É essencial em produção para garantir conectividade universal.

#### SPEC-TURN-001: TURN é CRÍTICO em Produção

- Sem TURN, usuários em redes restritivas (Wi-Fi corporativo, 4G com NAT simétrico) NÃO conseguirão se conectar
- A taxa de falha P2P em redes reais pode chegar a 15-30% dos usuários
- TURN é obrigatório para qualquer aplicação em produção

#### SPEC-TURN-002: Segurança do Servidor TURN

- **MUST:** Autenticar todas as conexões (nunca relay aberto)
- **MUST:** Usar credenciais temporárias (time-limited credentials) geradas pelo backend
- **MUST:** Aplicar rate limiting e restrição de IP
- **MUST:** Bloquear relay para IPs privados (10.x, 192.168.x) para evitar abuso como proxy
- **SHOULD:** Rotacionar credenciais a cada 5-15 minutos
- **SHOULD:** Monitorar uso de banda por usuário para detectar abuso

### 5.5. Opções de Servidor TURN

| Opção | Linguagem | Produção | Nota |
|-------|-----------|----------|------|
| coturn | C | Sim, padrão da indústria | Mais usado, roda em VPS barato |
| Pion TURN | Go | Sim | Pode embutir no backend Go |
| Twilio / Xirsys | Serviço gerenciado | Sim | Pago por uso, sem gerenciamento |
| Cloudflare TURN | Serviço gerenciado | Sim | Integrado com edge network |

---

## 6. Segurança e Criptografia

Segurança é o pilar central do WebRTC. Diferente de VoIP tradicional onde criptografia é frequentemente opcional (e desabilitada), no WebRTC a criptografia é obrigatória em todos os componentes. Mídia não criptografada é explicitamente proibida pela especificação.

### 6.1. Protocolos de Criptografia

#### 6.1.1. DTLS (Datagram Transport Layer Security)

DTLS é o equivalente ao TLS para datagramas UDP. É usado para:

- Handshake criptográfico entre peers
- Troca de chaves para SRTP (via DTLS-SRTP)
- Criptografia direta dos data channels (SCTP sobre DTLS)

#### 6.1.2. SRTP (Secure Real-time Transport Protocol)

SRTP criptografa os streams de mídia (áudio/vídeo). É mais leve que DTLS, otimizado para tráfego real-time. As chaves são derivadas do handshake DTLS-SRTP, permitindo detecção de ataques Man-in-the-Middle.

#### 6.1.3. DTLS-SRTP vs SDES

A especificação WebRTC exige DTLS-SRTP como mecanismo padrão e preferido de troca de chaves. SDES troca chaves em texto claro no SDP, sendo significativamente menos seguro.

#### SPEC-CRYPTO-001: DTLS-SRTP Obrigatório

- **MUST:** Usar DTLS-SRTP para troca de chaves de mídia
- **MUST:** Se uma oferta contiver suporte a DTLS-SRTP e SDES, DTLS-SRTP DEVE ser selecionado
- **MUST NOT:** Usar SDES como único mecanismo de troca de chaves
- **SHOULD:** Usar DTLS 1.2 ou superior

### 6.2. Limitações Conhecidas

> **⚠️ Fraqueza do SRTP: Headers Não Criptografados**
>
> SRTP criptografa apenas o payload dos pacotes RTP, NÃO os headers. Headers contêm níveis de áudio, permitindo que um observador determine se um usuário está falando. O conteúdo permanece secreto, mas metadados de atividade de fala ficam expostos. Para cenários de alta segurança, considerar E2EE adicional via Insertable Streams.

### 6.3. Permissões de Acesso a Dispositivos

O navegador/SDK DEVE solicitar permissão explícita do usuário para acessar câmera e microfone. Quando ativos, a UI DEVE indicar visualmente que os dispositivos estão em uso.

#### SPEC-PERM-001: Permissões de Mídia

- **MUST:** Solicitar permissão antes de acessar câmera/microfone
- **MUST:** Exibir indicador visual quando dispositivos estão ativos
- **SHOULD:** Interromper captura quando o indicador está obstruído (ex: janela sobreposta)
- Em Flutter: usar o pacote `permission_handler` para solicitar permissões do OS

### 6.4. Privacidade de IP

O ICE coleta candidatos de rede que podem expor IPs internos, mesmo quando o usuário usa VPN. Navegadores modernos mitigam isso com mDNS host candidate masking.

#### SPEC-PRIV-001: Proteção de IP

- **SHOULD:** Configurar ICE para usar apenas relay candidates quando privacidade é crítica
- **SHOULD:** Em apps nativos, implementar filtragem de candidatos para remover IPs internos antes de enviar ao peer
- **NOTA:** Usar apenas relay candidates força todo tráfego pelo TURN, aumentando latência e custo

### 6.5. Autenticação de Peers via Identity Providers

A arquitetura WebRTC suporta Identity Providers (IdPs) para verificar a identidade dos peers independentemente do servidor de sinalização. Isso é crucial quando o servidor de sinalização não é totalmente confiável (ex: federação entre domínios).

- IdPs (OpenID Connect, OAuth) emitem asserções vinculando identidade ao fingerprint DTLS
- O peer receptor verifica a asserção diretamente com o IdP, sem depender do servidor de sinalização
- Protege contra ataques Man-in-the-Middle onde o servidor de sinalização é comprometido

---

## 7. Riscos, Vulnerabilidades e Mitigações

| Risco | Severidade | Vetor de Ataque | Mitigação |
|-------|------------|-----------------|-----------|
| Sinalização insegura | **CRÍTICA** | Interceptação de SDP, injeção de candidatos, sequestro de sessão | WSS/HTTPS obrigatório, autenticação por token |
| TURN mal configurado | **CRÍTICA** | Relay aberto, abuso de banda, inspeção de tráfego | Autenticação, credenciais temporárias, rate limiting |
| Exposição de IP | **MÉDIA** | Vazamento de IP interno via ICE candidates | mDNS masking, filtragem de candidatos |
| Lógica de aplicação insegura | **CRÍTICA** | IDs previsíveis, tokens sem expiração, sem RBAC | Tokens JWT curtos, UUID v4, RBAC |
| Bugs na implementação | **MÉDIA** | Heap-buffer overflow (CVE-2022) | Manter browser/SDK atualizados |
| Headers SRTP expostos | **BAIXA** | Análise de metadados de fala | E2EE via Insertable Streams |
| MitM na sinalização | **CRÍTICA** | Servidor comprometido altera fingerprints | IdP independente, validação de fingerprint |

---

## 8. Guia de Implementação

### 8.1. Arquitetura Recomendada (Flutter + Go)

| Componente | Tecnologia | Porta/Protocolo |
|------------|------------|-----------------|
| App cliente | Flutter + `flutter_webrtc` | N/A (dispositivo móvel) |
| Sinalização | Go + `nhooyr.io/websocket` ou `gorilla/websocket` | WSS :443 |
| TURN/STUN | Pion TURN (embarcado no Go) ou coturn | UDP/TCP :3478, TLS :5349 |
| Autenticação | Go + JWT | HTTPS :443 |
| SFU (se grupo) | LiveKit ou Pion/mediadevices | UDP + WSS |

```
┌──────────────┐                    ┌──────────────┐
│  App Flutter  │                    │  App Flutter  │
│   (Aluno A)   │                    │   (Aluno B)   │
└──────┬───────┘                    └──────┬───────┘
       │                                    │
       │  WSS (sinalização)                 │
       ▼                                    ▼
┌─────────────────────────────────────────────┐
│          Servidor Go                         │
│  ┌─────────────────┐  ┌──────────────────┐  │
│  │  Sinalização     │  │   TURN (Pion)    │  │
│  │  (WebSocket)     │  │   porta 3478     │  │
│  └─────────────────┘  └──────────────────┘  │
│  ┌─────────────────┐                        │
│  │  Auth / Tokens   │                        │
│  │  (JWT + creds    │                        │
│  │   temporárias)   │                        │
│  └─────────────────┘                        │
└─────────────────────────────────────────────┘

Após sinalização: mídia flui direto P2P (ou via TURN se P2P falhar)
```

### 8.2. Credenciais TURN Temporárias

NUNCA armazene credenciais TURN fixas no app. O fluxo seguro é:

1. App Flutter autentica no backend Go (login, JWT)
2. Backend gera credenciais TURN temporárias (validade: 5-15 min)
3. App recebe credenciais e configura iceServers
4. Credenciais expiram automaticamente — mesmo se APK for decompilado, são inúteis

**Geração de credenciais temporárias em Go:**

```go
func GenerateTURNCredentials(username string) (string, string) {
    timestamp := time.Now().Add(10 * time.Minute).Unix()
    tempUser := fmt.Sprintf("%d:%s", timestamp, username)
    mac := hmac.New(sha1.New, []byte(turnSecret))
    mac.Write([]byte(tempUser))
    password := base64.StdEncoding.EncodeToString(mac.Sum(nil))
    return tempUser, password
}
```

**Configuração no Flutter/Dart:**

```dart
// Buscar credenciais do backend antes de cada chamada
final resp = await http.get(
  Uri.parse('https://api.exemplo.com/turn-credentials'),
  headers: {'Authorization': 'Bearer $jwtToken'},
);
final creds = jsonDecode(resp.body);

final config = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {
      'urls': ['turn:seu-servidor.com:3478'],
      'username': creds['username'],
      'credential': creds['password'],
    },
  ],
};

final pc = await createPeerConnection(config);
```

### 8.3. Servidor de Sinalização em Go

```go
package main

import (
    "log"
    "net/http"
    "sync"

    "nhooyr.io/websocket"
    "nhooyr.io/websocket/wsjson"
)

type Room struct {
    mu    sync.Mutex
    peers map[string]*websocket.Conn
}

type SignalMessage struct {
    Type   string      `json:"type"`
    Room   string      `json:"room"`
    From   string      `json:"from"`
    Data   interface{} `json:"data,omitempty"`
}

var rooms = sync.Map{}

func handleWS(w http.ResponseWriter, r *http.Request) {
    // Validar JWT aqui antes de aceitar conexão
    conn, err := websocket.Accept(w, r, nil)
    if err != nil {
        log.Println(err)
        return
    }
    defer conn.Close(websocket.StatusNormalClosure, "")

    ctx := r.Context()
    for {
        var msg SignalMessage
        if err := wsjson.Read(ctx, conn, &msg); err != nil {
            break
        }
        // Repassar offer/answer/ice-candidate aos outros peers na sala
        broadcast(msg.Room, msg.From, msg)
    }
}

func main() {
    http.HandleFunc("/ws", handleWS)
    log.Fatal(http.ListenAndServeTLS(":443", "cert.pem", "key.pem", nil))
}
```

### 8.4. Servidor TURN Embarcado em Go (Pion)

```go
package main

import (
    "log"
    "net"

    "github.com/pion/turn/v2"
)

func main() {
    udpListener, err := net.ListenPacket("udp4", "0.0.0.0:3478")
    if err != nil {
        log.Fatal(err)
    }

    server, err := turn.NewServer(turn.ServerConfig{
        Realm: "seu-dominio.com",
        AuthHandler: func(username string, realm string, srcAddr net.Addr) ([]byte, bool) {
            // Validar credenciais temporárias (timestamp + HMAC)
            if validarCredencialTemporaria(username) {
                return turn.GenerateAuthKey(username, realm, obterSenha(username)), true
            }
            return nil, false
        },
        PacketConnConfigs: []turn.PacketConnConfig{
            {
                PacketConn: udpListener,
                RelayAddressGenerator: &turn.RelayAddressGeneratorStatic{
                    RelayAddress: net.ParseIP("SEU_IP_PUBLICO"),
                    Address:      "0.0.0.0",
                },
            },
        },
    })
    if err != nil {
        log.Fatal(err)
    }
    defer server.Close()

    log.Println("TURN rodando na porta 3478")
    select {}
}
```

### 8.5. Fluxo Completo no Flutter/Dart

```dart
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';

class WebRTCService {
  late RTCPeerConnection _pc;
  late WebSocketChannel _ws;
  MediaStream? _localStream;

  // 1. Conectar ao servidor de sinalização
  Future<void> connect(String room, String token) async {
    _ws = WebSocketChannel.connect(
      Uri.parse('wss://api.exemplo.com/ws?room=$room&token=$token'),
    );

    _ws.stream.listen(_onSignalingMessage);
  }

  // 2. Iniciar chamada
  Future<void> startCall() async {
    // Buscar credenciais TURN temporárias
    final creds = await _fetchTurnCredentials();

    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': ['turn:seu-servidor.com:3478'],
          'username': creds['username'],
          'credential': creds['password'],
        },
      ],
    });

    // Capturar mídia
    _localStream = await navigator.mediaDevices.getUserMedia({
      'video': {'facingMode': 'user'},
      'audio': true,
    });

    _localStream!.getTracks().forEach((track) {
      _pc.addTrack(track, _localStream!);
    });

    // Enviar candidatos ICE ao peer
    _pc.onIceCandidate = (candidate) {
      _send({'type': 'ice-candidate', 'data': candidate.toMap()});
    };

    // Receber stream remoto
    _pc.onTrack = (event) {
      // Exibir no RTCVideoRenderer
      onRemoteStream?.call(event.streams[0]);
    };

    // Criar e enviar oferta
    final offer = await _pc.createOffer();
    await _pc.setLocalDescription(offer);
    _send({'type': 'offer', 'data': offer.toMap()});
  }

  // 3. Processar mensagens de sinalização
  Future<void> _onSignalingMessage(dynamic data) async {
    final msg = jsonDecode(data);

    switch (msg['type']) {
      case 'offer':
        await _pc.setRemoteDescription(
          RTCSessionDescription(msg['data']['sdp'], msg['data']['type']),
        );
        final answer = await _pc.createAnswer();
        await _pc.setLocalDescription(answer);
        _send({'type': 'answer', 'data': answer.toMap()});
        break;

      case 'answer':
        await _pc.setRemoteDescription(
          RTCSessionDescription(msg['data']['sdp'], msg['data']['type']),
        );
        break;

      case 'ice-candidate':
        await _pc.addCandidate(RTCIceCandidate(
          msg['data']['candidate'],
          msg['data']['sdpMid'],
          msg['data']['sdpMLineIndex'],
        ));
        break;
    }
  }

  void _send(Map<String, dynamic> msg) {
    _ws.sink.add(jsonEncode(msg));
  }

  // Callback para stream remoto
  Function(MediaStream)? onRemoteStream;
}
```

### 8.6. DataChannel para Chat/Dados

```dart
// No peer que inicia
final dataChannel = await _pc.createDataChannel(
  'chat',
  RTCDataChannelInit()..ordered = true,
);

dataChannel.onMessage = (RTCDataChannelMessage msg) {
  final data = jsonDecode(msg.text);
  print('${data["autor"]}: ${data["texto"]}');
};

dataChannel.onDataChannelState = (RTCDataChannelState state) {
  if (state == RTCDataChannelState.RTCDataChannelOpen) {
    dataChannel.send(RTCDataChannelMessage(
      jsonEncode({'autor': 'Alice', 'texto': 'Mensagem criptografada via DTLS!'})
    ));
  }
};

// No peer que recebe
_pc.onDataChannel = (RTCDataChannel channel) {
  channel.onMessage = (RTCDataChannelMessage msg) {
    final data = jsonDecode(msg.text);
    print('${data["autor"]}: ${data["texto"]}');
  };
};
```

### 8.7. Monitoramento de Conexão

```dart
// Monitorar estado da conexão
_pc.onConnectionState = (RTCPeerConnectionState state) {
  print('Estado: $state');
  if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
    // Implementar lógica de reconexão
  }
};

// Coletar métricas via getStats()
Future<void> collectStats() async {
  final stats = await _pc.getStats();
  stats.forEach((report) {
    if (report.type == 'candidate-pair') {
      final rtt = report.values['currentRoundTripTime'];
      print('RTT: ${(rtt * 1000).toStringAsFixed(0)}ms');
    }
    if (report.type == 'inbound-rtp' && report.values['kind'] == 'video') {
      print('Pacotes perdidos: ${report.values['packetsLost']}');
      print('Jitter: ${report.values['jitter']}');
    }
  });
}
```

### 8.8. Bibliotecas e Pacotes Recomendados

| Componente | Pacote/Lib | Linguagem |
|------------|------------|-----------|
| WebRTC no Flutter | `flutter_webrtc` | Dart |
| WebRTC server-side | `pion/webrtc` v3 | Go |
| Servidor TURN | `pion/turn` v2 ou coturn | Go / C |
| WebSocket server | `nhooyr.io/websocket` | Go |
| WebSocket client | `web_socket_channel` | Dart |
| JWT | `golang-jwt/jwt` | Go |
| Permissões mobile | `permission_handler` | Dart |
| SFU (videoconferência) | LiveKit (`livekit-server`) | Go |

---

## 9. Operações e Monitoramento

### 9.1. Checklist de Produção

| Item | Status | Verificação |
|------|--------|-------------|
| Sinalização via WSS/HTTPS | **OBRIGATÓRIO** | Testar com curl, verificar certificado TLS |
| TURN com autenticação | **OBRIGATÓRIO** | Testar com `turnutils_uclient` |
| Credenciais TURN temporárias | **OBRIGATÓRIO** | Verificar que expiram em < 15min |
| TURN bloqueando relay para IPs privados | **OBRIGATÓRIO** | Testar conexão para 10.x, 192.168.x |
| Tokens JWT com expiração | **OBRIGATÓRIO** | Verificar campo `exp` no payload |
| IDs de sessão aleatórios | **OBRIGATÓRIO** | Confirmar UUID v4 ou equivalente |
| Rate limiting no TURN | **RECOMENDADO** | Testar sob carga |
| Monitoramento de banda TURN | **RECOMENDADO** | Dashboard com métricas por usuário |
| E2EE (Insertable Streams) | **OPCIONAL** | Para cenários de alta segurança |
| STUN próprio | **OPCIONAL** | Apenas se requisitos regulatórios exigirem |

### 9.2. Métricas para Monitorar

- **RTT (Round Trip Time):** latência da conexão. Acima de 300ms degrada a experiência
- **Packet loss:** acima de 5% causa artefatos audiovisuais perceptíveis
- **Jitter:** variação na latência. Acima de 30ms causa problemas de áudio
- **ICE candidate type selecionado:** monitorar % de conexões via relay vs P2P
- **Banda consumida pelo TURN:** para dimensionamento de infraestrutura
- **Taxa de falha de conexão:** se acima de 5%, investigar configuração ICE

### 9.3. Manutenção e Atualizações

#### SPEC-OPS-001: Patch Management

- **MUST:** Manter `flutter_webrtc` e dependências WebRTC atualizadas
- **MUST:** Atualizar browser/WebView embeddings quando patches de segurança são lançados
- **MUST:** Monitorar CVEs relacionados a WebRTC (ex: CVE-2022 heap-buffer overflow)
- **SHOULD:** Realizar testes de penetração anuais na infraestrutura WebRTC
- **SHOULD:** Manter audit logs de todas as conexões e tentativas de acesso

---

## 10. Conformidade Regulatória

Aplicações WebRTC que lidam com dados pessoais devem considerar os seguintes frameworks:

| Framework | Requisito Chave | Como WebRTC Atende |
|-----------|-----------------|---------------------|
| LGPD (Brasil) | Proteção de dados pessoais em trânsito e repouso | DTLS-SRTP criptografa em trânsito; gravações devem ser cifradas em repouso |
| GDPR (UE) | Privacy by design, criptografia, consentimento | Criptografia obrigatória, permissões explícitas de mídia |
| HIPAA (EUA) | Proteção de informações de saúde | E2EE recomendado, controle de acesso rigoroso |

---

## Apêndice A: Resumo de SPEC IDs

| ID | Título | Nível |
|----|--------|-------|
| SPEC-SIG-001 | Transporte seguro de sinalização | MUST |
| SPEC-SIG-002 | Autenticação de peers na sinalização | MUST |
| SPEC-SIG-003 | WSS como padrão de sinalização | SHOULD |
| SPEC-STUN-001 | Política de uso de STUN | SHOULD |
| SPEC-TURN-001 | TURN obrigatório em produção | MUST |
| SPEC-TURN-002 | Segurança do servidor TURN | MUST |
| SPEC-CRYPTO-001 | DTLS-SRTP obrigatório | MUST |
| SPEC-PERM-001 | Permissões de acesso a mídia | MUST |
| SPEC-PRIV-001 | Proteção de privacidade de IP | SHOULD |
| SPEC-OPS-001 | Gerenciamento de patches e atualizações | MUST |

---

*Fim do Documento*
