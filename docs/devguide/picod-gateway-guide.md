# Picod Gateway 集成指南

本文档从网关（Gateway）的视角描述如何集成 Picod，包括需要为 Picod 指定的环境变量、认证与加密流程，以及 Java 版的加解密示例代码。

## 1. Picod 服务端配置

当网关作为 Picod 的客户端时，通常建议将 Picod 配置为 **静态认证模式 (Static Auth Mode)** 并启用 **请求加密**。

### 关键环境变量

| 变量名 | 推荐值 | 说明 |
| :--- | :--- | :--- |
| `PICOD_AUTH_MODE` | `static` | **必须**。启用静态认证模式，网关无需调用 `/init` 进行身份注册。 |
| `PICOD_PUBLIC_KEY` | `Base64(PEM)` | **必须**。网关的公钥（EC P-256）。Picod 将使用此公钥验证网关签发的 JWT。 |
| `PICOD_ENCRYPTION_ENABLED` | `true` | **建议**。强制要求所有业务请求必须经过加密，提升安全性。 |
| `PICOD_FORCE_OCTET_STREAM` | `true` | **建议**。强制所有 API 响应返回 `application/octet-stream`，便于网关统一处理二进制流。 |
| `PICOD_PORT` | `8080` | Picod 监听的端口。 |
| `PICOD_WORKSPACE` | `/tmp/picod` | Picod 的工作目录，存放上传的文件和代码。 |

---

## 2. 认证与加密流程

Picod 采用了 **JWT 认证 + 混合加密 (Hybrid Encryption)** 的机制。

### 2.1 初始化阶段 (Key Negotiation)

虽然是静态模式，但为了协商对称加密密钥，仍需执行一次初始化：

1. **网关** 生成一个 JWT（使用网关私钥签名，ES256 算法）。
2. **网关** 调用 `POST /init`，在 `Authorization` 头中携带 JWT。
3. **Picod** 返回加密后的会话公钥 `Pub1`、临时公钥 `E_p` 和 `nonce`。
4. **网关** 使用自己的私钥与 `E_p` 进行 ECDH 算出共享密钥，通过 HKDF 派生出 `wrapKey`，解密得到 `Pub1`。

### 2.2 业务请求阶段 (Data Transfer)

对于 `/api/*` 下的所有请求：

1. **网关** 生成一个临时密钥对 `ephPriv_G` / `EphPub_G`。
2. **网关** 使用 `ephPriv_G` 与 `Pub1` 进行 ECDH 算出共享密钥。
3. **网关** 通过 HKDF 派生出对称密钥 `sk` (AES-256)。
4. **网关** 使用 `sk` 加密请求体。
5. **网关** 发送请求，包含以下 Header：
   - `Authorization: Bearer <JWT>`
   - `X-Picod-Eph-Pub: <Base64(EphPub_G)>`
   - `X-Picod-Nonce: <Base64(nonce)>`
   - 请求体为加密后的二进制数据。

---

## 3. Java 示例代码

以下示例展示了网关如何实现上述流程。

### 依赖配置 (Maven)

```xml
<dependencies>
    <!-- JWT 库 -->
    <dependency>
        <groupId>com.nimbusds</groupId>
        <artifactId>nimbus-jose-jwt</artifactId>
        <version>9.37.3</version>
    </dependency>
    <!-- BouncyCastle (可选，若 JVM 自带算法支持不全) -->
    <dependency>
        <groupId>org.bouncycastle</groupId>
        <artifactId>bcprov-jdk18on</artifactId>
        <version>1.77</version>
    </dependency>
</dependencies>
```

### Java 实现

```java
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.*;
import com.nimbusds.jwt.*;
import org.bouncycastle.jce.provider.BouncyCastleProvider;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.security.*;
import java.security.interfaces.ECPrivateKey;
import java.security.interfaces.ECPublicKey;
import java.security.spec.*;
import java.util.Base64;
import java.util.Date;

public class PicodGatewayClient {

    static {
        Security.addProvider(new BouncyCastleProvider());
    }

    private ECPrivateKey gatewayPrivKey; // 网关私钥 (Pair0)
    private ECPublicKey picodSessionPubKey; // Picod 会话公钥 (Pub1)

    /**
     * 生成业务请求所需的加密数据和 Header
     */
    public EncryptedRequest encryptRequest(byte[] plaintext) throws Exception {
        // 1. 生成临时密钥对 (Ephemeral Key)
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("EC", "BC");
        kpg.initialize(new ECGenParameterSpec("secp256r1"));
        KeyPair ephKeyPair = kpg.generateKeyPair();
        ECPrivateKey ephPriv = (ECPrivateKey) ephKeyPair.getPrivate();
        ECPublicKey ephPub = (ECPublicKey) ephKeyPair.getPublic();

        // 2. ECDH 计算共享密钥 (ECDH with Picod's Pub1)
        KeyAgreement ka = KeyAgreement.getInstance("ECDH", "BC");
        ka.init(ephPriv);
        ka.doPhase(picodSessionPubKey, true);
        byte[] sharedSecret = ka.generateSecret();

        // 3. HKDF 派生对称密钥 (AES-256)
        // salt = null, info = "picod-business-wrap"
        byte[] sk = hkdfDerive(sharedSecret, "picod-business-wrap");

        // 4. AES-GCM 加密
        byte[] nonce = new byte[12];
        SecureRandom.getInstanceStrong().nextBytes(nonce);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding", "BC");
        GCMParameterSpec spec = new GCMParameterSpec(128, nonce);
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(sk, "AES"), spec);
        byte[] ciphertext = cipher.doFinal(plaintext);

        // 5. 组装结果
        EncryptedRequest req = new EncryptedRequest();
        req.body = ciphertext;
        req.ephPubHeader = Base64.getEncoder().encodeToString(ephPub.getEncoded());
        req.nonceHeader = Base64.getEncoder().encodeToString(nonce);
        return req;
    }

    /**
     * 处理 /init 响应，解密得到 picodSessionPubKey (Pub1)
     */
    public void handleInitResponse(String encPub1Base64, String ephPubBase64, String nonceBase64) throws Exception {
        byte[] encPub1 = Base64.getDecoder().decode(encPub1Base64);
        byte[] ephPubBytes = Base64.getDecoder().decode(ephPubBase64);
        byte[] nonce = Base64.getDecoder().decode(nonceBase64);

        // 解析 Picod 临时公钥
        KeyFactory kf = KeyFactory.getInstance("EC", "BC");
        ECPublicKey ephPub = (ECPublicKey) kf.generatePublic(new X509EncodedKeySpec(ephPubBytes));

        // ECDH 计算共享密钥 (ECDH with Gateway's Priv0)
        KeyAgreement ka = KeyAgreement.getInstance("ECDH", "BC");
        ka.init(gatewayPrivKey);
        ka.doPhase(ephPub, true);
        byte[] sharedSecret = ka.generateSecret();

        // HKDF 派生解密密钥 (wrapKey)
        // info = "picod-init-wrap"
        byte[] wrapKey = hkdfDerive(sharedSecret, "picod-init-wrap");

        // AES-GCM 解密得到 Pub1 (DER)
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding", "BC");
        GCMParameterSpec spec = new GCMParameterSpec(128, nonce);
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(wrapKey, "AES"), spec);
        byte[] pub1Der = cipher.doFinal(encPub1);

        // 解析并存储 Pub1
        this.picodSessionPubKey = (ECPublicKey) kf.generatePublic(new X509EncodedKeySpec(pub1Der));
    }

    /**
     * 简单的 HKDF-SHA256 实现 (info 模式)
     */
    private byte[] hkdfDerive(byte[] ikm, String info) throws Exception {
        // 这里可以使用第三方库如 Google Tink 或手动实现 HMAC-SHA256 的 HKDF
        // 为简化示例，演示逻辑：
        // 1. Extract: PRK = HMAC-SHA256(salt=0, IKM)
        // 2. Expand: OKM = HMAC-SHA256(PRK, info | 0x01)
        Mac hmac = Mac.getInstance("HmacSHA256", "BC");
        hmac.init(new SecretKeySpec(new byte[32], "HmacSHA256")); // salt=0
        byte[] prk = hmac.doFinal(ikm);

        hmac.init(new SecretKeySpec(prk, "HmacSHA256"));
        hmac.update(info.getBytes());
        hmac.update((byte) 0x01);
        byte[] okm = hmac.doFinal();
        return okm; // 32 字节
    }

    /**
     * 生成请求 JWT
     */
    public String generateJWT() throws Exception {
        JWSSigner signer = new ECDSASigner(gatewayPrivKey);
        JWTClaimsSet claimsSet = new JWTClaimsSet.Builder()
                .expirationTime(new Date(new Date().getTime() + 60 * 1000))
                .issueTime(new Date())
                .build();
        SignedJWT signedJWT = new SignedJWT(new JWSHeader(JWSAlgorithm.ES256), claimsSet);
        signedJWT.sign(signer);
        return signedJWT.serialize();
    }

    public static class EncryptedRequest {
        public byte[] body;
        public String ephPubHeader;
        public String nonceHeader;
    }
}
```

### 注意事项

1. **安全性**: `canonical_request_sha256` 建议在 JWT 中包含，以防止重放和篡改（本文示例为简化版未包含）。
2. **性能**: `picodSessionPubKey` 在 Picod 重启前有效，网关应缓存此密钥避免频繁调用 `/init`。
3. **错误处理**: 若 Picod 返回 403 "Encryption required"，说明需要先进行 `/init` 协商密钥。
