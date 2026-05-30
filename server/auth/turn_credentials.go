package auth

import (
	"crypto/hmac"
	"crypto/sha1" //nolint:gosec // TURN protocol exige SHA1 para compatibilidade com RFC 8489
	"encoding/base64"
	"fmt"
	"time"
)

// GenerateTURNCredentials gera credenciais temporárias para o servidor TURN.
// Segue o padrão de credenciais temporárias do TURN (RFC 8489 / coturn).
// Validade: 10 minutos. Credenciais expiradas são rejeitadas pelo AuthHandler do Pion TURN.
func GenerateTURNCredentials(pubKey string, secret []byte) (username, password string) {
	expiry := time.Now().Add(10 * time.Minute).Unix()
	username = fmt.Sprintf("%d:%s", expiry, pubKey)

	mac := hmac.New(sha1.New, secret) //nolint:gosec
	mac.Write([]byte(username))
	password = base64.StdEncoding.EncodeToString(mac.Sum(nil))
	return
}

// ValidateTURNCredentials valida se um par username/password ainda é válido e foi gerado com o secret correto.
func ValidateTURNCredentials(username string, secret []byte) (password string, valid bool) {
	var expiry int64
	var pubKey string
	if _, err := fmt.Sscanf(username, "%d:%s", &expiry, &pubKey); err != nil {
		return "", false
	}
	if time.Now().Unix() > expiry {
		return "", false
	}
	mac := hmac.New(sha1.New, secret) //nolint:gosec
	mac.Write([]byte(username))
	password = base64.StdEncoding.EncodeToString(mac.Sum(nil))
	return password, true
}
