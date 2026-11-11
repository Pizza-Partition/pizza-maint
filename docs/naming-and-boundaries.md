# Naming and module boundaries

The canonical shared contract lives in `pizza-maint/protocol/`. Both products
consume its UEFI lease implementation, firmware pin and receipt codecs, inventory
fingerprint and intent normalization. The exported package includes every source
and a SHA-256 manifest. The desktop consumes this package from its pinned maintenance
release; it does not carry a separately edited copy.

| Previous name                                | Current name                                 | Responsibility                                    |
| -------------------------------------------- | -------------------------------------------- | ------------------------------------------------- |
| Pizza `core/boot/session.zig`                | `core/boot/ports.zig`                        | Live maintenance controller and ESP storage ports |
| Pizza `core/desktop/http.zig`                | `core/desktop/asset_response.zig`            | Embedded asset response and MIME handling         |
| Pizza `ui/partition/prototype/`              | `ui/partition/app/`                          | Shipped frontend                                  |
| Pizza platform `session.zig` / `session/`    | `privileged_service.zig` / `ipc/`            | Privileged service lifecycle and IPC              |
| Pizza GPT `slot()`                           | `entryIndex()`                               | Zero-based GPT entry index, including holes       |
| pizza-maint `core/session*`                  | `core/legacy_handoff*`                       | Pre-v4 journal handoff and mounted journal home   |
| pizza-maint `core/maintenance_session/`      | `core/restart/`                              | v4 reboot handoff and offline compilation         |
| pizza-maint `maint/plan.zig` / `backend.zig` | `legacy_executor.zig` / `legacy_backend.zig` | Existing CLI execution and journal replay         |
| storage `maintenance_session.Session`        | `recovery_session.RecoverySession`           | Durable recovery state machine                    |
| storage `mutation.Builder`                   | `MutationBuilder`                            | Filesystem mutation overlay                       |
| storage `program.Builder`                    | `PhysicalProgramBuilder`                     | Versioned physical storage program                |

The obsolete host Prepared/Artifacts state machine and its tests were removed;
the live Maintenance platform tests remain. Legacy maintenance execution is still
reachable through the CLI and init fallback, so its implementation is retained
under explicit legacy names. Console output and dashboard polling/drawing belong
to the application composition root, not the executor or journal backend.
Same-disk FAT proof and recovery-bundle admission live in `session_admission.zig`;
the block driver enforces the resulting bounded write ranges.

Host scheduling and offline feasibility checks have different responsibilities.
Only their identical intent folding and data-version barrier rules are shared.
The shared LeaseFor policy preserves each endpoint's previous duplicate-BootOrder
handling. FirmwarePin payload limits also remain explicit per endpoint.

Wire v4, persisted field names, public CLI flags, file magic and record layout
remain compatible. In persisted structures `slot` retains its encoded name:
Handoff.Lease.slot is a UEFI Boot#### number; DesiredPartition.slot is a GPT entry
index. Storage model Range.offset and Range.length are bytes; sector_size is bytes
per logical sector; start_lba/size_lba count logical sectors. New internal geometry
names should include _bytes, _lba or _index where the type does not make this clear.
Storage fixtures are exposed only in unit-test or explicitly marked image harness
roots. Production maintenance no longer re-exports execution test suites.
