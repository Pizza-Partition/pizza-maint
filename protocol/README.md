# Pizza protocol v4

`contract.json` is maintained by pizza-maint. Run `zig build proto` and
`zig build check-proto` in that repository to generate and check Zig, JavaScript
and TypeScript bindings. The standalone package exports `pizza_protocol` and
embeds both frontend bindings. It contains no storage or executor dependency.

Run `zig build test` in this directory to test the package independently.
Wire protocol mismatches are rejected; older drafts are not converted. Recovery
store format versions are independent of this wire contract.
