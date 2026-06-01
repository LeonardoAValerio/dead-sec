package signaling

import (
	"context"
	"sync"

	"nhooyr.io/websocket"
)

// peer representa um cliente conectado ao servidor de sinalização.
type peer struct {
	pubKey string
	conn   *websocket.Conn
}

// Room agrupa peers pelo mesmo channel/room ID.
// Toda a estrutura existe apenas em memória — ao desconectar, o peer é removido.
// Nenhum dado é persistido (SPEC-ARCH-001).
type Room struct {
	mu    sync.RWMutex
	peers map[string]*peer // pubKey → peer
}

func newRoom() *Room {
	return &Room{peers: make(map[string]*peer)}
}

func (r *Room) add(p *peer) {
	r.mu.Lock()
	r.peers[p.pubKey] = p
	r.mu.Unlock()
}

func (r *Room) remove(pubKey string) {
	r.mu.Lock()
	delete(r.peers, pubKey)
	r.mu.Unlock()
}

func (r *Room) isEmpty() bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.peers) == 0
}

// broadcast envia uma mensagem para todos os peers da room exceto o remetente.
// Retorna o número de peers alcançados.
func (r *Room) broadcast(fromPubKey string, msg []byte) int {
	r.mu.RLock()
	targets := make([]*peer, 0, len(r.peers))
	for pk, p := range r.peers {
		if pk != fromPubKey {
			targets = append(targets, p)
		}
	}
	r.mu.RUnlock()

	sent := 0
	for _, p := range targets {
		if err := p.conn.Write(context.Background(), websocket.MessageText, msg); err == nil {
			sent++
		}
	}
	return sent
}

// Hub gerencia todas as rooms ativas.
type Hub struct {
	mu    sync.RWMutex
	rooms map[string]*Room
}

func NewHub() *Hub {
	return &Hub{rooms: make(map[string]*Room)}
}

func (h *Hub) getOrCreateRoom(roomID string) *Room {
	h.mu.Lock()
	defer h.mu.Unlock()
	if r, ok := h.rooms[roomID]; ok {
		return r
	}
	r := newRoom()
	h.rooms[roomID] = r
	return r
}

func (h *Hub) cleanupRoom(roomID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if r, ok := h.rooms[roomID]; ok && r.isEmpty() {
		delete(h.rooms, roomID)
	}
}

// Join adiciona um peer a uma room.
func (h *Hub) Join(roomID string, p *peer) {
	h.getOrCreateRoom(roomID).add(p)
}

// Leave remove um peer da room e limpa a room se estiver vazia.
func (h *Hub) Leave(roomID, pubKey string) {
	h.mu.RLock()
	r, ok := h.rooms[roomID]
	h.mu.RUnlock()
	if !ok {
		return
	}
	r.remove(pubKey)
	h.cleanupRoom(roomID)
}

// Broadcast repassa uma mensagem para os outros peers da room.
// Retorna o número de peers que receberam a mensagem.
func (h *Hub) Broadcast(roomID, fromPubKey string, msg []byte) int {
	h.mu.RLock()
	r, ok := h.rooms[roomID]
	h.mu.RUnlock()
	if ok {
		return r.broadcast(fromPubKey, msg)
	}
	return 0
}

// roomSize retorna o número de peers atualmente na room.
func (h *Hub) roomSize(roomID string) int {
	h.mu.RLock()
	r, ok := h.rooms[roomID]
	h.mu.RUnlock()
	if !ok {
		return 0
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.peers)
}
