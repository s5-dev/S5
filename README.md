# S5 network

S5 is a decentralized network that puts you in control of your data and identity.

At its core, it is a content-addressed storage network like IPFS and also uses many of the formats and standards created in the IPFS project.

This repository contains a proof of concept implementation of a S5 node written in the Dart programming language. It is licensed under the MIT license.

An implementation in Rust is planned.

## How to run the experimental S5-Dart node

1. Make sure you are on a x86_64 Linux system
2. Download the latest release: https://github.com/redsolver/S5/releases
3. Make it executable
4. Copy the `default_config.toml` file from this repo to your local system
5. Start the node with `./s5-dart-... path/to/config.toml`

## Features

### Raw files

Raw files are the foundation of data stored on S5. They can have any size and are stored as the hash of themselves (blake3 by default).
No additional metadata like filename or content type is added, to make deduplication as efficient as possible.
Raw files are stored together with a part of their [BLAKE3 Bao](https://github.com/oconnor663/bao) hash tree, which makes it possible
to trustlessly stream any 256 KiB chunk of a file. The chunk size is configurable.

### Directory files/CIDs

Directory files are special metadata files that specify a directory structure with paths that can map to raw or metadata files.
They also support specifying default routes and 404 pages.
Can be used to deploy web apps on S5.

### Registry

The registry is a decentralized key-value store with realtime subscriptions.
Keys are public ed25519 keys.
The values have a revision number and are limited to 48 bytes of data.
All writes to an entry must be signed by the public key.

### Resolver CIDs

Resolver cids are just registry entries encoded as a CID.
They reference another CID and are for example used for dynamically updating websites.

## Comparison to IPFS

Compared to IPFS, S5 should generally be faster at downloading files. The main reason for this is that there's no maximum chunk size, which reduces the network lookup to only 2 requests for a file of almost any size.

For example a 10 GB file is by default stored as one raw block, and an additional file is generated that contains the metadata like filename, content type and hashes for individual parts of the file (1 MB by default) to make trustless streaming possible.

Another difference is that the S5 protocol never transfers file data between nodes, instead the delivery itself is outsourced to the HTTP protocol. This makes it significantly easier to leverage existing storage providers to deliver content efficiently instead of having to optimize implementations of a new protocol like bitswap.

Example: You want to download a file with the CID `z5W7Bf74oMS4JU4CvM6Vt3U7BfRY4rMi49MYrhtPVEe7CNLUG`. First, your node checks if it already has download urls for that CID's hash in your local cache. If not, it sends a query to all connected nodes. Another connected node that uses a S3 storage backend then checks if it has the hash stored there. If yes, it generates a pre-signed S3 download url and sends it back to the node that asked for it. This routing also works over multiple nodes. As soon as the original node receives a valid response, it tries to download/stream the file directly from the S3 endpoint but still verifies the integrity of every byte. This way it's possible to deliver files extremely efficiently leveraging existing infrastructure while still not having to trust any entity in the process.

Responses from nodes are signed by their public key and every node keeps a local score for every other node it knows of. When a node provides a valid HTTP URL that also matches the hash, its score is increased, if not it's decreased. The score is used to decide which URL to try first if multiple nodes provide the same file.

Because the p2p procotol only transfers lightweight requests with hashes and http urls instead of transferring the full file data, running a full S5 node is very lightweight and can happen in the browser too.

S5 currently supports three storage backends:
- S3 (Any cloud provider supporting the S3 protocol, see https://s3.wiki)
- Local filesystem (needs additional configuration to make a http port available on the internet)
- Arweave (expensive, permanent storage)
- Sia (experimental, https://sia.tech/)

S5 currently supports one protocol to establish a connection between nodes:
- TCP
- WebSocket (planned)
- QUIC (planned)

S5 also uses some more modern defaults compared to IPFS, for example the BLAKE3 hashing algorithm. This is of course not a design limitation of IPFS, just a nice side effect of S5 being built from scratch.
