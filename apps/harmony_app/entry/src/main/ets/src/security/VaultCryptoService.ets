import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { EncryptedPayloadRecord } from '../model/VaultTypes';

const AES_GCM_TAG_BYTES: number = 16;
const AES_GCM_NONCE_BYTES: number = 12;
const DERIVED_KEY_BYTES: number = 32;

export class VaultCryptoService {
  static readonly DEFAULT_ITERATIONS: number = 600000;

  async deriveVerifier(
    password: string,
    saltBase64: string,
    iterations: number,
  ): Promise<string> {
    const keyBytes = await this.deriveKeyBytes(password, saltBase64, iterations);
    return bytesToBase64(keyBytes);
  }

  async deriveKeyToken(
    password: string,
    saltBase64: string,
    iterations: number,
  ): Promise<string> {
    const keyBytes = await this.deriveKeyBytes(password, saltBase64, iterations);
    return bytesToBase64(keyBytes);
  }

  async encryptString(
    plaintext: string,
    keyToken: string,
  ): Promise<EncryptedPayloadRecord> {
    const keyBytes = base64ToBytes(keyToken);
    return await encryptWithKit(plaintext, keyBytes);
  }

  async decryptString(
    payload: EncryptedPayloadRecord,
    keyToken: string,
  ): Promise<string> {
    const keyBytes = base64ToBytes(keyToken);
    return await decryptWithKit(payload, keyBytes);
  }

  generateSaltBase64(bytes: number = 16): string {
    return bytesToBase64(randomBytes(bytes));
  }

  private async deriveKeyBytes(
    password: string,
    saltBase64: string,
    iterations: number,
  ): Promise<Uint8Array> {
    const salt = base64ToBytes(saltBase64);
    return await deriveKeyBytesWithKit(password, salt, iterations);
  }
}

async function deriveKeyBytesWithKit(
  password: string,
  salt: Uint8Array,
  iterations: number,
): Promise<Uint8Array> {
  try {
    const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    const pbkdf2Spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password,
      salt,
      iterations,
      keySize: DERIVED_KEY_BYTES,
    };
    const keyBlob = await kdf.generateSecret(pbkdf2Spec);
    const keyBytes = dataBlobToBytes(keyBlob);
    if (keyBytes.length !== DERIVED_KEY_BYTES) {
      throw new Error(`Unexpected PBKDF2 key length: ${keyBytes.length}`);
    }
    return keyBytes;
  } catch (error) {
    throw new Error(`PBKDF2 derive failed: ${error}`);
  }
}

async function encryptWithKit(
  plaintext: string,
  keyBytes: Uint8Array,
): Promise<EncryptedPayloadRecord> {
  try {
    const nonce = randomBytes(AES_GCM_NONCE_BYTES);
    const key = await createAesSymKey(keyBytes);
    const cipher = cryptoFramework.createCipher(`${resolveAesAlgName(keyBytes)}|GCM|PKCS7`);
    const params = buildGcmParams(nonce, new Uint8Array(AES_GCM_TAG_BYTES));

    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);

    const plainBytes = encodeUtf8(plaintext);
    let ciphertext = new Uint8Array(0);
    if (plainBytes.length > 0) {
      const updateOut = await cipher.update({ data: plainBytes });
      ciphertext = dataBlobToBytes(updateOut);
    }

    const finalOut = await cipher.doFinal(null);
    const tag = requireFixedLength(dataBlobToBytes(finalOut), AES_GCM_TAG_BYTES);

    return {
      ciphertext: bytesToBase64(ciphertext),
      nonce: bytesToBase64(nonce),
      mac: bytesToBase64(tag),
      version: 1,
    };
  } catch (error) {
    throw new Error(`Encrypt with kit failed: ${error}`);
  }
}

async function decryptWithKit(
  payload: EncryptedPayloadRecord,
  keyBytes: Uint8Array,
): Promise<string> {
  try {
    const ciphertext = base64ToBytes(payload.ciphertext);
    const nonce = base64ToBytes(payload.nonce);
    const mac = requireFixedLength(base64ToBytes(payload.mac), AES_GCM_TAG_BYTES);

    const key = await createAesSymKey(keyBytes);
    const cipher = cryptoFramework.createCipher(`${resolveAesAlgName(keyBytes)}|GCM|PKCS7`);
    const params = buildGcmParams(nonce, mac);

    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);

    let plaintext = new Uint8Array(0);
    if (ciphertext.length > 0) {
      const updateOut = await cipher.update({ data: ciphertext });
      plaintext = dataBlobToBytes(updateOut);
    }

    const finalOut = await cipher.doFinal(null);
    const finalBytes = dataBlobToBytes(finalOut);
    if (finalBytes.length > 0) {
      plaintext = concatBytes(plaintext, finalBytes);
    }

    return decodeUtf8(plaintext);
  } catch (error) {
    throw new Error(`Decrypt with kit failed: ${error}`);
  }
}

async function createAesSymKey(
  keyBytes: Uint8Array,
): Promise<cryptoFramework.SymKey> {
  try {
    const symKeyGenerator = cryptoFramework.createSymKeyGenerator(resolveAesAlgName(keyBytes));
    return await symKeyGenerator.convertKey({ data: keyBytes });
  } catch (error) {
    throw new Error(`Create AES key failed: ${error}`);
  }
}

function resolveAesAlgName(keyBytes: Uint8Array): string {
  if (keyBytes.length === 16) {
    return 'AES128';
  }
  if (keyBytes.length === 24) {
    return 'AES192';
  }
  return 'AES256';
}

function buildGcmParams(
  iv: Uint8Array,
  authTag: Uint8Array,
): cryptoFramework.GcmParamsSpec {
  return {
    algName: 'GcmParamsSpec',
    iv: { data: iv },
    aad: { data: new Uint8Array(0) },
    authTag: { data: authTag },
  };
}

function dataBlobToBytes(
  blob: cryptoFramework.DataBlob | null | undefined,
): Uint8Array {
  if (blob === null || blob === undefined) {
    return new Uint8Array(0);
  }
  return blob.data;
}

function requireFixedLength(input: Uint8Array, length: number): Uint8Array {
  if (input.length === length) {
    return input;
  }
  throw new Error(`Unexpected data length: ${input.length}, expected ${length}`);
}

function randomBytes(length: number): Uint8Array {
  try {
    const random = cryptoFramework.createRandom();
    const randomBlob = random.generateRandomSync(length);
    const bytes = dataBlobToBytes(randomBlob);
    if (bytes.length === length) {
      return bytes;
    }
    throw new Error(`Unexpected random length: ${bytes.length}`);
  } catch (error) {
    throw new Error(`CryptoArchitectureKit random failed: ${error}`);
  }
}

function encodeUtf8(text: string): Uint8Array {
  const normalized = unescape(encodeURIComponent(text));
  const bytes = new Uint8Array(normalized.length);
  for (let i = 0; i < normalized.length; i++) {
    bytes[i] = normalized.charCodeAt(i);
  }
  return bytes;
}

function decodeUtf8(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return decodeURIComponent(escape(binary));
}

function bytesToBase64(bytes: Uint8Array): string {
  try {
    const helper = new util.Base64Helper();
    return helper.encodeToStringSync(bytes);
  } catch (error) {
    console.error(`Base64 encode failed, fallback to hex: ${error}`);
    return `hex:${bytesToHex(bytes)}`;
  }
}

function base64ToBytes(encoded: string): Uint8Array {
  if (encoded.startsWith('hex:')) {
    return hexToBytes(encoded.slice(4));
  }
  try {
    const helper = new util.Base64Helper();
    return helper.decodeSync(encoded);
  } catch (error) {
    console.error(`Base64 decode failed, fallback to hex parse: ${error}`);
    return hexToBytes(encoded);
  }
}

function bytesToHex(bytes: Uint8Array): string {
  let output = '';
  for (let i = 0; i < bytes.length; i++) {
    output += bytes[i].toString(16).padStart(2, '0');
  }
  return output;
}

function hexToBytes(input: string): Uint8Array {
  const normalized = input.trim();
  const size = Math.floor(normalized.length / 2);
  const output = new Uint8Array(size);
  for (let i = 0; i < size; i++) {
    output[i] = parseInt(normalized.substring(i * 2, i * 2 + 2), 16);
  }
  return output;
}

function concatBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  const output = new Uint8Array(left.length + right.length);
  output.set(left, 0);
  output.set(right, left.length);
  return output;
}
