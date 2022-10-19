const nodeVersion = '0.3.0';

const defaultChunkSize = 1024 * 1024;

// These bytes are carefully selected to make the base58 and base32 representations of different CID types
// easy to distinguish and not collide with anything on https://github.com/multiformats/multicodec
const cidTypeRaw = 0x26;
const cidTypeMetadataFile = 0x2d;
const cidTypeMetadataDirectory = 0x59;
const cidTypeResolver = 0x25;

const registryS5MagicByte = 0x5a;
const metadataMagicByte = 0x5f;

// types for metadata files
const metadataTypeFile = 0x01;
const metadataTypeChunkedFile = 0x02;
const metadataTypeDirectory = 0x03;

const registryMaxDataSize = 48;

// const mhashSha256 = [0x12, 0x20];
const mhashBlake3 = [0x1e, 0x20];

const mkeyEd25519 = 0xed;

//  Use this for protocol updates
const protocolMethodHandshakeOpen = 1;
const protocolMethodHandshakeDone = 2;

const protocolMethodSignedMessage = 10;

const protocolMethodHashQueryResponse = 5;
const protocolMethodHashQuery = 4;

const protocolMethodAnnouncePeers = 7;

const protocolMethodRegistryUpdate = 12;
const protocolMethodRegistryQuery = 13;
