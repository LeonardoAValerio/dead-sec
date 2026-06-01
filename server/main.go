package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"

	"github.com/safechannel/server/auth"
	"github.com/safechannel/server/signaling"
	"github.com/safechannel/server/turn"
)

func main() {
	cfg := loadConfig()

	// Servidor TURN embarcado
	if err := turn.Start(turn.Config{
		PublicIP:   cfg.PublicIP,
		Port:       3478,
		Realm:      cfg.Domain,
		TURNSecret: []byte(cfg.TURNSecret),
	}); err != nil {
		log.Fatalf("TURN start error: %v", err)
	}

	hub := signaling.NewHub()
	sigHandler := signaling.NewHandler(hub, []byte(cfg.JWTSecret))

	mux := http.NewServeMux()

	// WebSocket de sinalização — apenas repassa SDP/ICE, nunca armazena (SPEC-ARCH-001)
	mux.Handle("/ws", sigHandler)

	// Endpoint para emitir JWT anônimo (identificação por chave pública)
	mux.HandleFunc("/auth/token", func(w http.ResponseWriter, r *http.Request) {
		pubKey := r.URL.Query().Get("pk")
		if pubKey == "" {
			http.Error(w, "missing pk", http.StatusBadRequest)
			return
		}
		token, err := auth.IssueToken(pubKey, []byte(cfg.JWTSecret))
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		shortKey := pubKey
		if len(shortKey) > 8 {
			shortKey = shortKey[:8] + "…"
		}
		log.Printf("[AUTH] token issued pk=%s", shortKey)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"token": token})
	})

	// Endpoint para credenciais TURN temporárias (requer JWT válido)
	mux.HandleFunc("/turn/credentials", func(w http.ResponseWriter, r *http.Request) {
		tokenStr := r.Header.Get("Authorization")
		if len(tokenStr) > 7 && tokenStr[:7] == "Bearer " {
			tokenStr = tokenStr[7:]
		}
		pubKey, err := auth.ValidateToken(tokenStr, []byte(cfg.JWTSecret))
		if err != nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		username, password := auth.GenerateTURNCredentials(pubKey, []byte(cfg.TURNSecret))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"username": username,
			"password": password,
			"ttl":      "600",
		})
	})

	addr := ":" + cfg.Port
	log.Printf("SafeChannel signaling server on %s", addr)

	if cfg.TLSCert != "" && cfg.TLSKey != "" {
		log.Fatal(http.ListenAndServeTLS(addr, cfg.TLSCert, cfg.TLSKey, mux))
	} else {
		log.Println("WARNING: running without TLS — use only for local development")
		log.Fatal(http.ListenAndServe(addr, mux))
	}
}

type serverConfig struct {
	Port       string
	Domain     string
	PublicIP   string
	JWTSecret  string
	TURNSecret string
	TLSCert    string
	TLSKey     string
}

func loadConfig() serverConfig {
	return serverConfig{
		Port:       getEnv("PORT", "8080"),
		Domain:     getEnv("DOMAIN", "localhost"),
		PublicIP:   getEnv("PUBLIC_IP", "127.0.0.1"),
		JWTSecret:  getEnv("JWT_SECRET", "change-me-in-production"),
		TURNSecret: getEnv("TURN_SECRET", "change-me-in-production"),
		TLSCert:    getEnv("TLS_CERT", ""),
		TLSKey:     getEnv("TLS_KEY", ""),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
