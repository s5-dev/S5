<h1 align="center">S5</h1>
<div align="center">
 <strong>
   Content addressed storage, but fast.
 </strong>
</div>

<br />
<div align="center">
  <!-- docs.sfive.neet docs -->
  <a href="https://docs.sfive.net/">
    <img src="https://img.shields.io/badge/docs-latest-blue.svg?style=flat-square"
      alt="docs.rs docs" />
  </a>
</div>
</br>

## Ethos
---

At its core, S5 is a content-addressed storage network similar to IPFS and also uses many of the formats and standards created in the IPFS project. It just builds upon them to allow for a much more lightweight and scalable. Read the [docs](https://docs.sfive.net) for more info on the nitty gritty.

## Usage
---

`docker run -it --rm -p 5050:5050 -v /local/path/to/config:/config --name s5-node ghcr.io/s5-dev/node:0.9.2`

Or run it with docker compose
```docker
version: '3'
services:
  s5-node:
    image: ghcr.io/s5-dev/node:0.9.2
    volumes:
      - /local/path/to/config:/config
    ports:
      - "5050:5050"
    restart: unless-stopped
```
Keep in mind that the config will be generated if it does not exist, just make sure to set a pth for it to get written to. To add file stores edit the config as perscribed in the [docs](https://docs.sfive.net).

## Supported Backends
---
- S3 (Any cloud provider supporting the S3 protocol, see https://s3.wiki)
- Local filesystem (needs additional configuration to make a http port available on the internet)
- Arweave (expensive, permanent storage)
- Sia (experimental, https://sia.tech/)
- Pixeldrain (cheap, high bandwidth https://pixeldrain.com/)
- Estuary.tech (experimental)

# License

This project is licensed under the MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
