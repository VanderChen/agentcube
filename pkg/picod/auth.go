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
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/hkdf"
	"k8s.io/klog/v2"
)

const (
	keyFile = "picod_public_key.pem"
)

// AuthManager manages EC public key authentication
type AuthManager struct {
	publicKey         *ecdsa.PublicKey
	bootstrapKey      *ecdsa.PublicKey // Key injected at startup for init authentication
	sessionPriv1      *ecdsa.PrivateKey // Temporary session private key (Pair1)
	mutex             sync.RWMutex
	keyFile           string
	initialized       bool
	authMode          string
	maxBodySize       int64  // Maximum request body size in bytes
	encryptionEnabled bool   // Whether request encryption is forced
	onActivity        func() // Callback to update activity timestamp
}

// InitRequest represents initialization request (legacy)
type InitRequest struct {
	PublicKey string `json:"public_key"`
}

// InitResponse represents initialization response with Pair1 information
type InitResponse struct {
	Message            string `json:"message"`
	Pub1               string `json:"pub1"`                 // Base64(DER) of Pair1 Public Key
	EphemeralPublicKey string `json:"ephemeral_public_key"` // Base64(DER) of Tmp_Pub
	Nonce              string `json:"nonce"`                // Base64(12 bytes)
}

// NewAuthManager creates a new auth manager
func NewAuthManager(onActivity func(), maxBodySize int64, encryptionEnabled bool) *AuthManager {
	return &AuthManager{
		keyFile:           keyFile,
		initialized:       false,
		authMode:          AuthModeDynamic,
		maxBodySize:       maxBodySize,
		encryptionEnabled: encryptionEnabled,
		onActivity:        onActivity,
	}
}

// SetAuthMode sets the authentication mode
func (am *AuthManager) SetAuthMode(mode string) {
	am.authMode = mode
}

// SetInitialized sets the initialization state
func (am *AuthManager) SetInitialized(initialized bool) {
	am.mutex.Lock()
	defer am.mutex.Unlock()
	am.initialized = initialized
}

// GetAuthMode returns the current authentication mode
func (am *AuthManager) GetAuthMode() string {
	return am.authMode
}

// LoadStaticPublicKey loads the static public key from PICOD_PUBLIC_KEY environment variable
// The key must be base64 encoded PEM format
func (am *AuthManager) LoadStaticPublicKey() error {
	am.mutex.Lock()
	defer am.mutex.Unlock()

	keyEncoded := os.Getenv("PICOD_PUBLIC_KEY")
	if keyEncoded == "" {
		return fmt.Errorf("PICOD_PUBLIC_KEY environment variable is not set")
	}

	ecPub, err := parseECPublicKeyFromEncodedString(keyEncoded)
	if err != nil {
		return fmt.Errorf("failed to parse PICOD_PUBLIC_KEY: %v", err)
	}

	am.publicKey = ecPub
	am.initialized = true
	klog.Infof("Loaded static EC public key successfully")
	return nil
}

// LoadBootstrapKey loads the bootstrap public key from bytes
func (am *AuthManager) LoadBootstrapKey(keyData []byte) error {
	if len(keyData) == 0 {
		return fmt.Errorf("bootstrap key string is empty")
	}

	block, _ := pem.Decode(keyData)
	if block == nil {
		return fmt.Errorf("failed to decode bootstrap key PEM block")
	}

	pub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return fmt.Errorf("failed to parse bootstrap public key: %v", err)
	}

	ecPub, ok := pub.(*ecdsa.PublicKey)
	if !ok {
		return fmt.Errorf("bootstrap key is not an EC public key")
	}

	am.bootstrapKey = ecPub
	return nil
}

// LoadPublicKey loads public key from file
func (am *AuthManager) LoadPublicKey() error {
	am.mutex.Lock()
	defer am.mutex.Unlock()

	if _, err := os.Stat(am.keyFile); os.IsNotExist(err) {
		return fmt.Errorf("no public key file found, server not initialized")
	}

	data, err := os.ReadFile(am.keyFile)
	if err != nil {
		return fmt.Errorf("failed to read public key file: %v", err)
	}

	block, _ := pem.Decode(data)
	if block == nil {
		return fmt.Errorf("failed to decode PEM block")
	}

	pub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return fmt.Errorf("failed to parse public key: %v", err)
	}

	ecPub, ok := pub.(*ecdsa.PublicKey)
	if !ok {
		return fmt.Errorf("not an EC public key")
	}

	am.publicKey = ecPub
	am.initialized = true
	return nil
}

func (am *AuthManager) savePublicKeyLocked(publicKeyStr string) error {
	ecPub, err := parseECPublicKeyFromEncodedString(publicKeyStr)
	if err != nil {
		return fmt.Errorf("failed to parse session public key: %v", err)
	}

	// Normalize to PEM on disk so reload path stays stable.
	pubASN1, err := x509.MarshalPKIXPublicKey(ecPub)
	if err != nil {
		return fmt.Errorf("failed to marshal EC public key: %v", err)
	}
	publicKeyPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubASN1})

	// Check if already initialized
	if am.initialized {
		return fmt.Errorf("server already initialized with a public key")
	}

	// Save to file with read-only permissions
	if err := os.WriteFile(am.keyFile, publicKeyPEM, 0400); err != nil {
		return fmt.Errorf("failed to save public key file: %v", err)
	}

	// Try to make the file immutable (Linux only)
	if runtime.GOOS == "linux" {
		cmd := exec.Command("chattr", "+i", am.keyFile) //nolint:gosec // keyFile is internally managed
		if err := cmd.Run(); err != nil {
			klog.Warningf("failed to make key file immutable: %v. File permissions still set to read-only.", err)
		} else {
			klog.Info("Key file successfully set to immutable (chattr +i)")
		}
	} else {
		klog.Infof("Note: chattr command is Linux-specific. Current OS: %s. File permissions set to read-only.", runtime.GOOS)
	}

	am.publicKey = ecPub
	am.initialized = true
	return nil
}

func decodeBase64Auto(s string) ([]byte, error) {
	if b, err := base64.StdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return nil, fmt.Errorf("invalid base64 input")
}

// parseECPublicKeyFromEncodedString accepts:
// 1) Base64(PEM bytes)
// 2) Base64(DER PKIX bytes)
func parseECPublicKeyFromEncodedString(keyEncoded string) (*ecdsa.PublicKey, error) {
	keyBytes, err := decodeBase64Auto(keyEncoded)
	if err != nil {
		return nil, err
	}

	derBytes := keyBytes
	if block, _ := pem.Decode(keyBytes); block != nil {
		derBytes = block.Bytes
	}

	pub, err := x509.ParsePKIXPublicKey(derBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse public key: %v", err)
	}

	ecPub, ok := pub.(*ecdsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("not an EC public key")
	}

	return ecPub, nil
}

// IsInitialized checks if server is initialized
func (am *AuthManager) IsInitialized() bool {
	am.mutex.RLock()
	defer am.mutex.RUnlock()
	return am.initialized
}

// InitHandler handles initialization requests and key negotiation
func (am *AuthManager) InitHandler(c *gin.Context) {
	requestStart := time.Now()

	// Encryption negotiation is only supported in static key mode
	if am.authMode != AuthModeStatic {
		c.JSON(http.StatusForbidden, gin.H{
			"error":  "Key negotiation not supported",
			"code":   http.StatusForbidden,
			"detail": "Encryption negotiation is only available in static key mode",
		})
		return
	}

	authHeader := c.GetHeader("Authorization")
	if authHeader == "" {
		c.JSON(http.StatusUnauthorized, gin.H{
			"error":  "Missing Authorization header",
			"code":   http.StatusUnauthorized,
			"detail": "Init requires JWT authentication",
		})
		return
	}

	parts := strings.Split(authHeader, " ")
	if len(parts) != 2 || parts[0] != "Bearer" {
		c.JSON(http.StatusUnauthorized, gin.H{
			"error":  "Invalid Authorization header format",
			"code":   http.StatusUnauthorized,
			"detail": "Use Bearer <token>",
		})
		return
	}

	tokenString := parts[1]

	// Parse and validate JWT using the static public key (Pair0)
	token, err := jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
		if method, ok := token.Method.(*jwt.SigningMethodECDSA); !ok || method.Alg() != jwt.SigningMethodES256.Alg() {
			return nil, fmt.Errorf("unexpected signing method: %v, expected ES256", token.Header["alg"])
		}
		am.mutex.RLock()
		defer am.mutex.RUnlock()
		return am.publicKey, nil
	}, jwt.WithExpirationRequired(), jwt.WithIssuedAt(), jwt.WithLeeway(time.Minute))

	if err != nil || !token.Valid {
		c.JSON(http.StatusUnauthorized, gin.H{
			"error":  "Invalid token",
			"code":   http.StatusUnauthorized,
			"detail": fmt.Sprintf("JWT verification failed: %v", err),
		})
		return
	}

	// 1. Generate new session key pair (Pair1)
	newSessionPriv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Failed to generate session key pair",
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// 2. Encrypt Pub1 using Gateway's static public key (ECIES)
	am.mutex.RLock()
	pub0 := am.publicKey
	am.mutex.RUnlock()

	ecPub0, err := pub0.ECDH()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Failed to convert Pub0 to ECDH",
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Generate temporary key for the response wrapping
	tmpPriv, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Failed to generate temporary key",
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Compute shared secret S = ECDH(tmpPriv, ecPub0)
	sharedSecret, err := tmpPriv.ECDH(ecPub0)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Failed to compute shared secret",
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Derive wrapping key using HKDF
	kdf := hkdf.New(sha256.New, sharedSecret, nil, []byte("picod-init-wrap"))
	wrapKey := make([]byte, 32)
	if _, err := io.ReadFull(kdf, wrapKey); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Failed to derive wrapping key",
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Marshal Pub1 to PKIX DER
	pub1Bytes, err := x509.MarshalPKIXPublicKey(&newSessionPriv.PublicKey)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Failed to marshal Pub1",
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Encrypt pub1Bytes with wrapKey using AES-GCM
	block, err := aes.NewCipher(wrapKey)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Internal error",
			"code":  http.StatusInternalServerError,
		})
		return
	}
	aesGCM, err := cipher.NewGCM(block)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Internal error",
			"code":  http.StatusInternalServerError,
		})
		return
	}
	nonce := make([]byte, aesGCM.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "Internal error",
			"code":  http.StatusInternalServerError,
		})
		return
	}
	ciphertext := aesGCM.Seal(nil, nonce, pub1Bytes, nil)

	// Save session private key (Pair1)
	am.mutex.Lock()
	am.sessionPriv1 = newSessionPriv
	am.mutex.Unlock()

	c.JSON(http.StatusOK, InitResponse{
		Message:            "Session key negotiated successfully",
		Pub1:               base64.StdEncoding.EncodeToString(ciphertext),
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(tmpPriv.PublicKey().Bytes()),
		Nonce:              base64.StdEncoding.EncodeToString(nonce),
	})

	klog.Infof("[InitHandler] Key negotiation completed in %.3f seconds", time.Since(requestStart).Seconds())
}

// AuthMiddleware creates authentication middleware with JWT verification
func (am *AuthManager) AuthMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {

		// Check if server is initialized (only for dynamic mode or encryption init)
		if !am.IsInitialized() {
			c.JSON(http.StatusForbidden, gin.H{
				"error":  "Server not initialized",
				"code":   http.StatusForbidden,
				"detail": fmt.Sprintf("Please initialize this Picod instance first via /init. Request path is %s", c.Request.URL.Path),
			})
			c.Abort()
			return
		}

		// If encryption is forced, ensure Pair1 is ready
		am.mutex.RLock()
		isEncEnabled := am.encryptionEnabled
		hasSessionKey := am.sessionPriv1 != nil
		am.mutex.RUnlock()

		if isEncEnabled && !hasSessionKey {
			c.JSON(http.StatusForbidden, gin.H{
				"error":  "Encryption required",
				"code":   http.StatusForbidden,
				"detail": "Encryption is enabled but session key not initialized. Please call /init first.",
			})
			c.Abort()
			return
		}

		authHeader := c.GetHeader("Authorization")
		if authHeader == "" {
			c.JSON(http.StatusUnauthorized, gin.H{
				"error":  "Missing Authorization header",
				"code":   http.StatusUnauthorized,
				"detail": "Request requires JWT authentication",
			})
			c.Abort()
			return
		}

		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 || parts[0] != "Bearer" {
			c.JSON(http.StatusUnauthorized, gin.H{
				"error":  "Invalid Authorization header format",
				"code":   http.StatusUnauthorized,
				"detail": "Use Bearer <token>",
			})
			c.Abort()
			return
		}

		tokenString := parts[1]

		// Parse and validate JWT using Pair0 (Static Public Key)
		token, err := jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
			if method, ok := token.Method.(*jwt.SigningMethodECDSA); !ok || method.Alg() != jwt.SigningMethodES256.Alg() {
				return nil, fmt.Errorf("unexpected signing method: %v, expected ES256", token.Header["alg"])
			}
			am.mutex.RLock()
			defer am.mutex.RUnlock()
			return am.publicKey, nil
		}, jwt.WithExpirationRequired(), jwt.WithIssuedAt(), jwt.WithLeeway(time.Minute))

		if err != nil || !token.Valid {
			c.JSON(http.StatusUnauthorized, gin.H{
				"error":  "Invalid token",
				"code":   http.StatusUnauthorized,
				"detail": fmt.Sprintf("JWT verification failed: %v", err),
			})
			c.Abort()
			return
		}

		// Enforce maximum body size BEFORE reading to prevent memory exhaustion
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, am.maxBodySize)

		// Read body for integrity check and decryption
		var bodyBytes []byte
		if c.Request.Body != nil {
			var err error
			bodyBytes, err = io.ReadAll(c.Request.Body)
			if err != nil {
				if err.Error() == "http: request body too large" {
					c.JSON(http.StatusRequestEntityTooLarge, gin.H{
						"error":  "Request body too large",
						"code":   http.StatusRequestEntityTooLarge,
						"detail": fmt.Sprintf("Maximum %d bytes (%.2f MB) allowed", am.maxBodySize, float64(am.maxBodySize)/(1<<20)),
					})
					c.Abort()
					return
				}
				c.JSON(http.StatusInternalServerError, gin.H{
					"error":  "Failed to read request body",
					"code":   http.StatusInternalServerError,
					"detail": err.Error(),
				})
				c.Abort()
				return
			}
		}

		// Verify integrity (Hash of the Ciphertext if encrypted)
		claims, ok := token.Claims.(jwt.MapClaims)
		if !ok {
			c.JSON(http.StatusUnauthorized, gin.H{
				"error": "Invalid token claims",
				"code":  http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		claimedHash, _ := claims["canonical_request_sha256"].(string)
		if claimedHash != "" {
			actualHash := buildCanonicalRequestHash(c.Request, bodyBytes)
			if claimedHash != actualHash {
				klog.Warningf("[Auth] integrity check failed: expected %s, got %s", claimedHash, actualHash)
				c.JSON(http.StatusUnauthorized, gin.H{
					"error":  "Request integrity check failed",
					"code":   http.StatusUnauthorized,
					"detail": "canonical_request_sha256 mismatch - request may have been tampered",
				})
				c.Abort()
				return
			}
		}

		// Perform Decryption if enabled
		if isEncEnabled && len(bodyBytes) > 0 {
			ephPubB64 := c.GetHeader("X-Picod-Eph-Pub")
			nonceB64 := c.GetHeader("X-Picod-Nonce")

			if ephPubB64 == "" || nonceB64 == "" {
				c.JSON(http.StatusUnauthorized, gin.H{
					"error":  "Decryption failed",
					"code":   http.StatusUnauthorized,
					"detail": "Missing encryption metadata headers (X-Picod-Eph-Pub, X-Picod-Nonce)",
				})
				c.Abort()
				return
			}

			decryptedBody, err := am.decryptHybrid(bodyBytes, ephPubB64, nonceB64)
			if err != nil {
				klog.Errorf("[Auth] Decryption failed: %v", err)
				c.JSON(http.StatusUnauthorized, gin.H{
					"error":  "Decryption failed",
					"code":   http.StatusUnauthorized,
					"detail": fmt.Sprintf("Failed to decrypt request body: %v", err),
				})
				c.Abort()
				return
			}
			bodyBytes = decryptedBody
		}

		// Restore body for downstream handlers
		c.Request.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))

		// Update activity timestamp on successful authentication
		if am.onActivity != nil {
			am.onActivity()
		}

		c.Next()
	}
}

// decryptHybrid performs ECDH + AES-GCM decryption
func (am *AuthManager) decryptHybrid(ciphertext []byte, ephPubB64, nonceB64 string) ([]byte, error) {
	ephPubBytes, err := base64.StdEncoding.DecodeString(ephPubB64)
	if err != nil {
		return nil, fmt.Errorf("invalid eph-pub encoding: %v", err)
	}

	nonce, err := base64.StdEncoding.DecodeString(nonceB64)
	if err != nil {
		return nil, fmt.Errorf("invalid nonce encoding: %v", err)
	}

	am.mutex.RLock()
	priv1 := am.sessionPriv1
	am.mutex.RUnlock()

	if priv1 == nil {
		return nil, fmt.Errorf("session key not initialized")
	}

	// 1. Compute Shared Secret
	ecEphPub, err := ecdh.P256().NewPublicKey(ephPubBytes)
	if err != nil {
		return nil, fmt.Errorf("invalid eph-pub bytes: %v", err)
	}

	ecPriv1, err := priv1.ECDH()
	if err != nil {
		return nil, fmt.Errorf("failed to convert priv1 to ECDH: %v", err)
	}

	sharedSecret, err := ecPriv1.ECDH(ecEphPub)
	if err != nil {
		return nil, fmt.Errorf("ECDH failed: %v", err)
	}

	// 2. Derive SK using HKDF
	kdf := hkdf.New(sha256.New, sharedSecret, nil, []byte("picod-business-wrap"))
	sk := make([]byte, 32)
	if _, err := io.ReadFull(kdf, sk); err != nil {
		return nil, fmt.Errorf("HKDF failed: %v", err)
	}

	// 3. AES-GCM Decrypt
	block, err := aes.NewCipher(sk)
	if err != nil {
		return nil, err
	}
	aesGCM, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	plaintext, err := aesGCM.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("AES-GCM decryption failed: %v", err)
	}

	return plaintext, nil
}

// buildCanonicalRequestHash builds a canonical request string and returns its SHA256 hash
// Format: HTTPMethod + \n + URI + \n + QueryString + \n + CanonicalHeaders + \n + SignedHeaders + \n + BodyHash
func buildCanonicalRequestHash(r *http.Request, body []byte) string {
	// 1. HTTP Method
	method := strings.ToUpper(r.Method)

	// 2. Canonical URI (path only, percent-encoded to match what clients sign)
	uri := r.URL.EscapedPath()
	if uri == "" {
		uri = "/"
	}

	// 3. Canonical Query String (sorted)
	queryString := buildCanonicalQueryString(r)

	// 4. Canonical Headers (sorted, lowercase)
	canonicalHeaders, signedHeaders := buildCanonicalHeaders(r)

	// 5. Body hash
	bodyHash := fmt.Sprintf("%x", sha256.Sum256(body))

	// Build canonical request
	canonicalRequest := strings.Join([]string{
		method,
		uri,
		queryString,
		canonicalHeaders,
		signedHeaders,
		bodyHash,
	}, "\n")

	// Return SHA256 of canonical request
	hash := sha256.Sum256([]byte(canonicalRequest))
	return fmt.Sprintf("%x", hash)
}

// buildCanonicalQueryString builds a sorted query string
func buildCanonicalQueryString(r *http.Request) string {
	query := r.URL.Query()
	if len(query) == 0 {
		return ""
	}

	keys := make([]string, 0, len(query))
	for k := range query {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var pairs []string
	for _, k := range keys {
		values := query[k]
		sort.Strings(values)
		for _, v := range values {
			pairs = append(pairs, k+"="+v)
		}
	}

	return strings.Join(pairs, "&")
}

// buildCanonicalHeaders builds canonical headers string and returns signedHeaders list
func buildCanonicalHeaders(r *http.Request) (canonicalHeaders string, signedHeaders string) {
	// Only include content-type for request integrity
	headerMap := make(map[string]string)

	if v := r.Header.Get("Content-Type"); v != "" {
		headerMap["content-type"] = strings.TrimSpace(v)
	}

	// Sort header names
	keys := make([]string, 0, len(headerMap))
	for k := range headerMap {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	// Build canonical headers and signed headers
	var headerLines []string
	for _, k := range keys {
		headerLines = append(headerLines, k+":"+headerMap[k])
	}

	if len(headerLines) > 0 {
		canonicalHeaders = strings.Join(headerLines, "\n") + "\n"
	} else {
		canonicalHeaders = "\n"
	}
	signedHeaders = strings.Join(keys, ";")

	return canonicalHeaders, signedHeaders
}
