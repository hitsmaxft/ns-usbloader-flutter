# Persistent library and Awoo gallery

Status: host index/API/service implementation in progress; Awoo client validation remains pending. Updated 2026-10-16.

## Intended result

Add game directories or individual package files once. The application scans them into a persistent SQLite index containing sources, packages, games and Base / Update / DLC relationships. A library service publishes that inventory. An extended Awoo client remembers the server, refreshes its catalog when opened, shows a cover gallery and lets the user choose content to download through its installer. No repeated desktop file selection or send operation is required.

The same index and service core runs inside the macOS, Windows and Linux GUI, or as a headless Linux service on a NAS. A NAS does not need Flutter, a display server, Java or an open desktop application. Its service and storage must be reachable for downloads; an offline catalog remains browsable from the client cache.

The selected console integration is an **Awoo extension**. DBI and Tinfoil adapters are outside this increment. Stock Awoo does not gain a gallery merely by receiving a JSON URL. We must deliver and validate changes to both the host and the Awoo client.

## User flows

1. In the GUI, add one or more directories or individual files. Choose whether each source is published, then scan. All eligible packages in a published source enter the library without per-file selection.
2. Enable library sharing once. The GUI displays a persistent server address and its running state. On later application launches it restores the sharing preference and serves the last committed index while checking sources in the background.
3. Alternatively, configure source paths and a data directory on a NAS, start the Linux service, and enable service startup. The NAS performs its own indexing against its own filesystem paths.
4. Configure the server address once in extended Awoo. Remember the IP/hostname and port of recently connected servers on the console, restore the last successful server after restart, and offer history selection and removal. Opening its Library page loads the cached gallery immediately and checks for a new catalog revision. An optional startup preference opens Library directly.
5. Open a game card, inspect Base / Updates / DLC, select exact versions and formats, and confirm the download/install queue on the console. Refreshing a catalog never starts an installation.
6. Add or remove packages on disk. A background scan publishes the changed inventory; Awoo receives it on its next refresh without desktop interaction.

## Deployment and ownership

| Mode | Index owner | Filesystem paths | Client access |
| --- | --- | --- | --- |
| Desktop GUI | Embedded library service | Paths selected on that computer | Awoo connects to the desktop address |
| Linux NAS | Headless service | Paths mounted inside the NAS service/container | Awoo connects directly to the NAS address |
| GUI managing NAS | NAS service | NAS paths returned by the service | GUI uses a separate authenticated management API |

The first two modes are required. Remote NAS management is a follow-up; initial NAS configuration can use a file and CLI. The GUI must not open a NAS SQLite database over SMB/NFS. It must not interpret Windows drive letters or macOS mount paths as NAS paths.

SQLite belongs on local storage on the machine running the service. Game roots may be network mounts. A deployment has one database writer/service owner; additional local GUI processes connect to it or refuse a second writer with an actionable message. No automatic multi-host database merging is required.

### Data locations

Resolve directories with native platform APIs/environment conventions, not hard-coded usernames. Adopt a stable application identifier before migration.

| Platform | Default persistent data location |
| --- | --- |
| macOS GUI | User Application Support / application identifier |
| Windows GUI | User Local App Data / application identifier |
| Linux GUI or user service | `$XDG_DATA_HOME/ns-usbloader`, otherwise `~/.local/share/ns-usbloader` |
| Linux system service | Explicit `--data-dir`, packaged service default `/var/lib/ns-usbloader` |
| NAS container | Explicit local persistent volume mounted at `/data` |

Store `library.sqlite` and durable preferences under the data directory. Store downloadable covers and other rebuildable artifacts separately with bounded cache retention. Metadata, credentials, indexes and downloaded assets never enter the source repository. Existing folder settings and manual overrides migrate without deleting their previous files until migration succeeds.

## Persistent index requirements

| ID | Requirement |
| --- | --- |
| IDX-01 | Register directory and individual-file sources, enable/disable scanning and publication independently, and remove a source without deleting its files. Support NSP, NSZ, XCI, XCZ and validated split packages. |
| IDX-02 | Restore the last committed library immediately at startup. Scanning and metadata refresh must not block initial browsing. Persist directory membership, package identities, relationships, metadata evidence and scan status. |
| IDX-03 | Incremental scanning compares segment path, size and modification information. Do not read entire multi-gigabyte packages just to enumerate them. Bounded metadata probes remain cancellable. Never follow directory symlinks by default. |
| IDX-04 | Give each package an opaque persistent ID, separate from Title ID, game group and content revision. Overlapping roots must not create duplicate rows for the same file. Distinct copies, formats and versions remain separate packages. Do not merge files merely because names or sizes match. |
| IDX-05 | Use verified readable identity where available, distinguish filename-derived identity, retain manual overrides, and keep unknown or orphan DLC visible. Only explicit ID relationships or manual confirmation may associate content; fuzzy names remain suggestions. |
| IDX-06 | A successful scan publishes an atomic revision. Cancellation, partial access failure or process interruption must not publish a half-built replacement or erase the last good inventory. Unreachable sources become unavailable, not empty. Only completed enumeration can establish deletion within its scope. |
| IDX-07 | Keep unavailable records for browsing with a visible state; reject new downloads of unavailable files. A missing NAS mount must not turn its empty mountpoint into evidence that all games were deleted. Recheck source identity/availability before deletion reconciliation. |
| IDX-08 | Preserve manual identity decisions through rescans. Recognize renames only with sufficient filesystem evidence or an explicit user relink; otherwise mark the old entry missing and create a new entry. |
| IDX-09 | Use transactional schema migrations, foreign keys, schema versioning and a tested backup/restore path. Separate rebuildable package observations from source configuration and manual decisions so an index rebuild does not erase user work. |

### Logical SQLite model

This is the required data model, not a final migration script.

| Entity | Required fields or relationship |
| --- | --- |
| `sources` | ID, file/directory type, native root path, scan/publish flags, availability, last successful scan |
| `directories` | ID, source ID, parent ID, relative path, scan generation/status |
| `packages` | ID, format, content type, Title ID, version, byte size, identity evidence, availability, content revision |
| `package_locations` | Package ID, source membership, native relative path; overlapping sources share one package identity |
| `segments` | Package ID, ordered part number, location, size and modification observation; split packages expose one logical file |
| `games` | Group ID, base Title ID when known, display metadata reference; unknown groups need no fabricated Title ID |
| `game_content` | Game ID, package ID, Base/Update/DLC/Unknown role, association evidence and manual override |
| `title_metadata` | Title ID + locale, name, publisher, local cover reference, provider and refresh metadata; display-field allowlist only |
| `overrides` | Durable user identity/grouping decisions, separate from scan-derived data |
| `scan_runs` / `library_state` | Scan outcome, issues, committed catalog revision, schema version, stable server ID |

Index source membership, Title ID, group membership and availability. Cover image bytes remain files, not SQLite blobs. Start with one writer and bounded read transactions; WAL is permitted only on supported local storage. Use SQLite's backup mechanism or a quiescent checkpointed export, never copy a live database file alone.

## Awoo library protocol v1 proposal

Keep the existing Awoo TCP 2000 length-prefixed URL-list transfer and existing USB framing intact. The library uses a separate versioned HTTP API, discovered from a saved server URL. Do not inject new control messages into a stock Awoo listener or claim upstream protocol standardization.

The extension has three operations: discover capabilities, fetch catalog metadata, and fetch selected package bytes. The console initiates each operation; the server never needs a console IP to publish its library.

| Route | Purpose |
| --- | --- |
| `GET /api/awoo/v1/info` | Stable server ID, display name, protocol version, supported capabilities, current revision and limits |
| `GET /api/awoo/v1/games?limit=…&cursor=…` | Paginated game cards, search/filter support, opaque revision-bound cursor, `ETag` / conditional refresh |
| `GET /api/awoo/v1/games/{id}?revision=…` | Base / Updates / DLC groups and exact package choices from a consistent catalog revision |
| `GET /api/awoo/v1/covers/{id}` | Bounded cached artwork with fallback when absent; no arbitrary URL proxy |
| `HEAD, GET /api/awoo/v1/packages/{id}/{contentRevision}/{filename}` | One explicitly published logical package, full response or single byte range |

JSON responses contain `schemaVersion`, `serverId` and `libraryRevision`. Package records contain opaque ID, display filename, format, Title ID when known, identity evidence, content type/version, size, availability and a relative download URL. Never return local absolute paths, keys or filesystem credentials. The client resolves relative URLs only against its configured server; arbitrary origins and redirects are not accepted silently.

Pagination must retain a consistent revision or return a specific stale-revision error requiring restart. A game detail response must not silently mix revisions. Unknown fields are ignored within v1; unsupported major versions produce a clear update-required state. A stock/legacy endpoint failing capability discovery remains a legacy transfer target, not an empty library.

Initial limits: 100 game cards per page by default, at most 200; at most 1 MiB JSON per response; paginate unusually large content groups. Covers are fetched lazily with bounded decoded dimensions and cache size on the console. Search and filters run against the host index. Later delta synchronization is optional; paginated conditional refresh is required first.

### Download contract

- Support `HEAD`, full `GET`, single normal/open/suffix ranges and correct `206` / `416`, including ranges crossing split segments. Duplicate basenames must have different package URLs.
- Pin a URL and ETag to an immutable observed content revision. Validate the source before streaming and fail obsolete revisions rather than serving replacement bytes at an old resume offset. A changed file during a stream terminates that transfer; metadata observations are not cryptographic content verification.
- Support conditional range requests. The extended client must distinguish a full `200` restart from a `206` continuation and never append a full response to a partial file. When safe installer resume is unavailable, offer retry/restart rather than promising resumable installation.
- Multiple catalog readers and bounded concurrent downloads must not block scanning. Publish new revisions without invalidating unchanged package downloads. Revoking publication prevents new requests; stopping sharing cancels active streams.
- Only indexed, published files are addressable. Block traversal and arbitrary host-file access. The console API cannot delete, rename or write source files, change roots, or start an injection.
- Bind to the configured LAN interface and persistent port. Provision a per-client access credential once; extended Awoo sends it in a header and logs redact it. Do not claim plain HTTP encrypts credentials. Remote exposure, router changes and public hosting are outside scope.
- Desktop progress reports bytes served and connection state. Awoo owns installation results; a fully served file is not proof of successful installation. A completion-report extension can be added separately and must be labelled client-reported.

The exact wire schema and fixtures must be committed and exercised by both implementations before the extension is considered compatible. These routes are a design proposal, not a claim that stock Awoo supports them.

## GUI and console experience

Desktop Library settings provide **Add folder**, **Add files**, scan progress, source availability, publication toggles, and the persistent server address/status. Preserve the existing selected-file transfer queue as a separate operation. Show concise states instead of technical paragraphs.

Awoo adds **Library**, saved server selection, cached cover grid, search and filters, and a game detail page. A game occupies one card with update/DLC counts. Details separate Base / Updates / DLC and expose every version/format/copy explicitly. Orphans appear as usable records with missing-base context. Never automatically select every DLC, replace an installed version, or infer installed state from the desktop inventory. Missing artwork uses original fallback graphics.

Persist at most 10 recent server endpoints, normalized and deduplicated by scheme, host and port. Store the most recent successful connection first, with display name, stable server ID when available and last-success timestamp. Failed connection attempts must not replace the last working server. Preserve an offline remembered server, offer explicit retry/edit/forget actions, and never silently scan the LAN or connect to every historical address. Remembered addresses and credentials are separate records; forgetting a server removes its credential as well. IPv4, hostnames and bracketed IPv6 must round-trip without corrupting the port.

Handle first-use, empty library, refreshing, offline cached library, unavailable file, incompatible server and expired credential states. A server going offline must not freeze navigation. Refreshing the list must preserve focus and queued package selections when those packages remain valid.

## Linux NAS service

The implemented service core is UI-free and shared by GUI and CLI. The deployed server uses one explicit JSON config containing its data directory, bind address, port and sources. Required release targets are Linux x86_64 and arm64, with native SQLite runtime dependencies declared and validated for each artifact.

Foreground operation, periodic scans, a manual scan command, a read-only health endpoint, graceful shutdown, an exclusive daemon lock and a systemd template are implemented. Container deployment and Linux release artifacts remain follow-up work. Startup restores the committed index before background reconciliation.

NAS operation is independent of Xcode and macOS desktop availability. System boot startup is required for the NAS deployment. Desktop OS login startup and remote GUI administration are follow-ups; quitting a desktop host stops its embedded server unless a separately installed service owns it.

## Acceptance criteria

| ID | Scenario and required evidence |
| --- | --- |
| ACC-01 | Register a directory and an individual synthetic package, scan, restart the host: both reappear from SQLite without re-adding or completing a rescan. |
| ACC-02 | Configure extended Awoo once, restart it twice: each launch refreshes the saved server's inventory and permits package selection without any desktop send action. |
| ACC-03 | Present one base, two update versions, multiple DLC, an orphan DLC and two formats/copies: correct cards/groups remain stable across restart and no package is silently selected. |
| ACC-04 | Add/change/remove a file, cancel a scan and interrupt a transaction: clients see complete revisions; cancellation retains the prior inventory. |
| ACC-05 | Disconnect a NAS mount and reconnect it: records become unavailable, remain cached and recover without losing overrides or being mistaken for deleted games. |
| ACC-06 | Exercise duplicate filenames, overlapping roots, traversal attempts, revoked publication and obsolete download URLs: only intended current published bytes are served. |
| ACC-07 | Request normal/open/suffix/cross-segment ranges; interrupt and retry downloads: byte-for-byte synthetic fixtures match, and full-response fallback cannot corrupt resumed output. |
| ACC-08 | Restart a Linux NAS service with no GUI/Flutter/Xcode installed: its persisted catalog is available and background scans resume. Validate x86_64 and arm64 separately. |
| ACC-09 | Existing Awoo URL-list and USB protocol tests still pass. Validate stock-client compatibility separately from extended-client gallery behavior. |
| ACC-10 | With 10,000 synthetic package records, startup renders the first cached page without waiting for filesystem scans; record startup, first-page latency, peak memory and index size on a named reference host. Establish numeric budgets from this baseline. |
| ACC-11 | Run schema migration, backup/restore and index rebuild fixtures: sources and manual relationships survive; failures preserve the old usable database. |
| ACC-12 | Validate the actual extended Awoo build on a console for gallery navigation, caching and server reconnection. Real package installation remains a separate explicitly authorized hardware validation step; mocks or desktop screenshots do not satisfy this gate. |

## Delivery boundaries

1. Complete: persistent SQLite storage/migrations, directory/file GUI registration, shared headless core and scan lifecycle.
2. Complete in source: persistent library server, versioned contract fixtures, content revisions, Linux service config/template and host-side integration tests. Linux release artifacts and deployment validation remain pending.
3. Awoo client fork with saved servers, gallery, content selection and installer integration; console build and separately recorded device validation.

Completion requires both host and client work. This host repository now persists sources/packages/manual overrides in SQLite, publishes a revision-bound gallery API, and provides a headless service entry point with a systemd template. A separate local Awoo checkout has initial gallery, recent-server persistence and protocol client source with portable loopback tests; it has not been built as an NRO or validated on a console. Its exact initial wire contract is recorded in that checkout's `docs/LIBRARY_EXTENSION.md`. The Awoo checkout remains separate from this Flutter repository and from nsp-dawrin; preserve its upstream licensing and attribution. No remote fork has been created.

Upstream Awoo documents LAN/USB and URL-based installation, which is the existing transport foundation; the catalog API and gallery above are our proposed extension. See the [Awoo repository](https://github.com/Huntereb/Awoo-Installer) and the current host [network adapter](../lib/services/network.dart).
