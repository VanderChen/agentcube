# PicoD API 参考手册 (Static Auth + Encryption 增强版)

本文档面向需要在 **Static Auth Mode (静态认证)** 下启用 **Encrypted Request Mode (请求加密)** 的开发者。

## 1. 核心流程概述

在启用加密模式 (`PICOD_ENCRYPTION_ENABLED=true`) 后，客户端与服务端的通信分为两个阶段：

1.  **阶段一：密钥协商 (/init)**
    - 建立互信，获取服务端业务公钥 (Pair1_Pub)。
    - 该过程通过客户端已知的静态私钥 (Pair0_Priv) 保护。
2.  **阶段二：业务请求 (如 /api/run_python)**
    - 使用协商好的 Pair1_Pub 进行混合加密。
    - 每次请求均使用临时密钥加密，并附带请求完整性校验。

---

## 2. 阶段一：密钥协商 (/init)

即使在静态模式下，加密模式也要求先调用 `/init`。此接口用于安全地将服务端生成的 **会话公钥 (Pair1_Pub)** 传输给客户端。

### 请求详情
- **Method**: `POST`
- **Path**: `/init`
- **Headers**:
  - `Authorization: Bearer <JWT>`
    - 必须使用客户端的 **静态私钥 (Pair0_Priv)** 签名。
    - 声明要求：`exp`, `iat`。

### 响应详情 (JSON)
```json
{
  "message": "Session key negotiated successfully",
  "pub1": "base64-encoded-ciphertext",
  "ephemeral_public_key": "base64-encoded-Tmp_Pub",
  "nonce": "base64-encoded-12-byte-nonce"
}
```

### 客户端解密逻辑 (ECIES-like)
1.  **计算共享密钥**: $S = ECDH(\text{Pair0\_Priv}, \text{Tmp\_Pub})$。
2.  **派生包裹密钥**: $K_{wrap} = HKDF(S, \text{info="picod-init-wrap"})$。
3.  **解密公钥**: 使用 AES-GCM ($K_{wrap}$, $Nonce$) 解密 `pub1` 字段，得到 **Pair1_Pub** (会话公钥)。

---

## 3. 阶段二：业务请求示例 (/api/run_python)

在获取 `Pair1_Pub` 后，后续所有业务请求必须加密发送。

### 加密逻辑 (Encrypt-then-Sign)
1.  **生成临时密钥**: 客户端生成一对临时密钥 (`Eph_Priv`, `Eph_Pub`)。
2.  **计算共享密钥**: $S_{biz} = ECDH(\text{Eph\_Priv}, \text{Pair1\_Pub})$。
3.  **派生业务密钥**: $SK = HKDF(S_{biz}, \text{info="picod-business-wrap"})$。
4.  **AES 加密**: 使用 AES-GCM ($SK$) 加密原始内容 `{"code": "..."}`，得到 `Ciphertext` 和 `Nonce_Biz`。

### 请求构建
- **Method**: `POST`
- **Path**: `/api/run_python`
- **Headers**:
  - `X-Picod-Eph-Pub`: Base64 编码的 `Eph_Pub` (DER 或 Uncompressed)。
  - `X-Picod-Nonce`: Base64 编码的 `Nonce_Biz`。
  - `Authorization: Bearer <JWT>`
    - `JWT.claims.canonical_request_sha256` 必须基于 **密文 (Ciphertext)** 计算。
- **Body**: 二进制格式的 `Ciphertext`。

---

## 4. 客户端实现示例 (Python)

```python
import base64, hashlib, os, requests, jwt
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# 1. 初始化阶段
# 假设 bootstrap_priv 是你的静态私钥 (Pair0_Priv)
token = jwt.encode({'iat': now, 'exp': now + 300}, bootstrap_priv, algorithm='ES256')
resp = requests.post("http://picod/init", headers={'Authorization': f'Bearer {token}'})
data = resp.json()

# 解密获取 Pair1_Pub
tmp_pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), base64.b64decode(data['ephemeral_public_key']))
shared_secret = bootstrap_priv.exchange(ec.ECDH(), tmp_pub)
wrap_key = HKDF(hashes.SHA256(), 32, None, b"picod-init-wrap").derive(shared_secret)
pair1_pub_der = AESGCM(wrap_key).decrypt(base64.b64decode(data['nonce']), base64.b64decode(data['pub1']), None)
pair1_pub = serialization.load_der_public_key(pair1_pub_der)

# 2. 发送加密业务请求
plaintext = b'{"code": "print(42)"}'
eph_priv = ec.generate_private_key(ec.SECP256R1())
biz_secret = eph_priv.exchange(ec.ECDH(), pair1_pub)
sk = HKDF(hashes.SHA256(), 32, None, b"picod-business-wrap").derive(biz_secret)

nonce_biz = os.urandom(12)
ciphertext = AESGCM(sk).encrypt(nonce_biz, plaintext, None)

# 计算基于密文的摘要并签名 JWT
headers = {
    'X-Picod-Eph-Pub': base64.b64encode(eph_priv.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)).decode(),
    'X-Picod-Nonce': base64.b64encode(nonce_biz).decode(),
}
# JWT 计算逻辑省略...
requests.post("http://picod/api/run_python", headers=headers, data=ciphertext)
```

## 5. 常见问题 (FAQ)

- **为什么静态模式还需要 /init?**
  为了实现前向安全性 (Forward Secrecy)，我们不直接使用静态密钥加密业务数据，而是通过静态密钥保护“业务会话密钥”的协商。
- **JWT 摘要不匹配？**
  确保在计算 `canonical_request_sha256` 时，Body 传入的是加密后的 **二进制密文**，而不是解密前的 JSON 字符串。
