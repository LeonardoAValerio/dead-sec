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
// O servidor lê `type`, `room` e `from` para rotear — nunca inspeciona `data`.
type SignalMessage struct {
	Type string          `json:"type"`
	Room string          `json:"room"`
	From string          `json:"from"`
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
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: false,
	})
	if err != nil {
		log.Printf("ws accept error: %v", err)
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

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
		case "leave":
			h.hub.Leave(msg.Room, pubKey)
		case "offer", "answer", "ice-candidate":
			out, err := json.Marshal(msg)
			if err != nil {
				continue
			}
			h.hub.Broadcast(msg.Room, pubKey, out)
		}
	}

	// Limpeza ao desconectar — SPEC-ARCH-001: sem rastros em memória
	h.cleanupAllRooms(ctx, pubKey)
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
