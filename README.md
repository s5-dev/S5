# S5 network

S5 is a decentralized network that puts you in control of your data and identity.

At its core, it is a content-addressed storage network similar to IPFS and also uses many of the formats and standards created in the IPFS project.

This repository contains a proof of concept implementation of a S5 node written in the Dart programming language. It is licensed under the MIT license.

An implementation in Rust is planned.

## How to run the experimental S5-Dart node

`docker run -it --rm -p 5050:5050 -v /local/path/to/config:/config --name s5-node ghcr.io/s5-dev/node:0.9.2`

## Features

### Raw files / blobs

Raw files are the foundation of data stored on S5. They can have any size and are stored as the hash of themselves (blake3 by default). The CIDs also contain the filesize, you can read more about the format here: https://docs.s5.ninja/concepts/content-addressed-data.html
No additional metadata like filename or content type is added, to make deduplication as efficient as possible.
Raw files are stored together with a part of their [BLAKE3 Bao](https://github.com/oconnor663/bao) hash tree, which makes it possible
to trustlessly stream any 256 KiB chunk of a file. The chunk size is configurable.

### Web App Metadata CIDs

Web App metadata files are special metadata files that specify a directory structure with paths that can map to raw blobs or other metadata files.
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

Compared to IPFS, S5 should generally be faster at downloading files. The main reason for this is that there's no maximum chunk size, which reduces the DHT/p2p lookup to only 1 request for a file of any size.

Another difference is that the S5 protocol never transfers file data between nodes, instead the delivery itself is outsourced to the HTTP protocol. This makes it significantly easier to leverage existing storage providers or cdn networks to deliver content efficiently instead of having to optimize implementations of a new protocol like bitswap.

Example: You want to download a file with the CID `uJh9dvBupLgWG3p8CGJ1VR8PLnZvJQedolo8ktb027PrlTT5LvAY`. First, your node checks if it already has storage locations for that CID's hash in your local cache. If not, it sends a query to all connected nodes. Another connected node that uses a S3 storage backend then checks if it has the hash stored there. If yes, it generates a pre-signed S3 download url and sends it back to the node that asked for it. This routing also works over multiple nodes. As soon as the original node receives a valid response, it tries to download/stream the file directly from the S3 endpoint but still verifies the integrity of every byte. This way it's possible to deliver files extremely efficiently leveraging existing infrastructure while still not having to trust any entity in the process.

Responses from nodes are signed by their public key and every node keeps a local score for every other node it knows of. When a node provides a valid HTTP URL that also matches the hash, its score is increased, if not it's decreased. The score is used to decide which URL to try first if multiple nodes provide the same file.

Because the p2p procotol only transfers lightweight requests with hashes and http urls instead of transferring the full file data, running a full S5 node is very lightweight and can happen in the browser too.

S5 currently supports three storage backends:
- S3 (Any cloud provider supporting the S3 protocol, see https://s3.wiki)
- Local filesystem (needs additional configuration to make a http port available on the internet)
- Arweave (expensive, permanent storage)
- Sia (experimental, https://sia.tech/)
- Estuary.tech (experimental)

S5 currently supports one protocol to establish a connection between nodes:
- TCP
- nQUIC or QUIC-TLS (planned, waiting on what the iroh project will use)
- WebSocket (planned)

S5 also uses some more modern defaults compared to IPFS, for example the BLAKE3 hashing algorithm. This is of course not a design limitation of IPFS, just a nice side effect of S5 being built from scratch.
