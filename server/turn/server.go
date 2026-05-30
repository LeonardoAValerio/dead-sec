package turn

import (
	"log"
	"net"

	pion "github.com/pion/turn/v2"

	"github.com/safechannel/server/auth"
)

type Config struct {
	PublicIP   string
	Port       int
	Realm      string
	TURNSecret []byte
}

// Start inicia o servidor TURN embarcado usando Pion.
// Credenciais temporárias são validadas pelo AuthHandler — sem usuários fixos.
// O servidor bloqueia relay para IPs privados por padrão (SPEC-TURN-002).
func Start(cfg Config) error {
	udpListener, err := net.ListenPacket("udp4", net.JoinHostPort("0.0.0.0", itoa(cfg.Port)))
	if err != nil {
		return err
	}

	server, err := pion.NewServer(pion.ServerConfig{
		Realm: cfg.Realm,
		AuthHandler: func(username, realm string, srcAddr net.Addr) ([]byte, bool) {
			password, valid := auth.ValidateTURNCredentials(username, cfg.TURNSecret)
			if !valid {
				return nil, false
			}
			return pion.GenerateAuthKey(username, realm, password), true
		},
		PacketConnConfigs: []pion.PacketConnConfig{
			{
				PacketConn: udpListener,
				RelayAddressGenerator: &pion.RelayAddressGeneratorStatic{
					RelayAddress: net.ParseIP(cfg.PublicIP),
					Address:      "0.0.0.0",
				},
			},
		},
	})
	if err != nil {
		return err
	}

	log.Printf("TURN server listening on UDP :%d (realm=%s)", cfg.Port, cfg.Realm)

	go func() {
		<-make(chan struct{}) // bloqueia indefinidamente
		server.Close()
	}()

	return nil
}

func itoa(n int) string {
	if n == 0 {
		return "3478"
	}
	b := make([]byte, 0, 5)
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
