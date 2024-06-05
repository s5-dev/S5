<h1 align="center">S5</h1>
<div align="center">
 <strong>
   Content-addressed storage, but fast.
 </strong>
</div>

<br />
<div align="center">
  <!-- docs.sfive.net docs -->
  <a href="https://docs.sfive.net/">
    <img src="https://img.shields.io/badge/docs-latest-blue.svg?style=flat-square"
      alt="docs.rs docs" />
  </a>
</div>
</br>

## Ethos

At its core, S5 is a content-addressed storage network similar to IPFS and also uses many of the formats and standards created in the IPFS project. It just builds upon them to be much more lightweight and scalable. Read the [docs](https://docs.sfive.net) for more info on the nitty gritty.

## Usage

`docker run -it --rm -p 5050:5050 -v /local/path/to/config:/config --name s5-node ghcr.io/s5-dev/node:latest`

A basic config file is generated for you, just make sure the path to the directory exists.

Or run it with docker compose
```docker
services:
  s5-node:
    image: ghcr.io/s5-dev/node:latest
    volumes:
      - ./config:/config
      - ./db:/db # optional
      - /tmp/s5:/cache # optional
    ports:
      - "5050:5050"
    restart: unless-stopped
```
To add file stores edit the config as described in the [docs](https://docs.sfive.net).

## Supported Storage Backends

- S3 (Any cloud provider supporting the S3 protocol, see https://s3.wiki)
- Local filesystem (needs additional configuration to make a http port available on the internet)
- Sia (experimental and cheap, https://sia.tech/)
- Arweave (expensive, permanent storage)
- Pixeldrain (affordable, https://pixeldrain.com/)
- Estuary.tech (experimental)

## Development

### Dependencies

- Dart (https://dart.dev/get-dart)
- Rust (https://www.rust-lang.org/tools/install)
- Build dependencies (Debian/Ubuntu: `sudo apt install build-essential pkg-config libssl-dev libclang-dev`)

### Build

- `git clone https://github.com/s5-dev/s5.git`
- `cd s5/rust`
- `cargo build --release`
- `cp target/release/librust.so ..`
- `cd ..`
- `dart compile exe bin/s5_server.dart`

Run the node with `./bin/s5_server.exe config.toml`

# License

This project is licensed under the MIT license ([LICENSE-MIT](LICENSE) or http://opensource.org/licenses/MIT)
