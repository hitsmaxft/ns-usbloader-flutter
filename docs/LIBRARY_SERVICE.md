# Persistent library service

The library service is the host implementation for the Awoo gallery extension.
It owns a local SQLite database, scans configured package sources, and publishes
only its committed inventory through a read-only HTTP API. It does not expose
filesystem browsing, title-key handling, payload injection, source mutation, or
an installation-success claim.

## Storage and source ownership

`library.sqlite` is created under the configured local `dataDirectory`. Do not
place it on an SMB/NFS game mount or open it directly from a GUI on another
machine. One service process owns writes; GUI, CLI and NAS deployments use the
same Dart storage/service layer only when they run on the same host.

Source records can be directories or individual package files. Package paths,
segment sizes and modification times are committed transactionally. A repeated
scan can reuse unchanged stored metadata without rereading a package's bounded
metadata probe. Split packages are represented as one logical package.

For an unchanged source-root snapshot, the service does not walk the directory
tree or create a new library revision. A filename-rule or manual-override
change refreshes only the already indexed package paths. Where the filesystem
provides recursive directory notifications, a debounced event starts a full
discovery scan for new, removed, or renamed files. `scanIntervalSeconds` is the
full-discovery fallback for NAS mounts and missed notifications; use a longer
interval such as the example's six hours for a large remote library.

If a source root disappears, its prior records remain in the index and are
reported as unavailable. A successful complete enumeration is required before
paths are reconciled as deleted. Cancelling a scan leaves the previous revision
unchanged.

## CLI

```sh
nsusbloader library-add /var/lib/ns-usbloader /mnt/games/switch
nsusbloader library-scan /var/lib/ns-usbloader
nsusbloader library-serve /etc/ns-usbloader/library.json
```

`library-add` accepts an existing directory or one NSP/XCI/NSZ/XCZ package.
`library-scan` prints the committed revision and individual scan issues.
`library-serve` needs one absolute JSON configuration path. Start with
[library-service.example.json](library-service.example.json), put the token in
a separate file, and grant the service account read access to the configured
game sources. Configure Awoo with the resulting `http://host:port` once; it
remembers the successful endpoint locally.

The host binds only to a numeric address. This prevents an accidental DNS name
from binding an unexpected interface. Use an explicit LAN address, firewall it
to the intended subnet, and do not expose this service to the public internet.
HTTP is useful for a trusted LAN but does not encrypt the optional bearer token.

The service starts listening from its prior committed database before its first
background scan. It uses directory events when available and runs full
discovery at `scanIntervalSeconds` (15–86400 seconds) as a fallback. Stopping
the service cancels a scan and active HTTP streams; no partial index is
committed.

`GET /healthz` is a small unauthenticated readiness endpoint returning `ok` and
the committed revision. It does not expose file paths or catalog data. The
daemon takes an exclusive `library.lock` in its data directory, so two service
instances cannot silently become concurrent writers.

## API v1

The Awoo client uses these routes after a configured server connection:

| Route | Behavior |
| --- | --- |
| `GET /api/awoo/v1/info` | Server identity, current library revision and `library` capability. |
| `GET /api/awoo/v1/games?limit=…&cursor=…` | Revision-bound pages of up to 200 game cards. |
| `GET /api/awoo/v1/games/{id}?revision=rN` | Exact Base, Updates, DLC and unknown-content package records. |
| `GET /api/awoo/v1/covers/{id}` | Cached title cover or small original generated PNG; no remote-image proxy. |
| `HEAD` / `GET /api/awoo/v1/packages/{id}/{contentRevision}/{filename}` | Published available package with full or single range responses. |

JSON responses contain `schemaVersion`, stable `serverId`, and `libraryRevision`.
Cursors and game detail requests reject stale revisions with HTTP 409. Package
URLs bind an observed segment snapshot; changed files fail normal `FileSource`
verification rather than silently satisfying an old resume offset. Unauthorized
requests return 401, missing/unpublished/unavailable packages return 404, and
invalid ranges return 416.

Only compact Title DB display fields may enter `title_metadata`. The server uses
an already cached cover from `coverCache` if available. Otherwise it returns a
small deterministic original PNG generated from the game group ID, without
writing it to a mount or using commercial game artwork. No raw Title DB response,
keys, tickets, local paths, or source credentials appear in API responses.

## Linux NAS deployment

[ns-usbloader-library.service](../packaging/ns-usbloader-library.service) is a
systemd template, not an installer. Adjust the executable, service account,
data directory and read-only mount paths before enabling it. Its hardening
directives intentionally allow only the local database directory to be written.

Build the headless CLI on the target architecture and keep its generated
companion `lib/` directory beside the executable. Validate x86_64 and arm64
artifacts independently. This repository has not built a Linux release or run a
NAS deployment in this environment.
