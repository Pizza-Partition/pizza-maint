# Review fixes, November 2026

The review identified defects as well as architectural suggestions and hardware-dependent hypotheses. This patch addresses the concrete defects without changing the published v4 handoff wire format.

- ext allocation and relocation use libext2fs block-validity rules, preserving fast and block-backed symlinks. Fixtures check 51-, 59- and 100-byte targets after shrink and grow. Reserved blocks scale with filesystem size. Relocated orphan-file blocks receive new checksums. Formatting clears the old boot signature region.
- NTFS update-sequence fixups use 512-byte strides on both 512-byte and 4Kn media. Independent ntfs-3g tools check the native format.
- FAT orphan traversal rejects free, BAD, reserved and out-of-range links before indexing.
- In-process rollback uses an independent allocator after the execution memory controller has latched a failure. Logs retain both the original and recovery failures.
- PID 1 enters rescue on initialization failure; shutdown always attempts the final sync.
- Durable preparing states make interrupted bootstrap and cleanup-store initialization restartable. Existing transaction headers are never treated as fresh reservations. Failed cleanup can be explicitly retried without replaying accepted user changes.
- Decision prompts discard old terminal input and accept exactly one complete line. This prevents cancel text or queued input from accepting verified changes.
- Firmware lease restoration removes only the owned boot option, preserves unrelated BootOrder changes and foreign BootNext values, and leaves a reused option alone.
- Runtime physical write granules expand metadata writes and their before-images to cover neighboring 512e logical sectors. Unsupported unaligned copy/restore programs fail preflight before any write; this is not a promise of arbitrary drive firmware atomicity.
- Discovery errors propagate unless they explicitly mean that a device identity or journal format is unsupported.
- EFI stub package and executable digests are locked in tools/efi-stub.json. Both download and UKI assembly validate them. CI rejects a missing or dynamically linked PID 1.

Release dependency: pizza-bundle v0.5.1, with the exact commit and asset digests recorded in config/bundle/release.json. Release CI remains the gate for published artifacts, including production application QEMU boot tests.

The review's proposed wholesale namespace changes and protocol extraction are architectural follow-up work. They are not prerequisites for these fixes and are not claimed as completed. Real firmware, Windows sparse-GPT and power-loss behavior still need physical hardware acceptance; image, fault-injection and VM results do not establish those hardware guarantees.
