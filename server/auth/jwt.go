package auth

import (
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var ErrInvalidToken = errors.New("invalid token")

type Claims struct {
	PubKey string `json:"pk"`
	jwt.RegisteredClaims
}

// IssueToken cria um JWT anônimo para o peer identificado por sua chave pública.
// O token expira em 24h — suficiente para uma sessão, sem armazenar identidade no servidor.
func IssueToken(pubKeyBase64 string, secret []byte) (string, error) {
	claims := Claims{
		PubKey: pubKeyBase64,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(24 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(secret)
}

// ValidateToken valida o JWT e retorna a chave pública do peer.
func ValidateToken(tokenStr string, secret []byte) (string, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrInvalidToken
		}
		return secret, nil
	})
	if err != nil || !token.Valid {
		return "", ErrInvalidToken
	}
	claims, ok := token.Claims.(*Claims)
	if !ok || claims.PubKey == "" {
		return "", ErrInvalidToken
	}
	return claims.PubKey, nil
}
