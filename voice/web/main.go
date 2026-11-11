// voice-web serves a one-page browser client for the local voice agent. It
// gives each visitor a LiveKit access token for a fresh room; the voice agent
// joins every new room automatically.
package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"time"
)

//go:embed index.html
var page []byte

func main() {
	addr := flag.String("addr", "127.0.0.1:8090", "listen address")
	livekitURL := flag.String("livekit-url", "ws://localhost:7880", "LiveKit URL as seen from the browser")
	flag.Parse()
	apiKey := envOr("LIVEKIT_API_KEY", "devkey")
	apiSecret := envOr("LIVEKIT_API_SECRET", "secret")

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(page)
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /config", func(w http.ResponseWriter, _ *http.Request) {
		room, identity := "voice-"+randomHex(4), "user-"+randomHex(4)
		token, err := accessToken(apiKey, apiSecret, room, identity, time.Hour)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(map[string]string{"url": *livekitURL, "token": token, "room": room})
	})
	log.Printf("voice-web listening on %s, LiveKit at %s", *addr, *livekitURL)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

// accessToken returns a LiveKit access token: an HS256 JWT signed with the API
// secret, allowing identity to join, publish to and subscribe in room.
func accessToken(apiKey, apiSecret, room, identity string, ttl time.Duration) (string, error) {
	now := time.Now()
	claims := map[string]any{
		"iss":  apiKey,
		"sub":  identity,
		"name": identity,
		"nbf":  now.Add(-10 * time.Second).Unix(),
		"exp":  now.Add(ttl).Unix(),
		"video": map[string]any{
			"room": room, "roomJoin": true,
			"canPublish": true, "canSubscribe": true, "canPublishData": true,
		},
	}
	header, err := json.Marshal(map[string]string{"alg": "HS256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	enc := base64.RawURLEncoding
	unsigned := enc.EncodeToString(header) + "." + enc.EncodeToString(payload)
	mac := hmac.New(sha256.New, []byte(apiSecret))
	mac.Write([]byte(unsigned))
	return unsigned + "." + enc.EncodeToString(mac.Sum(nil)), nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
