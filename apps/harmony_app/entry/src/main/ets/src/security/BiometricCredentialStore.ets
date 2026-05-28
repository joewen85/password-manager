import { Context } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { huks } from '@kit.UniversalKeystoreKit';
import { userAuth } from '@kit.UserAuthenticationKit';

interface StoredBiometricCredential {
  version: number;
  enabled: boolean;
  ciphertext: string;
  nonce: string;
  authTag: string;
}

interface EncryptedPassword {
  ciphertext: Uint8Array;
  nonce: Uint8Array;
  authTag: Uint8Array;
}

const AES_GCM_NONCE_BYTES: number = 12;
const AES_GCM_TAG_BYTES: number = 16;

export class BiometricCredentialStore {
  private static readonly STORE_NAME: string = 'password_manager_biometric_unlock';
  private static readonly CREDENTIAL_KEY: string = 'master_password_credential';
  static readonly KEY_ALIAS: string = 'password_manager_harmony_biometric_unlock';

  private readonly pref: preferences.Preferences;

  private constructor(pref: preferences.Preferences) {
    this.pref = pref;
  }

  static async create(context: Context): Promise<BiometricCredentialStore> {
    try {
      const pref = await preferences.getPreferences(context, {
        name: BiometricCredentialStore.STORE_NAME
      });
      return new BiometricCredentialStore(pref);
    } catch (error) {
      throw new Error(`打开生物识别凭据存储失败: ${error}`);
    }
  }

  async canAuthenticate(): Promise<boolean> {
    return canUseBiometric(userAuth.UserAuthType.FACE) || canUseBiometric(userAuth.UserAuthType.FINGERPRINT);
  }

  async hasSavedCredential(): Promise<boolean> {
    const credential = await this.readStoredCredential();
    return credential.enabled && credential.ciphertext.length > 0 && credential.nonce.length > 0 && credential.authTag.length > 0;
  }

  async savePassword(password: string): Promise<void> {
    await this.ensureKey();
    const encrypted = await this.encryptPassword(password);
    const credential: StoredBiometricCredential = {
      version: 2,
      enabled: true,
      ciphertext: bytesToBase64(encrypted.ciphertext),
      nonce: bytesToBase64(encrypted.nonce),
      authTag: bytesToBase64(encrypted.authTag)
    };
    await this.writeStoredCredential(credential);
  }

  async readPassword(): Promise<string> {
    const credential = await this.readStoredCredential();
    if (!credential.enabled || credential.ciphertext.length === 0 || credential.nonce.length === 0 || credential.authTag.length === 0) {
      throw new Error('尚未启用生物识别解锁');
    }

    try {
      const plaintext = await this.decryptPassword({
        ciphertext: base64ToBytes(credential.ciphertext),
        nonce: base64ToBytes(credential.nonce),
        authTag: base64ToBytes(credential.authTag)
      });
      return decodeUtf8(plaintext);
    } catch (error) {
      await this.clear();
      throw new Error(`生物识别凭据已失效，请使用主密码重新启用: ${error}`);
    }
  }

  async clear(): Promise<void> {
    await this.writeStoredCredential(emptyCredential());
    try {
      if (await huks.isKeyItemExist(BiometricCredentialStore.KEY_ALIAS, {})) {
        await huks.deleteKeyItem(BiometricCredentialStore.KEY_ALIAS, {});
      }
    } catch (error) {
      console.error(`Delete biometric HUKS key failed: ${error}`);
    }
  }

  private async ensureKey(): Promise<void> {
    try {
      if (await huks.isKeyItemExist(BiometricCredentialStore.KEY_ALIAS, {})) {
        return;
      }
    } catch (error) {
      console.error(`Check biometric HUKS key failed, recreating: ${error}`);
    }

    try {
      await huks.generateKeyItem(BiometricCredentialStore.KEY_ALIAS, buildKeyOptions());
    } catch (error) {
      const keyAlreadyExistsCode = '12000017';
      if (`${error}`.includes(keyAlreadyExistsCode)) {
        return;
      }
      throw new Error(`创建硬件保护生物识别密钥失败: ${error}`);
    }
  }

  private async encryptPassword(password: string): Promise<EncryptedPassword> {
    const nonce = randomBytes(AES_GCM_NONCE_BYTES);
    const options = buildCipherOptions(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce, null, encodeUtf8(password));
    const session = await initBiometricHuksSession(options);
    const token = await this.authenticate(session.challenge ?? randomBytes(32), '启用生物识别解锁');

    try {
      const result = await huks.finishSession(session.handle, options, token);
      const outData = result.outData ?? new Uint8Array(0);
      return splitCiphertextAndTag(outData, findAuthTag(result.properties), nonce);
    } catch (error) {
      await abortHuksSession(session.handle, options);
      throw error as Error;
    }
  }

  private async decryptPassword(encrypted: EncryptedPassword): Promise<Uint8Array> {
    const options = buildCipherOptions(
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
      encrypted.nonce,
      encrypted.authTag,
      encrypted.ciphertext
    );
    const session = await initBiometricHuksSession(options);
    const token = await this.authenticate(session.challenge ?? randomBytes(32), '解锁密码管理器');

    try {
      const result = await huks.finishSession(session.handle, options, token);
      return result.outData ?? new Uint8Array(0);
    } catch (error) {
      await abortHuksSession(session.handle, options);
      throw error as Error;
    }
  }

  private async authenticate(challenge: Uint8Array, title: string): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve, reject) => {
      try {
        const instance = userAuth.getUserAuthInstance(
          {
            challenge,
            authType: [
              userAuth.UserAuthType.FACE,
              userAuth.UserAuthType.FINGERPRINT
            ],
            authTrustLevel: userAuth.AuthTrustLevel.ATL3
          },
          { title }
        );
        const callback: userAuth.IAuthCallback = {
          onResult: (result: userAuth.UserAuthResult) => {
            instance.off('result', callback);
            if (result.result === userAuth.UserAuthResultCode.SUCCESS && result.token !== undefined) {
              resolve(result.token);
            } else {
              reject(new Error(`生物识别认证失败: ${result.result}`));
            }
          }
        };
        instance.on('result', callback);
        instance.start();
      } catch (error) {
        reject(error as Error);
      }
    });
  }

  private async readStoredCredential(): Promise<StoredBiometricCredential> {
    let raw = '';
    try {
      raw = await this.pref.get(
        BiometricCredentialStore.CREDENTIAL_KEY,
        ''
      ) as string;
    } catch (error) {
      console.error(`Read biometric credential preference failed: ${error}`);
      return emptyCredential();
    }

    if (raw.trim().length === 0) {
      return emptyCredential();
    }
    try {
      const parsed = JSON.parse(raw) as StoredBiometricCredential;
      return {
        version: parsed.version ?? 1,
        enabled: parsed.enabled === true,
        ciphertext: parsed.ciphertext ?? '',
        nonce: parsed.nonce ?? '',
        authTag: parsed.authTag ?? ''
      };
    } catch (error) {
      console.error(`Parse biometric credential failed: ${error}`);
      return emptyCredential();
    }
  }

  private async writeStoredCredential(credential: StoredBiometricCredential): Promise<void> {
    try {
      await this.pref.put(
        BiometricCredentialStore.CREDENTIAL_KEY,
        JSON.stringify(credential)
      );
      await this.pref.flush();
    } catch (error) {
      throw new Error(`写入生物识别凭据失败: ${error}`);
    }
  }
}

function canUseBiometric(authType: userAuth.UserAuthType): boolean {
  try {
    userAuth.getAvailableStatus(authType, userAuth.AuthTrustLevel.ATL3);
    return true;
  } catch (error) {
    console.error(`Biometric auth unavailable: ${error}`);
    return false;
  }
}

function buildKeyOptions(): huks.HuksOptions {
  return {
    properties: [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
      },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      {
        tag: huks.HuksTag.HUKS_TAG_USER_AUTH_TYPE,
        value: huks.HuksUserAuthType.HUKS_USER_AUTH_TYPE_FACE | huks.HuksUserAuthType.HUKS_USER_AUTH_TYPE_FINGERPRINT
      },
      { tag: huks.HuksTag.HUKS_TAG_KEY_AUTH_ACCESS_TYPE, value: huks.HuksAuthAccessType.HUKS_AUTH_ACCESS_INVALID_NEW_BIO_ENROLL },
      { tag: huks.HuksTag.HUKS_TAG_AUTH_TIMEOUT, value: 0 },
      { tag: huks.HuksTag.HUKS_TAG_KEY_AUTH_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_CHALLENGE_TYPE, value: huks.HuksChallengeType.HUKS_CHALLENGE_TYPE_CUSTOM },
      { tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL, value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_ECE },
      { tag: huks.HuksTag.HUKS_TAG_USER_AUTH_MODE, value: huks.HuksUserAuthMode.HUKS_USER_AUTH_MODE_LOCAL }
    ]
  };
}

function buildCipherOptions(
  purpose: huks.HuksKeyPurpose,
  nonce: Uint8Array,
  authTag: Uint8Array | null,
  input: Uint8Array
): huks.HuksOptions {
  const properties: Array<huks.HuksParam> = [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
    { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
    { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
    { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
    { tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: new Uint8Array(0) }
  ];
  if (authTag !== null) {
    properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: authTag });
  }
  return {
    properties,
    inData: input
  };
}

async function abortHuksSession(handle: number, options: huks.HuksOptions): Promise<void> {
  try {
    await huks.abortSession(handle, options);
  } catch (error) {
    console.error(`Abort biometric HUKS session failed: ${error}`);
  }
}

async function initBiometricHuksSession(options: huks.HuksOptions): Promise<huks.HuksSessionHandle> {
  try {
    return await huks.initSession(BiometricCredentialStore.KEY_ALIAS, options);
  } catch (error) {
    throw new Error(`初始化生物识别 HUKS 会话失败: ${error}`);
  }
}

function splitCiphertextAndTag(outData: Uint8Array, explicitTag: Uint8Array | null, nonce: Uint8Array): EncryptedPassword {
  if (explicitTag !== null) {
    return {
      ciphertext: outData,
      nonce,
      authTag: explicitTag
    };
  }
  if (outData.length <= AES_GCM_TAG_BYTES) {
    throw new Error('HUKS 未返回有效 AES-GCM 密文');
  }
  return {
    ciphertext: outData.slice(0, outData.length - AES_GCM_TAG_BYTES),
    nonce,
    authTag: outData.slice(outData.length - AES_GCM_TAG_BYTES)
  };
}

function findAuthTag(properties: Array<huks.HuksParam> | undefined): Uint8Array | null {
  if (properties === undefined) {
    return null;
  }
  for (let index = 0; index < properties.length; index++) {
    const property = properties[index];
    if (property.tag === huks.HuksTag.HUKS_TAG_AE_TAG && property.value instanceof Uint8Array) {
      return property.value;
    }
  }
  return null;
}

function emptyCredential(): StoredBiometricCredential {
  return {
    version: 2,
    enabled: false,
    ciphertext: '',
    nonce: '',
    authTag: ''
  };
}

function randomBytes(length: number): Uint8Array {
  try {
    const random = cryptoFramework.createRandom();
    const blob = random.generateRandomSync(length);
    if (blob.data.length === length) {
      return blob.data;
    }
    throw new Error(`Unexpected random length: ${blob.data.length}`);
  } catch (error) {
    throw new Error(`生成安全随机数失败: ${error}`);
  }
}

function encodeUtf8(text: string): Uint8Array {
  const normalized = unescape(encodeURIComponent(text));
  const bytes = new Uint8Array(normalized.length);
  for (let index = 0; index < normalized.length; index++) {
    bytes[index] = normalized.charCodeAt(index);
  }
  return bytes;
}

function decodeUtf8(bytes: Uint8Array): string {
  let binary = '';
  for (let index = 0; index < bytes.length; index++) {
    binary += String.fromCharCode(bytes[index]);
  }
  return decodeURIComponent(escape(binary));
}

function bytesToBase64(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

function base64ToBytes(encoded: string): Uint8Array {
  const helper = new util.Base64Helper();
  return helper.decodeSync(encoded);
}
