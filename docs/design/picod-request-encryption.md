# Design Document: Picod Request Encryption

## 1. Overview
This document describes the design for adding a request encryption layer to `picod`. The goal is to ensure data confidentiality between a Gateway (client) and `picod` (server) using a simplified TLS-like key negotiation mechanism.

## 2. Key Components
- **Asymmetric Encryption (ECC)**: NIST P-256 (secp256r1) for key negotiation and JWT signing.
- **Symmetric Encryption**: AES-256-GCM for request payload encryption.
- **Key Derivation Function (KDF)**: HKDF-SHA256 for deriving wrapping keys from ECDH shared secrets.
- **Authentication**: Existing JWT (ES256) scheme.

## 3. Key Negotiation Phase (`/init`)

The `/init` endpoint is repurposed for key negotiation. It is only available in `static` authentication mode, where `picod` is pre-configured with the Gateway's public key.

### 3.1 Flow
1. **Gateway** generates a JWT signed with its private key.
2. **Gateway** sends `POST /init` with the JWT in the `Authorization` header.
3. **Picod** verifies the JWT using the configured static public key.
4. **Picod** generates a random 32-byte session key ($K_{session}$).
5. **Picod** generates an ephemeral EC key pair $(e_p, E_p)$.
6. **Picod** computes a shared secret $S = ECDH(e_p, G_{pub})$, where $G_{pub}$ is the Gateway's static public key.
7. **Picod** derives a wrapping key $K_{wrap} = HKDF(S)$.
8. **Picod** encrypts $K_{session}$ using $K_{wrap}$ with AES-256-GCM to produce ciphertext $C_{session}$ and nonce $N_{session}$.
9. **Picod** returns $E_p$, $C_{session}$, and $N_{session}$ to the Gateway.
10. **Gateway** receives the response, computes $S = ECDH(G_{priv}, E_p)$, derives $K_{wrap}$, and decrypts $C_{session}$ to obtain $K_{session}$.

### 3.2 `/init` Response Structure
```json
{
  "ephemeral_public_key": "base64-encoded-DER",
  "encrypted_session_key": "base64-encoded-ciphertext",
  "nonce": "base64-encoded-12-byte-nonce"
}
```

## 4. Subsequent Request Phase

After key negotiation, all requests to `/api/*` endpoints must be encrypted.

### 4.1 Order of Operations (Encrypt-then-Sign)

Encryption and signing are performed in the following order to ensure both confidentiality and integrity:

**Gateway (Sender):**
1. **Encrypt**: Encrypt the plaintext request body ($P$) using $K_{session}$ and a random nonce ($N$).
   - $C = AES-GCM-Encrypt(K_{session}, N, P)$
   - Resulting payload: $N + C$ (concatenated)
2. **Hash**: Compute $H = SHA256(N + C)$.
3. **Sign**: Create a JWT with the claim `canonical_request_sha256: H`. Sign it with the Gateway's private key.
4. **Send**: Send `POST` request with `Authorization: Bearer <JWT>` and binary body $(N + C)$.

**Picod (Receiver):**
1. **Verify Signature**: Verify the JWT signature using the Gateway's public key.
2. **Verify Integrity**: Compute $H' = SHA256(\text{Request Body})$ and verify $H' == JWT.claims.canonical\_request\_sha256$.
3. **Decrypt**: Split the body into nonce $N$ and ciphertext $C$.
   - $P = AES-GCM-Decrypt(K_{session}, N, C)$
4. **Process**: Pass the decrypted plaintext body $P$ to the respective API handlers.

## 5. Security Considerations
- **Non-Generic**: This protocol assumes `picod` is not being impersonated (no server certificate validation). It focuses on securing the link between a trusted Gateway and a `picod` instance.
- **Symmetric Key Rotation**: The session key $K_{session}$ is valid for the lifetime of the `picod` process or until a new `/init` is performed (if allowed).
- **Static Mode Only**: This encryption layer is strictly for the `static` authentication mode.

## 6. Implementation Details

### 6.1 `AuthManager` Updates
- Store `sessionKey []byte`.
- Add `EncryptionEnabled bool` flag.
- Implement ECIES-like logic for `/init`.
- Update `AuthMiddleware` to handle decryption.

### 6.2 Data Format
Encrypted request bodies will be sent as `application/octet-stream`. The structure will be:
- Bytes 0-11: AES-GCM Nonce (12 bytes)
- Bytes 12+: Ciphertext + Tag
