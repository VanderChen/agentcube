package picod

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/hkdf"
)

func TestPicod_Encryption(t *testing.T) {
	// 1. Setup Keys (Pair0)
	gatewayPriv, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	gatewayPub := &gatewayPriv.PublicKey
	pubASN1, _ := x509.MarshalPKIXPublicKey(gatewayPub)
	gatewayPubB64 := base64.StdEncoding.EncodeToString(pubASN1)

	// 2. Setup Server in Static Mode with Encryption Enabled
	tmpDir, err := os.MkdirTemp("", "picod_enc_test")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	os.Setenv("PICOD_PUBLIC_KEY", gatewayPubB64)
	os.Setenv("PICOD_ENCRYPTION_ENABLED", "true")
	defer os.Unsetenv("PICOD_PUBLIC_KEY")
	defer os.Unsetenv("PICOD_ENCRYPTION_ENABLED")

	config := Config{
		Port:      0,
		Workspace: tmpDir,
		AuthMode:  AuthModeStatic,
	}

	server := NewServer(config)
	ts := httptest.NewServer(server.engine)
	defer ts.Close()
	client := ts.Client()

	var pub1 *ecdsa.PublicKey

	t.Run("Forced Encryption - Uninitialized Check", func(t *testing.T) {
		// Attempt to call execute before /init
		req, _ := http.NewRequest("POST", ts.URL+"/api/execute", bytes.NewBuffer([]byte("{}")))
		resp, err := client.Do(req)
		require.NoError(t, err)
		assert.Equal(t, http.StatusForbidden, resp.StatusCode)
		
		body, _ := io.ReadAll(resp.Body)
		assert.Contains(t, string(body), "Encryption is enabled but session key not initialized")
	})

	t.Run("Key Negotiation (/init)", func(t *testing.T) {
		// Create JWT signed by gateway private key (Pair0)
		claims := jwt.MapClaims{
			"iat": time.Now().Unix(),
			"exp": time.Now().Add(time.Hour).Unix(),
		}
		token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
		tokenString, _ := token.SignedString(gatewayPriv)

		req, _ := http.NewRequest("POST", ts.URL+"/init", nil)
		req.Header.Set("Authorization", "Bearer "+tokenString)
		
		resp, err := client.Do(req)
		require.NoError(t, err)
		assert.Equal(t, http.StatusOK, resp.StatusCode)

		var initResp InitResponse
		err = json.NewDecoder(resp.Body).Decode(&initResp)
		require.NoError(t, err)
		assert.NotEmpty(t, initResp.Pub1)

		// Decrypt Pub1 using Pair0
		tmpPubBytes, _ := base64.StdEncoding.DecodeString(initResp.EphemeralPublicKey)
		tmpPub, _ := ecdh.P256().NewPublicKey(tmpPubBytes)
		
		gatewayPrivECDH, _ := gatewayPriv.ECDH()
		sharedSecret, _ := gatewayPrivECDH.ECDH(tmpPub)
		
		kdf := hkdf.New(sha256.New, sharedSecret, nil, []byte("picod-init-wrap"))
		wrapKey := make([]byte, 32)
		io.ReadFull(kdf, wrapKey)

		block, _ := aes.NewCipher(wrapKey)
		aesGCM, _ := cipher.NewGCM(block)
		nonce, _ := base64.StdEncoding.DecodeString(initResp.Nonce)
		ciphertext, _ := base64.StdEncoding.DecodeString(initResp.Pub1)
		
		pub1Bytes, err := aesGCM.Open(nil, nonce, ciphertext, nil)
		require.NoError(t, err)
		
		pub1Generic, err := x509.ParsePKIXPublicKey(pub1Bytes)
		require.NoError(t, err)
		pub1 = pub1Generic.(*ecdsa.PublicKey)
	})

	t.Run("Encrypted Business Request", func(t *testing.T) {
		execReq := ExecuteRequest{Command: []string{"echo", "hybrid_hello"}}
		plaintext, _ := json.Marshal(execReq)

		// 1. Generate Request-level SK using Pair1
		ephPriv, _ := ecdh.P256().GenerateKey(rand.Reader)
		pub1ECDH, _ := pub1.ECDH()
		sharedSecret, _ := ephPriv.ECDH(pub1ECDH)
		
		kdf := hkdf.New(sha256.New, sharedSecret, nil, []byte("picod-business-wrap"))
		sk := make([]byte, 32)
		io.ReadFull(kdf, sk)

		// 2. Encrypt Body
		block, _ := aes.NewCipher(sk)
		aesGCM, _ := cipher.NewGCM(block)
		nonce := make([]byte, aesGCM.NonceSize())
		rand.Read(nonce)
		ciphertext := aesGCM.Seal(nil, nonce, plaintext, nil)

		// 3. Create JWT with Hash of Ciphertext
		bodyHash := sha256.Sum256(ciphertext)
		canonicalReq := strings.Join([]string{
			"POST",
			"/api/execute",
			"", // Query
			"content-type:application/octet-stream\n",
			"content-type",
			fmt.Sprintf("%x", bodyHash),
		}, "\n")
		reqHash := sha256.Sum256([]byte(canonicalReq))

		claims := jwt.MapClaims{
			"canonical_request_sha256": fmt.Sprintf("%x", reqHash),
			"iat":                      time.Now().Unix(),
			"exp":                      time.Now().Add(time.Hour).Unix(),
		}
		token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
		tokenString, _ := token.SignedString(gatewayPriv)

		// 4. Send Request with Headers
		req, _ := http.NewRequest("POST", ts.URL+"/api/execute", bytes.NewBuffer(ciphertext))
		req.Header.Set("Authorization", "Bearer "+tokenString)
		req.Header.Set("Content-Type", "application/octet-stream")
		req.Header.Set("X-Picod-Eph-Pub", base64.StdEncoding.EncodeToString(ephPriv.PublicKey().Bytes()))
		req.Header.Set("X-Picod-Nonce", base64.StdEncoding.EncodeToString(nonce))

		resp, err := client.Do(req)
		require.NoError(t, err)
		assert.Equal(t, http.StatusOK, resp.StatusCode)

		var execResp ExecuteResponse
		err = json.NewDecoder(resp.Body).Decode(&execResp)
		require.NoError(t, err)
		assert.Equal(t, "hybrid_hello\n", execResp.Stdout)
	})

	t.Run("Decryption Failure - Wrong Metadata", func(t *testing.T) {
		req, _ := http.NewRequest("POST", ts.URL+"/api/execute", bytes.NewBuffer([]byte("bad cipher")))
		
		claims := jwt.MapClaims{
			"iat": time.Now().Unix(),
			"exp": time.Now().Add(time.Hour).Unix(),
		}
		token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
		tokenString, _ := token.SignedString(gatewayPriv)

		req.Header.Set("Authorization", "Bearer "+tokenString)
		req.Header.Set("X-Picod-Eph-Pub", "invalid-base64")
		req.Header.Set("X-Picod-Nonce", base64.StdEncoding.EncodeToString(make([]byte, 12)))

		resp, err := client.Do(req)
		require.NoError(t, err)
		assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
		
		body, _ := io.ReadAll(resp.Body)
		assert.Contains(t, string(body), "Decryption failed")
	})
}
