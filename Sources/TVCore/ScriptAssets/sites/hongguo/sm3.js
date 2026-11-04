// SM3 (GB/T 32905), pure JavaScript: Electron's bundled crypto may omit SM3.
import { Buffer } from './crypto.js';
export default function sm3(input) {
  const source = Buffer.isBuffer(input) ? input : Buffer.from(input);
  const data = Buffer.alloc(Math.ceil((source.length + 9) / 64) * 64);
  source.copy(data);
  data[source.length] = 0x80;
  data.writeBigUInt64BE(BigInt(source.length) * 8n, data.length - 8);
  const state = new Uint32Array([0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e]);
  const words = new Uint32Array(68);
  const rotate = (x, n) => ((x << (n & 31)) | (x >>> ((32 - n) & 31))) >>> 0;
  for (let offset = 0; offset < data.length; offset += 64) {
    for (let i = 0; i < 16; i++) words[i] = data.readUInt32BE(offset + i * 4);
    for (let i = 16; i < 68; i++) {
      const x = words[i - 16] ^ words[i - 9] ^ rotate(words[i - 3], 15);
      words[i] = x ^ rotate(x, 15) ^ rotate(x, 23) ^ rotate(words[i - 13], 7) ^ words[i - 6];
    }
    let [a, b, c, d, e, f, g, h] = state;
    for (let i = 0; i < 64; i++) {
      const a12 = rotate(a, 12);
      const s1 = rotate((a12 + e + rotate(i < 16 ? 0x79cc4519 : 0x7a879d8a, i)) >>> 0, 7);
      const s2 = s1 ^ a12;
      const ff = i < 16 ? a ^ b ^ c : (a & b) | (a & c) | (b & c);
      const gg = i < 16 ? e ^ f ^ g : (e & f) | (~e & g);
      const t1 = (ff + d + s2 + (words[i] ^ words[i + 4])) >>> 0;
      const t2 = (gg + h + s1 + words[i]) >>> 0;
      d = c; c = rotate(b, 9); b = a; a = t1;
      h = g; g = rotate(f, 19); f = e;
      e = (t2 ^ rotate(t2, 9) ^ rotate(t2, 17)) >>> 0;
    }
    const next = [a, b, c, d, e, f, g, h];
    for (let i = 0; i < 8; i++) state[i] ^= next[i];
  }
  const digest = Buffer.alloc(32);
  for (let i = 0; i < 8; i++) digest.writeUInt32BE(state[i], i * 4);
  return digest;
};
