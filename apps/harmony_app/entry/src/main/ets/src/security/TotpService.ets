export interface TotpConfig {
  periodSeconds: number;
  digits: number;
  skewWindows: number;
}

export class TotpService {
  private readonly config: TotpConfig;

  constructor(config: TotpConfig = defaultTotpConfig()) {
    this.config = {
      periodSeconds: config.periodSeconds,
      digits: config.digits,
      skewWindows: config.skewWindows,
    };
  }

  async generateCode(secret: string, timeMs: number = Date.now()): Promise<string> {
    const counter = this.toCounter(timeMs);
    return await this.generateByCounter(secret, counter);
  }

  async verifyCode(
    secret: string,
    code: string,
    timeMs: number = Date.now(),
  ): Promise<boolean> {
    const normalizedCode = code.trim();
    const pattern = new RegExp(`^[0-9]{${this.config.digits}}$`);
    if (!pattern.test(normalizedCode)) {
      return false;
    }

    const baseCounter = this.toCounter(timeMs);
    for (let offset = -this.config.skewWindows; offset <= this.config.skewWindows; offset++) {
      const generated = await this.generateByCounter(secret, baseCounter + offset);
      if (generated === normalizedCode) {
        return true;
      }
    }
    return false;
  }

  private toCounter(timeMs: number): number {
    return Math.floor(timeMs / 1000 / this.config.periodSeconds);
  }

  private async generateByCounter(secret: string, counter: number): Promise<string> {
    const counterBytes = counterToBytes(counter);
    const secretBytes = decodeSecret(secret);
    const digest = await hmacSha1(secretBytes, counterBytes);

    const offset = digest[digest.length - 1] & 0x0f;
    const binary =
      ((digest[offset] & 0x7f) << 24) |
      ((digest[offset + 1] & 0xff) << 16) |
      ((digest[offset + 2] & 0xff) << 8) |
      (digest[offset + 3] & 0xff);
    const code = binary % pow10(this.config.digits);
    return code.toString().padStart(this.config.digits, '0');
  }
}

function defaultTotpConfig(): TotpConfig {
  return {
    periodSeconds: 30,
    digits: 6,
    skewWindows: 1,
  };
}

async function hmacSha1(keyBytes: Uint8Array, dataBytes: Uint8Array): Promise<Uint8Array> {
  return hmacSha1Sync(keyBytes, dataBytes);
}

function hmacSha1Sync(keyBytes: Uint8Array, dataBytes: Uint8Array): Uint8Array {
  const blockSize = 64;
  let key = keyBytes;
  if (key.length > blockSize) {
    key = sha1(key);
  }

  const keyBlock = new Uint8Array(blockSize);
  keyBlock.set(key, 0);

  const iKeyPad = new Uint8Array(blockSize);
  const oKeyPad = new Uint8Array(blockSize);
  for (let i = 0; i < blockSize; i++) {
    iKeyPad[i] = keyBlock[i] ^ 0x36;
    oKeyPad[i] = keyBlock[i] ^ 0x5c;
  }

  const inner = sha1(concatBytes(iKeyPad, dataBytes));
  return sha1(concatBytes(oKeyPad, inner));
}

function sha1(input: Uint8Array): Uint8Array {
  const bitLength = input.length * 8;
  const paddingLength = (56 - ((input.length + 1) % 64) + 64) % 64;
  const totalLength = input.length + 1 + paddingLength + 8;
  const padded = new Uint8Array(totalLength);

  padded.set(input, 0);
  padded[input.length] = 0x80;

  let bitLengthValue = bitLength;
  for (let i = 0; i < 8; i++) {
    padded[totalLength - 1 - i] = bitLengthValue & 0xff;
    bitLengthValue = Math.floor(bitLengthValue / 256);
  }

  let h0 = 0x67452301;
  let h1 = 0xefcdab89;
  let h2 = 0x98badcfe;
  let h3 = 0x10325476;
  let h4 = 0xc3d2e1f0;

  const w = new Array<number>(80).fill(0);

  for (let offset = 0; offset < padded.length; offset += 64) {
    for (let t = 0; t < 16; t++) {
      const i = offset + t * 4;
      w[t] = (
        ((padded[i] & 0xff) << 24) |
        ((padded[i + 1] & 0xff) << 16) |
        ((padded[i + 2] & 0xff) << 8) |
        (padded[i + 3] & 0xff)
      ) >>> 0;
    }

    for (let t = 16; t < 80; t++) {
      w[t] = rotateLeft((w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]) >>> 0, 1);
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;

    for (let t = 0; t < 80; t++) {
      let f = 0;
      let k = 0;

      if (t < 20) {
        f = ((b & c) | ((~b) & d)) >>> 0;
        k = 0x5a827999;
      } else if (t < 40) {
        f = (b ^ c ^ d) >>> 0;
        k = 0x6ed9eba1;
      } else if (t < 60) {
        f = ((b & c) | (b & d) | (c & d)) >>> 0;
        k = 0x8f1bbcdc;
      } else {
        f = (b ^ c ^ d) >>> 0;
        k = 0xca62c1d6;
      }

      const temp = (rotateLeft(a, 5) + f + e + k + w[t]) >>> 0;
      e = d;
      d = c;
      c = rotateLeft(b, 30);
      b = a;
      a = temp;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
  }

  const out = new Uint8Array(20);
  writeUint32BE(out, 0, h0);
  writeUint32BE(out, 4, h1);
  writeUint32BE(out, 8, h2);
  writeUint32BE(out, 12, h3);
  writeUint32BE(out, 16, h4);
  return out;
}

function writeUint32BE(out: Uint8Array, offset: number, value: number): void {
  out[offset] = (value >>> 24) & 0xff;
  out[offset + 1] = (value >>> 16) & 0xff;
  out[offset + 2] = (value >>> 8) & 0xff;
  out[offset + 3] = value & 0xff;
}

function rotateLeft(value: number, bits: number): number {
  return ((value << bits) | (value >>> (32 - bits))) >>> 0;
}

function decodeSecret(secret: string): Uint8Array {
  const normalized = secret.trim().replace(/\s+/g, '').replace(/-/g, '').toUpperCase();
  if (normalized.length > 0 && /^[A-Z2-7]+=*$/.test(normalized)) {
    const decoded = base32ToBytes(normalized);
    if (decoded.length > 0) {
      return decoded;
    }
  }
  return encodeUtf8(secret.trim());
}

function base32ToBytes(input: string): Uint8Array {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const clean = input.replace(/=+$/g, '');
  const output: number[] = [];

  let buffer = 0;
  let bitsLeft = 0;
  for (let i = 0; i < clean.length; i++) {
    const value = alphabet.indexOf(clean[i]);
    if (value < 0) {
      return new Uint8Array(0);
    }
    buffer = (buffer << 5) | value;
    bitsLeft += 5;

    while (bitsLeft >= 8) {
      bitsLeft -= 8;
      output.push((buffer >> bitsLeft) & 0xff);
    }
  }

  return new Uint8Array(output);
}

function encodeUtf8(text: string): Uint8Array {
  const normalized = unescape(encodeURIComponent(text));
  const bytes = new Uint8Array(normalized.length);
  for (let i = 0; i < normalized.length; i++) {
    bytes[i] = normalized.charCodeAt(i);
  }
  return bytes;
}

function counterToBytes(counter: number): Uint8Array {
  let value = counter;
  const output = new Uint8Array(8);
  for (let i = 7; i >= 0; i--) {
    output[i] = value & 0xff;
    value = Math.floor(value / 256);
  }
  return output;
}

function concatBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  const output = new Uint8Array(left.length + right.length);
  output.set(left, 0);
  output.set(right, left.length);
  return output;
}

function pow10(digits: number): number {
  let value = 1;
  for (let i = 0; i < digits; i++) {
    value *= 10;
  }
  return value;
}
