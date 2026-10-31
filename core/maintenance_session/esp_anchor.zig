//! Host and maintenance share the native FAT32 recovery-file proof.
const anchor = @import("storage").esp_anchor;
pub const ShortName = anchor.ShortName;
pub const Proof = anchor.Proof;
pub const inspect = anchor.inspect;
pub const revalidate = anchor.revalidate;
test {
    @import("std").testing.refAllDecls(anchor);
}
