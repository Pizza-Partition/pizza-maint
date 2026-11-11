# Pizza protocol v4

`contract.json` is maintained by pizza-maint. Run `zig build proto` and
`zig build check-proto` in that repository to generate and check Zig, JavaScript
and TypeScript bindings. The standalone package exports `pizza_protocol` and
embeds both frontend bindings. It contains no storage or executor dependency.

Run `zig build test` in this directory to test the package independently.
Wire protocol mismatches are rejected; older drafts are not converted. Recovery
store format versions are independent of this wire contract.

Shared source modules also own the UEFI lease algorithm, firmware pin codec,
receipt envelope parser, inventory fingerprint and intent normalization. OS ports
implement the shared Variables interface. LeaseFor(false) preserves the host's
existing tolerance of repeated BootOrder entries; LeaseFor(true) preserves the
maintenance endpoint's strict admission policy. Payload size limits remain explicit
arguments to FirmwarePin. These source API additions do not change wire v4 or any
on-disk field name. Full host scheduling and offline feasibility validation remain
in their respective applications.
