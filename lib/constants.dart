import 'dart:io';

const chunkSize = 1000 * 1000;

const cidTypeRaw = 0x26;
const cidTypeMetadata = 0x2d;

const registryS5MagicByte = 0x5a;

const metadataMagicByte = 0x5f;

// const mhashSha256 = [0x12, 0x20];

const mhashBlake3 = [0x1e, 0x20];

final jsonContentType = ContentType('application', 'json');
