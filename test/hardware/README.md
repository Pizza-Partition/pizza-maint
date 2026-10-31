# Physical filesystem acceptance

The hardware matrix is a Zig executable. It takes an explicitly selected empty,
disposable block device or partition; no USB serial, partition start, capacity,
backup mount or device path is compiled into the test. Python is not required.

```sh
zig build hardware-filesystems -Doptimize=safe

# Read-only identity, geometry and registered-format preflight.
sudo zig-out/bin/pizza-filesystems-hardware --device /dev/DEVICE

# Explicit destructive run; the recovery directory must be new, with an existing
# parent on another persistent physical disk. The selected target must be empty.
sudo zig-out/bin/pizza-filesystems-hardware \
  --device /dev/DEVICE \
  --journal-home /absolute/independent-disk/run-001 --run

# Resume the same run; passed cases are not repeated.
sudo zig-out/bin/pizza-filesystems-hardware \
  --device /dev/DEVICE \
  --journal-home /absolute/independent-disk/run-001 --run --resume

# Supervisor process tests: no disk access, no root privileges.
zig build test-hardware-supervisor -Doptimize=safe
```

`/dev/DEVICE` is a placeholder for the explicitly authorized target. A stable
`/dev/disk/by-id/...` name or a current kernel device path is accepted; the
production backend derives and checks hardware identity independently of that
path. `--run` asserts that the selected target is empty and disposable; the test
cannot prove that arbitrary residual bytes contain no valuable data. It rejects
recognized partitioned targets; select an empty partition or an unpartitioned
empty disk. It does not select or erase a disk automatically.

The matrix discovers every registered backend and its contract fixture, currently
ext2 → ext3 → ext4 → FAT32 → NTFS → Btrfs. It formats the same target view, finishes
that format's complete contract, then replaces it with the next format. Per-format
fixtures use 64 MiB (ext2/3/4, NTFS) or 128 MiB (FAT32, Btrfs), shrink to half and
grow back. All writes are bounded to the first 128 MiB of the selected target;
these borrowed views do not create hardware partition entries. A 1 GB device is
ample. The suite currently requires 512-byte logical sectors; unsupported
geometry fails before target writes rather than silently skipping a format.

Each of the six formats runs 28 checks:

- Native format and an independent filesystem check.
- A seeded 1 MiB file with data forced into the shrinking tail, read-only query
  and check, and independent content verification.
- A proven repairable inconsistency, native repair and independent verification.
- SIGINT cancellation, SIGKILL during shrink and again during recovery, repeated
  rollback and comparison of meaningful retained bytes.
- Forced data relocation, shrink, grow and independent file verification.
- Same-device clone refusal, interrupted clone recovery without a source
  capability, then a successful source-preserving clone and verification.

The Zig parent signals only its own child after an observed target-I/O checkpoint.
Every child acquires the target itself through production `BlockDevice` with the
saved identity, exclusive access, mounted/holder/swap checks and independent
recovery-disk admission. Recovery uses the production executor and persistent
records, not UI logs. Source fixture images remain locked and read-only; image
backends never replace the physical target. Independent filesystem tools create
fixtures and check results; Pizza performs the mutations under test.

The recovery directory holds a frozen executable and digest, identity/geometry
manifest, per-case requests, stdout/stderr, exit statuses, immutable execution
programs, undo, scratch and results. A resume refuses changed identity, geometry,
fixture contracts or executable. A failed case stops the sequence and retains
its records; an unrecorded case is not silently retried. A completed run has
172 recorded actions (168 format checks plus admission, initialization and final
format/check), and leaves an empty Btrfs in the 128 MiB test view. `report.json`
records the actual formats and counts. A completed `--resume` performs no target
writes.

For explicit recovery of an unrecorded interrupted case, the frozen worker can
be invoked with its recorded format, fixture home, case directory and identity:

```sh
sudo /absolute/independent-disk/run-001/pizza-filesystems-hardware \
  ext4 recover /absolute/independent-disk/run-001/ext4 \
  /absolute/independent-disk/run-001/ext4/cases/kill-shrink \
  IDENTITY_FROM_MANIFEST none /dev/DEVICE
```

The recovery worker accepts no source capability. Retain the recovered case and
its evidence; an unrecorded failed case still requires inspection before starting
another matrix. Physical power removal and hardware partition-table mutation are
separate acceptance scopes.

Historical fixed-USB Python supervisors and their fd-lending Zig runner were
removed. Their original artifacts and reports remain historical evidence, not
portable test entry points:

- [Initial experiment](../../docs/hardware-experiment-2026-10-23.md).
- [Recovery experiment](../../docs/hardware-experiment-2026-10-24.md).
- [Production CLI experiment](../../docs/hardware-production-2026-10-24.md).
- [Six-format physical matrix](../../docs/hardware-filesystems-2026-10-25.md).
