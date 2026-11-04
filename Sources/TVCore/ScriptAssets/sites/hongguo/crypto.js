// The small Node binary/crypto surface used by the Hongguo signing module, on QuickJS.
// Bulk media decryption stays in Swift; no media buffers cross this bridge.
export class Buffer extends globalThis.Buffer {
    static from(value, encoding) { const bytes = globalThis.Buffer.from(value, encoding); return new Buffer(bytes); }
    static alloc(size, fill = 0) { return new Buffer(size).fill(fill); }
    static concat(list) { const out = Buffer.alloc(list.reduce((n, b) => n + b.length, 0)); let at = 0; for (const b of list) { out.set(b, at); at += b.length; } return out; }
    static isBuffer(value) { return value instanceof Uint8Array; }
    copy(target, offset = 0, start = 0, end = this.length) { const bytes = this.subarray(start, Math.min(end, start + target.length - offset)); target.set(bytes, offset); return bytes.length; }
    view() { return new DataView(this.buffer, this.byteOffset, this.byteLength); }
    readUInt32BE(offset = 0) { return this.view().getUint32(offset, false); }
    readUInt32LE(offset = 0) { return this.view().getUint32(offset, true); }
    writeUInt32BE(value, offset = 0) { this.view().setUint32(offset, value, false); return offset + 4; }
    writeUInt32LE(value, offset = 0) { this.view().setUint32(offset, value, true); return offset + 4; }
    writeFloatLE(value, offset = 0) { this.view().setFloat32(offset, value, true); return offset + 4; }
    readBigUInt64LE(offset = 0) { return this.view().getBigUint64(offset, true); }
    writeBigUInt64LE(value, offset = 0) { this.view().setBigUint64(offset, value, true); return offset + 8; }
    writeBigUInt64BE(value, offset = 0) { this.view().setBigUint64(offset, value, false); return offset + 8; }
}

function aesCBC(encrypt, algorithm, key, iv) {
    if (algorithm !== 'aes-128-cbc') throw new Error('Unsupported Hongguo cipher');
    let padding = true;
    const parts = [];
    return {
        setAutoPadding(value) { padding = value; },
        update(data) { parts.push(Buffer.from(data)); return Buffer.alloc(0); },
        final() { return Buffer.from(nativeCrypto({ op: 'aes', encrypt, mode: 'CBC', padding,
            key: key.toString('base64'), iv: iv.toString('base64'), data: Buffer.concat(parts).toString('base64') }).data, 'base64'); },
    };
}

export const crypto = {
    randomBytes(count) { return Buffer.from(nativeCrypto({ op: 'random', count }).data, 'base64'); },
    randomUUID() {
        const bytes = crypto.randomBytes(16);
        bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80;
        const hex = bytes.toString('hex');
        return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    },
    createHash(alg) {
        const parts = [];
        return {
            update(data) { parts.push(Buffer.from(data)); return this; },
            digest(encoding) {
                const bytes = Buffer.from(nativeCrypto({ op: 'hash', alg, data: Buffer.concat(parts).toString('base64') }).hex, 'hex');
                return encoding ? bytes.toString(encoding) : bytes;
            },
        };
    },
    createCipheriv(algorithm, key, iv) { return aesCBC(true, algorithm, key, iv); },
    createDecipheriv(algorithm, key, iv) { return aesCBC(false, algorithm, key, iv); },
};
