package signaling

import (
	"context"
	"encoding/json"
	"log"
	"net/http"

	"nhooyr.io/websocket"

	"github.com/safechannel/server/auth"
)

// SignalMessage é a única estrutura de dados que trafega pelo servidor.
// O servidor lê `type`, `room`, `from` e `to` para rotear — nunca inspeciona `data`.
type SignalMessage struct {
	Type string          `json:"type"`
	Room string          `json:"room"`
	From string          `json:"from"`
	To   string          `json:"to,omitempty"` // destino específico para offer/answer/ice-candidate
	Data json.RawMessage `json:"data,omitempty"`
}

type Handler struct {
	hub       *Hub
	jwtSecret []byte
}

func NewHandler(hub *Hub, jwtSecret []byte) *Handler {
	return &Handler{hub: hub, jwtSecret: jwtSecret}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Valida JWT antes de aceitar a conexão WebSocket
	tokenStr := r.URL.Query().Get("token")
	pubKey, err := auth.ValidateToken(tokenStr, h.jwtSecret)
	if err != nil {
		log.Printf("[WS] rejected connection — invalid JWT: %v", err)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	shortKey := shortPK(pubKey)
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: false,
	})
	if err != nil {
		log.Printf("[WS] accept error (pk=%s): %v", shortKey, err)
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	log.Printf("[WS] connected  pk=%s", shortKey)
	p := &peer{pubKey: pubKey, conn: conn}
	ctx := r.Context()

	// Loop principal: lê mensagens e repassa — sem inspecionar payload
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			break
		}

		var msg SignalMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			log.Printf("[WS] bad JSON from pk=%s: %v", shortKey, err)
			continue
		}
		if msg.Room == "" || msg.Type == "" {
			continue
		}

		// Sobrescreve `from` com a chave pública validada pelo JWT — não confiar no campo enviado pelo cliente
		msg.From = pubKey

		switch msg.Type {
		case "join":
			h.hub.Join(msg.Room, p)
			// Notifica o novo peer sobre quem já está na sala (room_peers).
			existingPeers := h.hub.GetPeers(msg.Room, pubKey)
			roomSize := h.hub.roomSize(msg.Room)
			log.Printf("[HUB] join  pk=%s room=%s peers_in_room=%d existing=%d", shortKey, shortRoom(msg.Room), roomSize, len(existingPeers))
			if len(existingPeers) > 0 {
				peersData, _ := json.Marshal(map[string]interface{}{"peers": existingPeers})
				roomPeersMsg, _ := json.Marshal(SignalMessage{
					Type: "room_peers",
					Room: msg.Room,
					From: "server",
					Data: json.RawMessage(peersData),
				})
				if err := conn.Write(ctx, websocket.MessageText, roomPeersMsg); err != nil {
					log.Printf("[WS] room_peers error pk=%s: %v", shortKey, err)
				}
			}
		case "leave":
			h.hub.Leave(msg.Room, pubKey)
			log.Printf("[HUB] leave pk=%s room=%s", shortKey, shortRoom(msg.Room))
		case "offer", "answer", "ice-candidate":
			out, err := json.Marshal(msg)
			if err != nil {
				continue
			}
			var n int
			if msg.To != "" {
				// Roteamento direto para peer específico (mesh topology).
				if h.hub.SendTo(msg.Room, msg.To, out) {
					n = 1
				}
			} else {
				// Broadcast para compatibilidade com clientes sem campo `to`.
				n = h.hub.Broadcast(msg.Room, pubKey, out)
			}
			log.Printf("[HUB] %-13s from=%s to=%s room=%s delivered_to=%d", msg.Type, shortKey, shortPK(msg.To), shortRoom(msg.Room), n)
		}
	}

	log.Printf("[WS] disconnected pk=%s", shortKey)
	// Limpeza ao desconectar — SPEC-ARCH-001: sem rastros em memória
	h.cleanupAllRooms(ctx, pubKey)
}

// shortPK retorna os primeiros 8 caracteres da chave pública para logs legíveis.
func shortPK(pk string) string {
	if len(pk) > 8 {
		return pk[:8] + "…"
	}
	return pk
}

// shortRoom retorna os primeiros 8 chars do UUID de room para logs.
func shortRoom(room string) string {
	if len(room) > 8 {
		return room[:8] + "…"
	}
	return room
}

func (h *Handler) cleanupAllRooms(ctx context.Context, pubKey string) {
	h.hub.mu.Lock()
	roomIDs := make([]string, 0, len(h.hub.rooms))
	for id := range h.hub.rooms {
		roomIDs = append(roomIDs, id)
	}
	h.hub.mu.Unlock()

	for _, id := range roomIDs {
		h.hub.Leave(id, pubKey)
	}
}
