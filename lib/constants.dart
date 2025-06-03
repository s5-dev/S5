// ! S5 node version
const nodeVersion = '1.0.0-pre.1';

// ! default chunk size for hashes
const defaultChunkSize = 256 * 1024;
const defaultChunkSizeAsPowerOf2 = 18;

// const magicByteStoredFile = 0x8d;

@Deprecated('use directory identifiers with ed25519 key type instead')
const cidTypeResolver = 0x25;