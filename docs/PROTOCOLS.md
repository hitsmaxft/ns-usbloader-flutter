# Protocol and identity boundaries

## Awoo USB

`TUL0`, a little-endian 32-bit UTF-8 file-list length, eight zero bytes and newline-separated names advertise a frozen manifest. Names include a path-derived identifier, preserving duplicate basenames. `TUC0` request commands 1/2 carry a 64-bit size/offset and a name; all names and ranges are validated before replying. Reply framing retains upstream's 12-byte header, eight-byte size and twelve-byte padding. Data uses at most 8 MiB blocks, including across split-file boundaries. Command 0 ends the device session without asserting installation success.

libusb transfers run outside the UI isolate with 500 ms native polling and bounded waits. Writes advance by the accepted byte count even on a timeout; they never replay an already accepted prefix. Cancellation is cooperative and cleanup releases the claimed interface and context. A host-level disconnect or protocol error fails the job. Native transport behavior is not proven by the fake transport tests.

## Awoo network

The server binds before any file URLs are advertised. TCP port 2000 receives a four-byte big-endian length followed by newline-separated `host:port/id/name` entries, matching upstream Awoo's scheme-less list. HTTP routing accepts only exact selected entries and GET/HEAD. Range handling returns 206 or 416 with the corresponding Content-Range, including suffix ranges. Full GET works without a Range header. Concurrent and repeated requests accumulate interval coverage without double counting. The server remains available until cancellation; a successful socket write is not remote installation confirmation.

## RCM

The framed payload retains NS-USBloader's intermezzo and spray layout, with the attribution to fusee-launcher. Input is limited to 16,384–126,296 bytes; frames use an odd number of 4 KiB packets. The 16-byte RCM identity response is checked before sending. macOS submits the 0x7000 control request with libusb; Linux uses a bounded usbfs URB; Windows uses the libusb-win32-compatible device IOCTL, checks the driver service and refuses multiple matching devices.

The bus, address, port topology and VID/PID form a selected-device identity. No first-device automatic injection occurs. The Windows helper additionally resolves and rechecks the sole device path. The oversized request's raw status is reported; disconnects and errors can occur during triggering, so it is never reported as verified boot. Patched hardware is not made vulnerable by this software. No hardware exploit or transfer was exercised during implementation.

## Content identity

Package identity is a hash of the normalized absolute path, distinct from title ID and base-game group. Multiple copies remain separate selectable files. Standard title ID relationships classify application IDs, patch IDs (+0x800) and add-on IDs (the application range +0x1001 and above). Unknown/nonstandard IDs stay unclassified. Explicit plaintext CNMT application relationships take priority over inference; users can override group and kind.

The PFS0 parser reads bounded tables (at most 1,024 entries / 64 KiB strings) and a plaintext `.cnmt` entry at most 64 KiB. It does not parse encrypted `.cnmt.nca` contents, XCI encrypted partitions, NACP, compressed package contents, tickets or keys. Multi-title plaintext packages are not assigned one arbitrary identity. Filename IDs remain a lower-evidence fallback. CNMT format fields were checked against [Atmosphère's packaged content metadata declarations](https://github.com/Atmosphere-NX/Atmosphere/blob/master/libraries/libstratosphere/include/stratosphere/ncm/ncm_content_meta.hpp); no Atmosphère implementation code is incorporated.

Title DB indexes use values' `id` fields, not the outer nsuId keys. Name suggestions never modify identity without an explicit user selection. Unfiltered regional input is bounded in memory and passed to a background isolate; it is never written to disk. Only the compact allowlist (ID, name, publisher and an HTTPS artwork URL) is staged and persisted. Cancellation preserves the previous completed index.


## Deliberate exclusions

Goldleaf HOME/VIRT RPC is not implemented or advertised. In particular, the application does not expose an arbitrary host root, and does not claim to offer console MTP. Old Goldleaf protocol variants, nxdumptool receiving, signatures and keys-based decryption are outside this release's scope. The upstream implementation remains available in Git history at the documented reference revision.
