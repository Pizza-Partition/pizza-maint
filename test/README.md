> 运行环境发布测试现位于 [pizza-bundle](https://github.com/Pizza-Partition/pizza-bundle)。
> 本仓库消费固定且通过 attestation 验证的发布；旧的逐文件清单和本地软件包准备流程已移除。
> 当前组装命令见 [dependencies.md](../docs/dependencies.md)。

# Transition test infrastructure

The separately built `zig build hardware-filesystems -Doptimize=safe` matrix
is a Zig-only, opt-in physical test. It takes an explicit empty target and an
independent recovery directory, then tests every registered filesystem in turn.
It never runs automatically. Commands and block-I/O boundaries are documented in
[hardware/README.md](hardware/README.md).

Current architecture: [maintenance design](../docs/superpowers/specs/2026-10-13-pizza-transition-design.md).
The [M0 implementation gate](../docs/superpowers/plans/2026-10-21-pizza-maintenance-plan.md)
records the completed producer release, consumer lock and full application rerun.
The published `v0.4.1` (`cpu-maint-v1`) passed scratch/QEMU checks: 40 command starts,
11 filesystem-plugin technology checks, 27 loadable modules and 19 registered filesystems.
The current Pizza working tree also passed maintenance supervision, in-image backend replay,
executor fault recovery and the complete systemd/kexec/session/report gate using this release.
The maintenance supervisor self-test now invokes bundled dynamic coreutils `bin/true --version`.
It checks dynamic execution without restoring browser sandbox tools. The completed M0 record lists actual commands and evidence;
distro matrices, real hardware, native display and filesystem mutation remain separate gates.

The tooling and test runners are Zig programs built with the pinned 0.17.1 release.
Run `zig build deps` to install locked formatter dependencies. `zig build test`
runs core tests, runtime contract and consumption tests, initramfs tests and native integration tests.
The execution frontend and npm frontend tests have been removed.
`zig build fmt-check` is the CI formatting gate; Zig and ZON use the official `zig fmt`.
Feasibility experiments and VM fixtures belong outside the checkout.

Host test commands are dispatched by `main.zig`, separately from `tools/main.zig`.
Both use the locked `zig-clap` dependency for option parsing and generated help.
The product `pizza-maint` binary is linked for its bundle at build time with
`PT_INTERP=lib/ld-linux-x86-64.so.2` and `DT_RUNPATH=$ORIGIN/../lib`.
Host CLI/TUI/backend harnesses invoke it through the host glibc loader explicitly;
they do not build a host-specific application or patch an ELF. Integration tests
inspect the emitted linkage and execute the same binary from a relocated
working directory using a host-loader fixture. Assembly rejects incompatible
linkage before accessing the runtime release.
Attested release consumption is implemented natively in `../build/bundle/`;
minimal runtime path checks live in `../core/bundle/`.
Initramfs logic lives in `../core/initramfs/`. Generic file, process and JSON helpers live in `../core/utils/`; functions take their required
allocator, I/O and environment parameters explicitly. Runtime logs use `std.log`.

Image-backed maintenance acceptance uses a separate `pizza-maint-fixture` binary,
built explicitly with `zig build maintenance-fixture` or as a test dependency. Its
entry point injects `core/maint/testing/devices.zig`; the ordinary-file backend lives
in `core/maint/storage/testing/image_device.zig`. The production application rejects
image requests before opening the path and has no `--probe-image` command. QEMU
image executor and kexec tests inject the fixture only into a disposable copy of the
maintenance image; the prepared bundle and installed product binary are unchanged.
The fixture uses the same application loop, planner, executor and recovery code.

`zig build test-runners` installs `zig-out/bin/pizza-tests` and the journal/executor fixtures
`zig-out/bin/pizza-journal-guest`, `zig-out/bin/pizza-executor-guest` and `zig-out/bin/pizza-abi-check`; ordinary builds do not install test executables.
`zig build test` compiles the host runner and executor fixture as well as running the test suites.

Tests for private archive, backend, acceptance-gate and matrix argument parsing
implementations live beside those implementations. `zig build test` runs their
test artifacts explicitly, so these helpers do not need public visibility.
Module unit tests live beside their implementations. `integration/` exercises
executable behavior and runtime path confinement.

Runtime trust-policy and archive integration tests live in `../build/bundle/tests.zig`
and run through `zig build test`: they check pinned source/workflow/ref verification,
authenticate the real published v0.3.1 fixture with native cryptography, reject modified assets,
signatures, certificates, log bodies, SETs, Merkle proofs and checkpoints, and reject
wrong publisher/workflow/tag/commit and artifact digests. They also preserve opaque base
bytes, round-trip the application layer and reject every truncated certificate.
Certificate parsing and verification use the standard library, preceded by bounded
standard DER decoding; Fulcio policy remains separate from the generic utils adapters.
TUF tests authenticate real public metadata through roots 10–16, verify signed
timestamp/snapshot/targets and the trust target, enforce distinct old/new root
signature thresholds, and reject tampering, rollback, expired metadata, version
conflicts, removed snapshot entries and substituted targets. Cache tests cover
atomic persistence, loading without subprocesses and strict offline expiry.
The time-sensitive metadata fixtures use a fixed verification time in October 2026.
They also compare native TAR/gzip output with libarchive, cover long filenames and
executable symlinks, reject unsafe extraction paths and corrupted gzip CRCs, and
check archive reproducibility after source timestamps change.
These tests need no GitHub CLI, credentials or network; bsdtar is only the independent
archive interoperability oracle.
`integration/bundle.zig` checks path confinement. Upstream archive construction,
loader checks and runtime ABI tests belong to pizza-bundle's publishing CI.

- `zig build test`: protocol drift, Zig compilation/refusal boundaries, schema/backend unit tests, bundle verification tests.
- `zig build test-maint-executor`: run the maintenance module through its own test root, including default device gates, image-provider execution, committed recovery, request mismatch and cancellation. Dependency-module imports alone do not run these assertions. This suite is also part of `zig build test`.
- `zig build test-filesystems`: run the same filesystem contracts for every registered backend using format-specific fixture providers and independent checkers. Covers direct vtable dispatch, query/check byte preservation, creation, repair, shrink/grow, same-format copy, source and destination-tail preservation, interrupted writes, rollback and repeated power-loss recovery. Registered backends without fixtures fail. Current providers cover ext2/3/4, FAT32, NTFS and Btrfs, requiring host e2fsprogs, dosfstools, mtools, ntfs-3g and btrfs-progs. Format-specific checksum, geometry, Unicode, orphan salvage and corruption tests supplement the shared suite. Build support follows the same format directories under `build/filesystem/{ext,fat32,ntfs,btrfs}/`. NTFS oracle checks use ntfsfix and ntfsresize on a volume-length copy; they do not provide full Windows chkdsk qualification. Btrfs fixtures additionally use read-only data-checksum checking and file restoration; its offline shrink moves whole SINGLE/DUP physical chunks within bounded transaction limits. Implementations live under `core/maint/storage/filesystem/`; all storage tests live under `core/maint/storage/testing/`.
- `zig build test-storage-crash`: dynamically enumerate every registered backend’s validated mutations across four phases (currently 120 ext2/3/4, FAT32, NTFS and Btrfs cases, including same-format copy). A parent sends randomly timed SIGKILL to separate writer and recovery processes, checks retained source bytes, file contents and independent fsck; originally free move destinations may retain bytes after rollback, and requires actual write interruptions, recovery interruptions and completed commits. Test writes are fragmented to expose partial sectors. Use `-- --rounds 800 --seed 12345` for a longer run, or `-- --filesystem ntfs --seed 12345` to isolate a format while retaining all four phases; failures retain artifacts and print the seed. This does not discard the host kernel's disk cache.
- `zig build test-storage-unit`: independently runs current immutable-program planning, data-version and dependency checks, bounded relocation, before-image protection and execution/recovery crash models. Non-discard writes protect their prior contents; explicit create/copy destinations may discard their previous contents. No retired `plan.Plan` or separate reverse-move executor is used.
- `test-storage` also runs a [SQLite-style crash model](https://www.sqlite.org/testing.html#crash_testing) for both target bytes and recovery files: enumerate every baseline I/O event, lose/reorder/tear/corrupt unsynced writes, inject one-shot and persistent I/O/space failures, then repeat failures during recovery. `test-filesystems` runs current `service` plans and `program_executor` for all success and fault cases, and materializes eight additional resize/recovery simulations per resize-capable backend (48 resize and 48 copy cases across ext2/3/4, FAT32, NTFS and Btrfs) with retained-data rollback checks; resize simulations also materialize valid originals for independent fsck and file checks, while copy models can start with an unformatted destination. Committed clones are independently checked by the shared success and SIGKILL suites. The model honors successful sync barriers and models directory persistence separately; it is not hardware power-loss qualification or a claim of SQLite-level coverage.
- `zig build test-storage`: current immutable-program private-image primitives; nine transaction scenarios cover interrupted writes, verification failure, durable commits and interrupted rollback. No filesystem is created or resized. Unit tests also verify concurrent memory accounting and refusal on corrupted programs or recovery state or mismatched identities.
- `zig build test-maintenance -- --storage --bundle PATH --kernel-version VERSION`: the standalone native primitive self-test, injected only into this RAM-root test image. The build passes its binary path; direct `pizza-tests maintenance --storage` runs accept `--storage-binary PATH` (build with `zig build storage-test-binary`). It does not execute the retired third-party filesystem matrix or qualify persistent recovery. See [filesystem boundaries](../docs/filesystems.md).
- `zig build test-smoke`: real static Zig PID1, real host kernel, OVMF, QEMU/TCG. Checks RAM-root and basic mounts, then powers off with explicit `pizza.boot=smoke`. Requires no root or KVM.
- `zig build test-init-recovery -- --base PATH --kernel PATH`: Zig-only QEMU supervisor for production shutdown and eight injected recovery scenarios, including reboot/halt commands, console respawn, persistence, BusyBox fallback and synchronization failure. Uses the native newc/gzip encoder; requires QEMU and e2fsprogs, without a Python runtime. See [init recovery](../docs/init-recovery.md).
- `zig build test-maintenance -- --kernel-version VERSION`: builds the layered image from a prepared base-plus-application package, attaches a fresh read-only virtio disk, and boots with `pizza.boot=selftest`. Requires RAM-root, mounts, matching kernel modules, a block device, successful execution of dynamic `bin/true --version`, direct-child and orphan reaping, TERM/INT handling, the ordinary application exiting with code 17 while PID 1 stays alive, at least three seconds of supervisor lifetime, and clean poweroff. It rejects kernel panics and degraded startup.
- `zig build test-journal`: creates a private ext4 disk, runs two independent QEMU boots, and extracts the persisted journal with debugfs for host-side verification. Checks actual boot IDs, continued sequence numbers, and `succeeded` / `failed` / `in_flight` reconciliation. Requires `mkfs.ext4`, `debugfs`, OVMF and a kernel with built-in virtio/ext4; the build supplies its static fixture PID 1. This is a clean-reboot persistence test.
- `zig build test-transition -- --bundle PATH`: generates a disposable systemd fixture and runs the strict phase-7 gate against a disposable copy of the current image with the separate device fixture injected. Requires the verified base-plus-overlay bundle, host systemd executables, bsdtar, mkfs.ext4, debugfs, QEMU and OVMF; no physical disks or host privileges are used.
- `zig build abi-check`: builds `matrix/abi_check.zig` as a dynamic glibc executable and installs `zig-out/bin/pizza-abi-check`. Copy it to `bin/pizza-abi-check` inside an explicitly unpacked runtime fixture before running the matrix. Its library search path is relative to the executable; the matrix invokes the fixture's loader directly.
- `zig build test-matrix -- --config /path/targets.json --bundle /path/bundle`: boots pinned cloud fixtures, mounts only the unpacked runtime fixture read-only, and runs its local `bin/pizza-abi-check` in an otherwise empty tmpfs root. Supply the cloud images and install the checker into the runtime fixture first.

VM outputs always default to `/tmp/pizza-qemu-*`. Use `KERNEL=/boot/vmlinuz-...`
and `OVMF_CODE`/`OVMF_VARS` for distro-specific paths. The variable-store file is
copied per run. No physical disks are attached to a VM. TCG is used to avoid
depending on `/dev/kvm` permissions. qcow2 inputs remain immutable; writable
fixtures use overlays/snapshot mode.

`zig build test-backend` checks the actual maintenance application and batched journal replay without a graphical runtime.
`zig build test-maintenance -- --backend --bundle /path/bundle --kernel-version VERSION` checks this inside the layered RAM image,
including application exit, PID 1 reaping and poweroff. Its 134-record journal is a RAM diagnostic fixture.

`test-transition` uses the production systemd/kexec fixture, protected session and independent recovery boot.
Backend replay commit sequences are compared with the durable journal independently extracted from ext4.
It validates execution and memory evidence without making graphical output claims.

PID 1 samples all guest process RSS and `MemTotal-MemAvailable`, at a nominal
100 ms interval while supervising the application. `results.json` reports the
sampled maxima as `peak_rss_kib` and `peak_used_kib`, plus the sample count.
Summed RSS double-counts shared pages; used memory includes RAM filesystems and
kernel allocations. These samples may miss shorter spikes and do not measure
the source system/kexec staging peak or PSS. The VM has 4 GiB RAM; use
`--memory-budget-kib N` to impose a lower acceptance limit on both measurements.
The default 4194304 KiB is the fixture limit, not a finalized product budget.
Acceptance also fixes a safety floor of `max(512 MiB, MemTotal/10)` before
launching the application. Every sample must retain this much available RAM;
a transient breach is latched and fails the run even if RAM later recovers.
Reports include `memory_total_kib`, `safety_reserve_kib`,
`minimum_available_kib`, and `reserve_breached`; both report-validation paths
recompute the required floor and require this evidence.
Sampling does not prove the absence of spikes between observations.

Storage execution separately derives a cache budget from `MemAvailable` and
visible cgroup v2 ancestors, with dedicated safety, library and recovery
reserves. `pizza-maint --storage-memory` prints the budget. Guarded allocations
are admitted against both that quota and current headroom. Storage unit tests
cover every simulated allocation, concurrent lanes and latched failures;
filesystem acceptance includes a real 128 MiB clone and recovery after memory
pressure interrupts target writes. This remains bounded in-memory staging,
without disk spill. SIGKILL workers use the same memory controller for planning,
execution and recovery.
The 2 GiB supervisor fixture previously failed during initramfs unpacking, so
both maintenance boot tests now use 4 GiB as well.

The host checks root-disk hashes, orderly systemd shutdown, load refusal and
rollback, new boot identities, journal CRC/completion, and the post-reboot
read-only report. It saves commands, serial logs, disk images, input hashes,
`journal.bin`, marker/plan, report and `results.json` under `/tmp/pizza-qemu-kexec-*`.
This is an isolated systemd RAM fixture with an original filesystem attached
read-only; it does not replace the real distro-image or hardware matrix.

The direct `pizza-tests transition --kernel ... --initrd ... --root-disk ...
--journal-disk ...` entry remains available for external instrumented guests.
Those guests must print exactly one complete `PIZZA_ACCEPTANCE_JSON:{...}` line;
a backend self-test marker alone cannot satisfy either mode.

`qemu/faults.json` enumerates the spec's fault cases. `pizza.fsync_fail_step=N`
is a proposed clarification because the spec's fsync-failure parameter has no
step selector. The parameter list is not evidence that each injection is wired up or has passed; verify the actual consumer and fixture result.

Cloud fixtures belong outside the checkout. Pin an actual image path and SHA-256
in a private copy of `matrix/targets.json`. RHEL images require the user's
properly licensed image source. Resolve `fedora-current` to an explicit Fedora
release/image checksum when running the matrix; never silently retarget an old
result to a new release.

Maintenance PID 1 normally stays running with `pizza.boot=normal` (the default).
It mounts only RAM and kernel pseudo filesystems in this phase.
Startup errors and application exit request controlled reboot; failed shutdown
enters a supervised rescue console. Diagnostic fixtures retain their explicit
completion/poweroff behavior. The application hosts its backend and TUI in one ordinary process. DRM
display and the Linux 4.18 ABI matrix remain separate milestones. The transition
fixture exercises production journal selection and mounting on its independent
ext4 device.

`pizza.*` parsing accepts bare `key=value` tokens. Unknown keys, duplicates,
malformed values and `pizza.nonce` fail closed without printing their values.
Supported non-secret options are `plan_id` (ASCII letters/digits/underscore/hyphen,
up to 128 bytes), `kiosk=enable|disable`,
`journal=enable|disable|fsync_fail`, and `step_fail`, `step_hang`, `fsync_fail_step`
(1–20). Some journal/executor settings are currently only parsed; do not assume every kernel option is connected to execution.
Secrets require the protected RAM handoff described in the spec clarifications.

Native examples:

```bash
zig build test-smoke
zig build test-journal
zig build bundle -Doptimize=safe
zig build test-maintenance -- --kernel-version 7.2.11-arch1-1 --kernel zig-out/runtime/bundle/vmlinuz
zig build test-maintenance -- --backend --kernel-version 7.2.11-arch1-1 --kernel zig-out/runtime/bundle/vmlinuz
# The default kernel is BUNDLE/vmlinuz; no host kernel discovery.
zig build test-transition -Doptimize=safe -- --bundle zig-out/runtime/bundle --memory-budget-kib 2097152
zig build test-matrix -- --check-fixtures
zig build test-smoke -- --help
zig build test-runners
```

The build supplies the first-boot fixture and production CLI to `test-transition`.
The kernel defaults to the bundle's `vmlinuz`; `--maintenance-image PATH` reuses
an image with matching metadata. All artifacts remain outside the checkout.

The matrix needs `cloud-localds` and cloud-init-capable UEFI qcow2 guests with
9p support. It requires no SSH, guest network or host privilege. Override the
local test binary with `--binary RELATIVE_PATH --binary-arg=ARG` (repeatable;
the equals form also permits arguments such as `--version`). Choose a
binary that reports its bundled glibc version and checks its loaded mappings;
a trivial static program alone does not validate the bundled runtime. Matrix output
records the host kernel/glibc and the exact check command. A passing ABI check
does not mark the three full-transition targets as complete.

## Journal layer and reporting

`core/maint/journal.zig` and `journal/storage.zig` implement the v1 wire format and
fsync gate. Unit tests compare an independent Python/zlib golden header, truncate
and corrupt every byte of a terminal record, reject invalid phases and boot/plan
boundaries, exercise sequence exhaustion, and inject write/file-fsync/directory-fsync
failures. A failed append poisons the writer. Reopening a damaged tail refuses to
append; reads preserve the valid prefix without repairing the file.

The CLI integration test runs the real `pizza transition report --journal PATH`
against a torn file and checks that its hash stays unchanged. `report` prints
JSON with decimal-string sequences/timestamps, per-step outcomes, boot/UTC/home
boundaries, UTF-8 payload text where valid, and hexadecimal payload bytes. Notes
never hide an unfinished intent. A non-clean `tail` describes the unread suffix;
`valid_bytes` is the prefix boundary, not a claim that the entire file is valid.

The two-boot fixture mounts only its fresh virtual disk. It does not choose the
product journal home or resolve the original-root read-only constraint. Its
`journal.bin`, `journal.raw`, serial logs and `results.json` remain in
`/tmp/pizza-qemu-journal-*`; use the built `pizza` report command on the extracted
`journal.bin` to inspect the actual recovered timeline.

## Maintenance executor acceptance

The v3 three-transaction same-disk coordinator has a separate ordinary-image
acceptance target, `zig build test-maint-session-image`. Its real subprocesses
compile bootstrap/apply/cleanup, reopen the durable session, then exercise Undo
or acceptance and cleanup. `test-host` additionally verifies a native FAT32 file
originally allocated in the reused tail. `test-storage-unit` injects persistence
faults across the coordinator phases. These do not claim OVMF boot or physical
same-disk acceptance. See [v3 implementation status](../docs/maintenance-session-v3.md)
for remaining production wiring and the original independent-device gate.

`zig build test-executor-physical test-executor-physical-4kn -- --bundle /path/current-bundle --kernel-version VERSION`
uses the production application on disposable, separately attached block devices
with 512-byte and 4096-byte logical sectors. It checks mounted-target and
same-disk recovery rejection before journal creation, successful mutation,
SIGINT rollback, SIGKILL and recovery without the clone source after reboot.
The host independently checks FAT32/ext4. No host physical disk is passed to QEMU.

`zig build test-executor -- --bundle /path/current-bundle --kernel-version VERSION`
builds the full layered image, then appends a static VM-only PID 1 and the separate
`pizza-maint-fixture` entry point to a disposable copy. Only the fresh private
`/dev/vda` ext4 disk is mounted. The fixture uses v2 image requests and the shared
application loop, planner, executor and recovery code. The product binary and
prepared bundle remain unchanged.

Six homes test real formatting, a changed stable identity, a clone killed after
its durable physical intent, a torn presentation journal, interrupted cloning
whose source is deleted before recovery, and SIGINT cancellation with automatic
rollback before process exit. A second boot runs raw recovery without
rerunning filesystem algorithms or reopening the missing clone source. Host
extraction and `pizza transition report` independently inspect the journals.
Step counts come from the compiled physical program. Fault injection remains in
test wrappers; production CLI fault flags and fixed simulated steps were removed.

The application accepts an existing caller-selected home on ext4, XFS or Btrfs.
It rejects volatile/unknown filesystem types and never creates or mounts a home.
Image identity and geometry are checked after an exclusive open. Production physical
writes additionally require hardware identity, geometry, exclusivity and an
independent persistent recovery disk; PID 1 startup alone grants no write capability. See
[storage architecture and requests](../docs/filesystems.md).

## Production kexec and journal handoff

```sh
zig build test-kexec -- --bundle /path/to/current-bundle \
  --kernel-version VERSION --output /tmp/pizza-kexec-acceptance
```

The runner builds a disposable RAM systemd environment, invokes the actual Pizza
CLI, verifies a real load/unload rollback after a rejected shutdown command, then
uses ordinary `systemctl kexec` to enter the production PID 1 and a maintenance
image containing the separate device fixture. The app discovers its independent
ext4 device by UUID, validates the protected plan and durable loaded marker, and
executes real formatting steps through the shared executor. A separate boot
checks completion and the read-only report. The original disk is attached
read-only and independently hashed before and after the test.

The test never invokes kexec, reboot or host disk mounts on the development host.
The deliberately rejecting systemctl fixture is used only for the rollback case;
the successful switch uses the real systemd manager and systemctl. This focused
suite does not replace the broader `test-transition` acceptance gate, graphics,
Secure Boot, distro matrix or physical-hardware validation.

The distro compatibility matrix takes an explicitly unpacked `pizza-bundle` raw runtime fixture (`runtime.json`), not the production opaque base-plus-overlay package.
