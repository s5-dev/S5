## 0.10.0

- Added new admin API for account management
- `auth_token` can now be passed as query parameter for all endpoints
- Added `deleteCID` method
- Improved tus upload auth
- accounts: New "invite code" feature for registration
- accounts: Moved API endpoints (removed subdomain requirement)
- accounts: Improved pinning API

## 0.9.2

- Add support for the **Sia storage network** using **renterd**
- Add new "storage location" concept that replaces the old download URIs. Makes it possible to keep bao outboard metadata for verified streaming fully separated and adds support for "bridged metadata" (generating S5-compatible metadata for existing social networks and websites) and "archive locations" (tell the network that you are storing a file, but don't want to provide downloads for it)
- Added support for using multiple stores at once, including custom upload rules (for example upload large files to Sia and small files to a S3 bucket)
- Performance improvements to the S3 store, the entire list of available hashes is now kept in memory instead of doing a `HEAD` request to the S3 bucket for every single file
- Make metadata formats compatible with standard msgpack unpackers (for example in Python)
- Add new "domain" value for the HTTP API configuration, configure this to enable loading of web apps on subdomains and/or dnslinks
- Add some new endpoints to the HTTP API, for example to make adaptive DASH streaming possible without any special client software
- Add new configuration option configure allowed scopes for accounts system
- Improve efficiency of storage location cache
- Improve registry signatures, serialization is now identical for storage and wire format
- Add bridge metadata support to CIDs
- Switch to KeyValueDB abstraction, makes using custom key-value stores easy

## 0.3.0

Initial open source version
