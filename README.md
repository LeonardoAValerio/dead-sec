# SafeChannel

**Mensageiro P2P seguro e descentralizado.** Toda mensagem, mídia e metadado é criptografado e persistido **exclusivamente nos dispositivos dos usuários** — o servidor não guarda nada além do estado de presença em memória necessário para conectar dois peers.

O objetivo é unir a robustez de segurança de protocolos P2P (Signal Protocol + WebRTC) com a familiaridade de interfaces como WhatsApp/Telegram.

> ⚠️ **Status: em desenvolvimento ativo (v0.2, pré-alpha).** O core criptográfico e o transporte P2P funcionam e são cobertos por testes, mas o projeto ainda não passou por auditoria de segurança externa e não deve ser usado para comunicação sensível em produção.

---

## Por que SafeChannel existe

A maioria dos mensageiros "seguros" ainda depende de um servidor central que, mesmo sem ler o conteúdo das mensagens, enxerga metadados: quem fala com quem, quando, com que frequência. SafeChannel elimina esse ponto de observação por design — o servidor de sinalização só existe para ajudar dois dispositivos a negociar uma conexão WebRTC direta (ICE/SDP) e esquece tudo assim que a sessão termina.

## Princípios de design

| Princípio | O que significa na prática |
|---|---|
| **Zero Trust Server** | Sem banco de dados no servidor. Nenhuma mensagem, mídia ou metadado passa por storage remoto — apenas roteamento efêmero de sinalização WebRTC. |
| **Data Sovereignty** | Chaves privadas nunca tocam disco em texto claro: vivem no Android Keystore / iOS Keychain (ou keyring do sistema, no desktop). |
| **Double Encryption** | Todo payload é cifrado com Signal Protocol (X3DH + Double Ratchet) **antes** de entrar no `RTCDataChannel` — a criptografia de transporte (DTLS) é tratada como insuficiente por si só. |
| **Offline First** | O app funciona sem conexão. Ao reconectar, os peers trocam Vector Clocks e fazem sync incremental (delta sync) das mensagens perdidas. |

---

## Como funciona

```
┌─────────────┐        sinalização (WSS)        ┌─────────────┐
│   Peer A    │ ───── SDP offer/answer ────────► │   Peer B    │
│  (Flutter)  │ ◄──── ICE candidates ──────────  │  (Flutter)  │
└──────┬──────┘                                  └──────┬──────┘
       │                                                 │
       │        servidor Go sai da equação                │
       │        após o handshake                          │
       │                                                 │
       └──────────── RTCDataChannel (DTLS/SCTP) ─────────┘
              conteúdo já cifrado com Signal Protocol
              (X3DH + Double Ratchet) antes de trafegar
```

1. O app conecta ao servidor de sinalização via **WSS**, identificado apenas pela sua chave pública (sem cadastro, sem e-mail, sem telefone).
2. Servidor troca **SDP offer/answer** e **ICE candidates** entre os dois peers e sai da equação.
3. Peers fazem **handshake DTLS** direto entre si, estabelecendo o `RTCDataChannel`.
4. Assim que o canal abre, os peers negociam sessão **Signal Protocol (X3DH)** e trocam **Vector Clocks** para sincronizar mensagens pendentes (offline-first).
5. Toda mensagem é cifrada com **Double Ratchet**, assinada com **Ed25519**, e só então enviada pelo DataChannel.
6. Se a conexão direta falhar, o tráfego cai para relay **TURN** — o conteúdo continua cifrado ponta a ponta; o relay só vê bytes opacos.

Um indicador visual no app mostra o tipo de conexão ativa: 🟢 P2P direto, 🟡 relay TURN, ⚫ offline.

---

## O que já funciona

- **Identidade e chaves** — geração local de chaves Ed25519 (assinatura), X25519 (DH) e identidade Signal, todas no secure enclave do dispositivo.
- **Signal Protocol completo** — X3DH para handshake inicial e Double Ratchet para cada mensagem, com forward secrecy.
- **Assinatura de mensagens** — toda mensagem recebida é verificada com Ed25519 antes de ser processada; assinatura inválida é descartada silenciosamente.
- **Transporte P2P via WebRTC** — conexão direta entre dispositivos com fallback automático para TURN, incluindo reconexão automática em quedas e em cenários de entrada fora de ordem dos peers.
- **Sincronização offline** — Vector Clocks + delta sync: peers que reconectam trocam apenas o que o outro ainda não tem, com deduplicação por UUID.
- **Storage local criptografado** — SQLCipher (mobile) com chave derivada por Argon2id; nenhuma linha do banco existe fora do dispositivo.
- **Canais/grupos** — criação de canal, ingresso por código de convite ou QR Code (expira em 5 minutos), tela de detalhes com membros.
- **PIN + biometria** — desbloqueio do app por PIN com Argon2id, com biometria como atalho opcional.
- **Notificações locais** — alertas de novas mensagens e de peers entrando no canal, sem depender de push de terceiros.
- **Servidor de sinalização Go** — zero-storage por construção: sem banco de dados, presença mantida só em memória e descartada ao desconectar.

Detalhes de implementação, decisões técnicas e débito técnico conhecido estão documentados em [`docs/SafeChannel_Status.md`](docs/SafeChannel_Status.md).

## O que ainda não existe

- Envio de mídia (imagem, áudio, vídeo) — protocolo de chunking com SHA-256 está especificado mas não implementado.
- TLS real no servidor de sinalização (hoje roda em WS/desenvolvimento local).
- Rotação de signed pre-keys e pool de one-time pre-keys no servidor.
- Auditoria de segurança externa.
- Scanner de QR Code em desktop Linux (sem suporte de câmera na lib atual).

---

## Stack técnica

| Camada | Tecnologia |
|---|---|
| App mobile | Flutter 3.x + Dart |
| Transporte P2P | WebRTC (`flutter_webrtc`) — apenas `RTCDataChannel`, sem SRTP |
| Criptografia E2E | Signal Protocol (`libsignal_protocol_dart`) |
| Storage local | SQLCipher (`sqflite_sqlcipher`) / AES-256-GCM |
| Derivação de chave | Argon2id (`pointycastle`) |
| Biometria | `local_auth` |
| Notificações | `flutter_local_notifications` |
| Servidor de sinalização | Go + `nhooyr.io/websocket` |
| Servidor TURN | Pion TURN v2 |
| Autenticação | JWT de curta duração (`golang-jwt/jwt`) |

---

## Estrutura do repositório

```
/
├── mobile/                # App Flutter (cliente)
│   └── lib/
│       ├── crypto/        # Signal Protocol, Argon2id, Ed25519
│       ├── webrtc/        # flutter_webrtc, ICE, DataChannel, sinalização
│       ├── db/             # SQLCipher + repositórios
│       ├── sync/           # Vector clocks, delta sync
│       ├── services/        # Notificações, biometria
│       ├── ui/              # Onboarding, pareamento, chat, canais, configurações
│       └── models/          # Entidades locais (User, Channel, Message...)
├── server/                # Backend Go
│   ├── signaling/          # WebSocket WSS, zero-storage
│   ├── turn/                # Servidor TURN embarcado (Pion)
│   └── auth/                # JWT + credenciais TURN temporárias
└── docs/
    ├── SafeChannel_Spec_v1.md              # Especificação funcional completa
    ├── SafeChannel_Status.md               # Estado de implementação, débito técnico
    └── WebRTC_Spec_Melhores_Praticas.md    # Base de conhecimento WebRTC usada no projeto
```

---

## Rodando localmente

### Pré-requisitos

- Flutter 3.x (`flutter config --enable-linux-desktop` para testar no desktop)
- Go 1.26+
- No Linux: `libsecret-1-dev` (necessário para `flutter_secure_storage`)

### Servidor de sinalização

```bash
cd server
go run main.go
# TURN server listening on UDP :3478 (realm=localhost)
# SafeChannel signaling server on :8000
```

### App (dois peers no mesmo Linux, para testar o fluxo P2P)

```bash
cd mobile
flutter run -d linux --dart-define=INSTANCE_ID=alice   # cria o canal
flutter run -d linux --dart-define=INSTANCE_ID=bob      # entra via código de convite
```

Cada `INSTANCE_ID` usa chaves e banco de dados isolados, permitindo simular dois usuários na mesma máquina.

### Testes automatizados

```bash
cd mobile
flutter test
```

---

## Modelo de ameaça (resumo)

SafeChannel assume que o **servidor de sinalização é não-confiável** — ele pode ser comprometido, subpoenado ou logar tudo que vê, e ainda assim não obtém conteúdo de mensagens, chaves privadas ou histórico de conversas, porque nunca os armazena. O que o servidor *pode* observar é o momento em que dois pares se conectam entre si (metadado de sinalização) e, no pior caso (fallback TURN), o volume de tráfego cifrado entre eles — nunca o conteúdo.

Este projeto ainda **não passou por auditoria de segurança independente**. Trate-o como um projeto experimental/educacional até que isso mude.

---

## Licença

Ainda não definida.
