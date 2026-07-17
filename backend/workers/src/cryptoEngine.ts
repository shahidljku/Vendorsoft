/**
 * Cryptographic helper functions for ID generation and base64url HMAC-SHA256 lease signing.
 * See SECURITY_RULES.md Section 1.1 & API_SPECIFICATION.md Section 2.3.
 */

/**
 * Generates a deterministic 10-character alphanumeric ID (`89A2B3C4D5`).
 */
export function generateShortId(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let result = '';
  const randomBytes = new Uint8Array(10);
  crypto.getRandomValues(randomBytes);
  for (let i = 0; i < 10; i++) {
    result += chars[randomBytes[i] % chars.length];
  }
  return result;
}

/**
 * Encodes and digitally signs the lease payload using Web Crypto HMAC-SHA256 (`crypto.subtle`).
 * Ensures client APK modification cannot spoof active status locally (`SECURITY_RULES.md Section 1.1`).
 * The signing secret (`LEASE_SIGNING_SECRET`) resides exclusively inside Cloudflare Workers V8 isolated memory.
 */
export async function generateSignedLeaseToken(payload: Record<string, any>, privateKeyPem: string): Promise<string> {
  const jsonStr = JSON.stringify(payload);
  const base64Payload = btoa(jsonStr).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  
  const encoder = new TextEncoder();
  const dataBuffer = encoder.encode(base64Payload);

  try {
    // Strip PEM headers to extract base64 PKCS#8 payload
    const base64Pkcs8 = privateKeyPem
      .replace(/-----BEGIN (?:RSA )?PRIVATE KEY-----/g, '')
      .replace(/-----END (?:RSA )?PRIVATE KEY-----/g, '')
      .replace(/\s+/g, '');
      
    const binaryPkcs8 = atob(base64Pkcs8);
    const pkcs8Bytes = new Uint8Array(binaryPkcs8.length);
    for (let i = 0; i < binaryPkcs8.length; i++) {
      pkcs8Bytes[i] = binaryPkcs8.charCodeAt(i);
    }

    const cryptoKey = await crypto.subtle.importKey(
      'pkcs8',
      pkcs8Bytes,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['sign']
    );

    const signatureBuffer = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', cryptoKey, dataBuffer);
    const signatureBytes = new Uint8Array(signatureBuffer);
    let signatureBinary = '';
    for (let i = 0; i < signatureBytes.byteLength; i++) {
      signatureBinary += String.fromCharCode(signatureBytes[i]);
    }
    const base64Signature = btoa(signatureBinary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    return `${base64Payload}.${base64Signature}`;
  } catch (err) {
    console.error('Failed to sign lease token with RSA Key. Ensure RSA_PRIVATE_KEY is a valid PKCS#8 PEM string.', err);
    throw new Error('INTERNAL_CRYPTO_ERROR');
  }
}

/**
 * Computes SHA-256 hex string using Web Crypto API (`crypto.subtle`).
 */
export async function computeSha256Hash(input: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(input);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Verifies an RSASSA-PKCS1-v1_5 SHA-256 signature against a PEM/SPKI Public Key using Web Crypto API.
 */
export async function verifyRsaSha256Signature(payloadStr: string, signatureBase64: string, publicKeyPem: string): Promise<boolean> {
  try {
    // 1. Strip PEM header/footer and decode base64 SPKI
    const base64Spki = publicKeyPem
      .replace(/-----BEGIN PUBLIC KEY-----/g, '')
      .replace(/-----END PUBLIC KEY-----/g, '')
      .replace(/\s+/g, '');
    
    const binarySpki = atob(base64Spki);
    const spkiBytes = new Uint8Array(binarySpki.length);
    for (let i = 0; i < binarySpki.length; i++) {
      spkiBytes[i] = binarySpki.charCodeAt(i);
    }

    const cryptoKey = await crypto.subtle.importKey(
      'spki',
      spkiBytes,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify']
    );

    // 2. Decode base64 signature
    const binarySignature = atob(signatureBase64);
    const signatureBytes = new Uint8Array(binarySignature.length);
    for (let i = 0; i < binarySignature.length; i++) {
      signatureBytes[i] = binarySignature.charCodeAt(i);
    }

    // 3. Verify signature
    const payloadBytes = new TextEncoder().encode(payloadStr);
    return await crypto.subtle.verify('RSASSA-PKCS1-v1_5', cryptoKey, signatureBytes, payloadBytes);
  } catch (err) {
    console.warn('Web Crypto RSA verification failed:', err);
    return false;
  }
}
