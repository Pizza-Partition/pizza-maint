//! Read-only ELF metadata inspection for executable compatibility checks.
//! Runtime ELF modification is performed by patchelf in pizza-bundle.
const std = @import("std");
const elf = std.elf;
const Ehdr = elf.Elf64.Ehdr;
const Phdr = elf.Elf64.Phdr;
const Shdr = elf.Elf64.Shdr;
const Dyn = elf.Elf64_Dyn;

/// Checks the four-byte ELF magic without validating the rest of the file.
pub fn isElf(io: std.Io, path: []const u8) !bool {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var magic: [4]u8 = undefined;
    return try file.readPositionalAll(io, &magic, 0) == 4 and std.mem.eql(u8, &magic, elf.MAGIC);
}

/// Parsed ELF loader, dependency, architecture and symbol-version information.
/// Strings and collections use the supplied allocator (normally an arena); input bytes are not retained.
pub const Metadata = struct {
    /// DT_NEEDED library names, in declaration order.
    needed: []const []const u8,
    /// DT_RUNPATH values, each containing colon-separated search directories.
    runpath: []const []const u8,
    /// Legacy DT_RPATH values, in the same format as RUNPATH.
    rpath: []const []const u8,
    /// PT_INTERP loader paths; empty when no program interpreter is declared.
    interp: []const []const u8,
    /// GNU x86 ISA-needed bitmask; optional ISA-used properties are excluded.
    isa: u32,
    /// DT_SONAME names declared by the file.
    soname: []const []const u8,
    /// ELF32 or ELF64, using the standard ELF class enumeration.
    class: elf.CLASS,
    /// Target machine architecture from the ELF header.
    machine: elf.EM,
    /// Byte order used to decode the file's integer fields.
    endian: std.builtin.Endian,
    /// Dependency library names mapped to their required symbol-version names.
    needed_versions: std.StringArrayHashMapUnmanaged([]const []const u8),
    /// Symbol-version names defined by this file.
    defined_versions: []const []const u8,

    /// Keeps the audit report's version map as a JSON object rather than map internals.
    pub fn jsonStringify(self: Metadata, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        inline for (.{ "needed", "runpath", "rpath", "interp", "isa", "soname", "class", "machine", "endian", "defined_versions" }) |field| {
            try jw.objectField(field);
            try jw.write(@field(self, field));
        }
        try jw.objectField("needed_versions");
        try jw.beginObject();
        for (self.needed_versions.keys(), self.needed_versions.values()) |name, versions| {
            try jw.objectField(name);
            try jw.write(versions);
        }
        try jw.endObject();
        try jw.endObject();
    }
};

/// GNU_PROPERTY_X86_ISA_1_BASELINE from the x86 ELF ABI.
pub const X86_ISA_BASELINE: u32 = 1;
const GNU_PROPERTY_X86_ISA_1_NEEDED = 0xc0008002;
const NT_GNU_PROPERTY_TYPE_0 = 5;
const PT_GNU_PROPERTY: elf.PT = @fromBackingInt(@intCast(0x6474e553));

fn stringAt(allocator: std.mem.Allocator, strings: []const u8, offset: u64) ![]const u8 {
    if (offset >= strings.len) return error.InvalidElf;
    const tail = strings[@intCast(offset)..];
    return allocator.dupe(u8, tail[0 .. std.mem.indexOfScalar(u8, tail, 0) orelse return error.InvalidElf]);
}

fn readEndian(comptime T: type, bytes: []const u8, offset: u64, endian: std.builtin.Endian) !T {
    var reader: std.Io.Reader = .fixed(try region(bytes, offset, @sizeOf(T)));
    return reader.takeStruct(T, endian) catch return error.InvalidElf;
}

fn virtualTail(bytes: []const u8, phdrs: []const Phdr, address: u64) ![]const u8 {
    for (phdrs) |p| {
        if (p.type != .LOAD or address < p.vaddr) continue;
        const delta = address - p.vaddr;
        if (delta < p.filesz) return region(bytes, try plus(p.offset, delta), p.filesz - delta);
    }
    return error.InvalidElf;
}

fn noteIsa(bytes: []const u8, header: elf.Header, alignment: u64) !u32 {
    var result: u32 = 0;
    var offset: u64 = 0;
    while (offset < bytes.len) {
        const note = try readEndian(elf.Elf64_Nhdr, bytes, offset, header.endian);
        const name_offset = try plus(offset, @sizeOf(elf.Elf64_Nhdr));
        const name = try region(bytes, name_offset, note.n_namesz);
        const desc_offset = try aligned(try plus(name_offset, note.n_namesz), alignment);
        const desc = try region(bytes, desc_offset, note.n_descsz);
        offset = try aligned(try plus(desc_offset, note.n_descsz), alignment);
        if (offset > bytes.len) return error.InvalidElf;
        if (note.n_type != NT_GNU_PROPERTY_TYPE_0 or !std.mem.eql(u8, name, "GNU\x00")) continue;
        if (header.machine != .X86_64 and header.machine != .@"386") continue;
        var property: u64 = 0;
        while (property < desc.len) {
            var reader: std.Io.Reader = .fixed(try region(desc, property, 8));
            const kind = reader.takeInt(u32, header.endian) catch return error.InvalidElf;
            const size = reader.takeInt(u32, header.endian) catch return error.InvalidElf;
            const data = try region(desc, try plus(property, 8), size);
            if (kind == GNU_PROPERTY_X86_ISA_1_NEEDED) {
                if (data.len != 4) return error.InvalidElf;
                result |= std.mem.readInt(u32, data[0..4], header.endian);
            }
            property = try aligned(try plus(try plus(property, 8), size), if (header.is_64) 8 else 4);
            if (property > desc.len) return error.InvalidElf;
        }
    }
    return result;
}

fn versionNeeds(allocator: std.mem.Allocator, bytes: []const u8, strings: []const u8, count: u64, endian: std.builtin.Endian, needs: *std.StringArrayHashMapUnmanaged([]const []const u8)) !void {
    if (count > bytes.len / @sizeOf(elf.Verneed)) return error.InvalidElf;
    var offset: u64 = 0;
    for (0..@intCast(count)) |index| {
        const need = try readEndian(elf.Verneed, bytes, offset, endian);
        if (need.version != 1 or need.cnt == 0 or need.aux < @sizeOf(elf.Verneed)) return error.InvalidElf;
        const name = try stringAt(allocator, strings, need.file);
        var versions: std.array_list.Managed([]const u8) = .init(allocator);
        if (needs.get(name)) |previous| try versions.appendSlice(previous);
        var aux = try plus(offset, need.aux);
        if (need.cnt > bytes.len / @sizeOf(elf.Vernaux)) return error.InvalidElf;
        for (0..need.cnt) |aux_index| {
            const entry = try readEndian(elf.Vernaux, bytes, aux, endian);
            try versions.append(try stringAt(allocator, strings, entry.name));
            if (aux_index + 1 < need.cnt) {
                if (entry.next < @sizeOf(elf.Vernaux)) return error.InvalidElf;
                aux = try plus(aux, entry.next);
            } else if (entry.next != 0) return error.InvalidElf;
        }
        if (needs.get(name)) |previous| allocator.free(previous);
        try needs.put(allocator, name, try versions.toOwnedSlice());
        if (index + 1 < count) {
            if (need.next < @sizeOf(elf.Verneed)) return error.InvalidElf;
            offset = try plus(offset, need.next);
        } else if (need.next != 0) return error.InvalidElf;
    }
}

fn versionDefinitions(allocator: std.mem.Allocator, bytes: []const u8, strings: []const u8, count: u64, endian: std.builtin.Endian, defines: *std.array_list.Managed([]const u8)) !void {
    if (count > bytes.len / @sizeOf(elf.Verdef)) return error.InvalidElf;
    var offset: u64 = 0;
    for (0..@intCast(count)) |index| {
        const def = try readEndian(elf.Verdef, bytes, offset, endian);
        if (def.version != 1 or def.cnt == 0 or def.aux < @sizeOf(elf.Verdef)) return error.InvalidElf;
        var aux = try plus(offset, def.aux);
        if (def.cnt > bytes.len / @sizeOf(elf.Verdaux)) return error.InvalidElf;
        for (0..def.cnt) |aux_index| {
            const entry = try readEndian(elf.Verdaux, bytes, aux, endian);
            const name = try stringAt(allocator, strings, entry.name);
            // Further auxiliary entries name parents, not additional definitions.
            if (aux_index == 0) try defines.append(name);
            if (aux_index + 1 < def.cnt) {
                if (entry.next < @sizeOf(elf.Verdaux)) return error.InvalidElf;
                aux = try plus(aux, entry.next);
            } else if (entry.next != 0) return error.InvalidElf;
        }
        if (index + 1 < count) {
            if (def.next < @sizeOf(elf.Verdef)) return error.InvalidElf;
            offset = try plus(offset, def.next);
        } else if (def.next != 0) return error.InvalidElf;
    }
}

/// Parses ELF32/ELF64 in either byte order, including files without section headers.
/// Returned strings and collections use `allocator` (normally an arena); `bytes` may be freed afterward.
pub fn metadataBytes(allocator: std.mem.Allocator, bytes: []const u8) !Metadata {
    // Header.read peeks an ELF64-sized buffer even for the smaller ELF32 header.
    var prefix: [@sizeOf(elf.Elf64_Ehdr)]u8 = @splat(0);
    const prefix_len = @min(bytes.len, prefix.len);
    @memcpy(prefix[0..prefix_len], bytes[0..prefix_len]);
    var reader: std.Io.Reader = .fixed(&prefix);
    const header = elf.Header.read(&reader) catch return error.InvalidElf;
    _ = try region(bytes, 0, if (header.is_64) @sizeOf(elf.Elf64_Ehdr) else @sizeOf(elf.Elf32_Ehdr));
    // The std.elf iterators use 16-bit counts and cannot represent extended numbering.
    if (header.phnum == 0xffff or (header.shnum == 0 and header.shoff != 0)) return error.UnsupportedElf;
    const phsize: u64 = if (header.is_64) @sizeOf(elf.Elf64.Phdr) else @sizeOf(elf.Elf32.Phdr);
    if (header.phnum != 0 and header.phentsize != phsize) return error.InvalidElf;
    _ = try region(bytes, header.phoff, phsize * header.phnum);
    var phdrs: std.array_list.Managed(Phdr) = .init(allocator);
    defer phdrs.deinit();
    var programs = header.iterateProgramHeadersBuffer(bytes);
    var dynamic: ?Phdr = null;
    var interp: std.array_list.Managed([]const u8) = .init(allocator);
    var isa: u32 = 0;
    while (programs.next() catch return error.InvalidElf) |p| {
        try phdrs.append(p);
        switch (p.type) {
            .LOAD => {
                if (p.filesz > p.memsz) return error.InvalidElf;
                _ = try region(bytes, p.offset, p.filesz);
            },
            .DYNAMIC => {
                if (dynamic != null) return error.InvalidElf;
                _ = try region(bytes, p.offset, p.filesz);
                dynamic = p;
            },
            .INTERP => try interp.append(try stringAt(allocator, try region(bytes, p.offset, p.filesz), 0)),
            .NOTE, PT_GNU_PROPERTY => isa |= try noteIsa(try region(bytes, p.offset, p.filesz), header, if (p.@"align" == 8) 8 else 4),
            else => {},
        }
    }
    if (header.shnum != 0) {
        const shsize: u64 = if (header.is_64) @sizeOf(elf.Elf64_Shdr) else @sizeOf(elf.Elf32_Shdr);
        if (header.shentsize != shsize) return error.InvalidElf;
        _ = try region(bytes, header.shoff, shsize * header.shnum);
        var sections = header.iterateSectionHeadersBuffer(bytes);
        while (sections.next() catch return error.InvalidElf) |s| {
            if (s.sh_type == elf.SHT_NOTE)
                isa |= try noteIsa(try region(bytes, s.sh_offset, s.sh_size), header, if (s.sh_addralign == 8) 8 else 4);
        }
    }
    var entries: std.array_list.Managed(Dyn) = .init(allocator);
    defer entries.deinit();
    var strtab: ?u64 = null;
    var strsz: ?u64 = null;
    var verneed: ?u64 = null;
    var verneednum: u64 = 0;
    var verdef: ?u64 = null;
    var verdefnum: u64 = 0;
    if (dynamic) |p| {
        const entry_size: u64 = if (header.is_64) @sizeOf(elf.Elf64_Dyn) else @sizeOf(elf.Elf32_Dyn);
        // A segment may include linker padding after the complete DT_NULL.
        // Inspect only complete entries and still require a full terminator;
        // never decode a partial entry or treat a truncated table as terminated.
        var dynamics = header.iterateDynamicSectionBuffer(bytes, p.offset, p.filesz - p.filesz % entry_size);
        var terminated = false;
        while (dynamics.next() catch return error.InvalidElf) |d| {
            if (d.d_tag == elf.DT_NULL) {
                terminated = true;
                break;
            }
            try entries.append(d);
            switch (d.d_tag) {
                elf.DT_STRTAB => strtab = d.d_val,
                elf.DT_STRSZ => strsz = d.d_val,
                elf.DT_VERNEED => verneed = d.d_val,
                elf.DT_VERNEEDNUM => verneednum = d.d_val,
                elf.DT_VERDEF => verdef = d.d_val,
                elf.DT_VERDEFNUM => verdefnum = d.d_val,
                else => {},
            }
        }
        if (!terminated) return error.InvalidElf;
    }
    var strings: []const u8 = &.{};
    if (strtab) |address| {
        const size = strsz orelse return error.InvalidElf;
        strings = try region(bytes, try fileOffset(phdrs.items, address, size), size);
    } else if (strsz != null) return error.InvalidElf;
    var needed: std.array_list.Managed([]const u8) = .init(allocator);
    var runpath: std.array_list.Managed([]const u8) = .init(allocator);
    var rpath: std.array_list.Managed([]const u8) = .init(allocator);
    var soname: std.array_list.Managed([]const u8) = .init(allocator);
    for (entries.items) |d| switch (d.d_tag) {
        elf.DT_NEEDED => try needed.append(try stringAt(allocator, strings, d.d_val)),
        elf.DT_RUNPATH => try runpath.append(try stringAt(allocator, strings, d.d_val)),
        elf.DT_RPATH => try rpath.append(try stringAt(allocator, strings, d.d_val)),
        elf.DT_SONAME => try soname.append(try stringAt(allocator, strings, d.d_val)),
        else => {},
    };
    var needs: std.StringArrayHashMapUnmanaged([]const []const u8) = .empty;
    var defines: std.array_list.Managed([]const u8) = .init(allocator);
    if ((verneed == null) != (verneednum == 0) or (verdef == null) != (verdefnum == 0)) return error.InvalidElf;
    if (verneed) |address| try versionNeeds(allocator, try virtualTail(bytes, phdrs.items, address), strings, verneednum, header.endian, &needs);
    if (verdef) |address| try versionDefinitions(allocator, try virtualTail(bytes, phdrs.items, address), strings, verdefnum, header.endian, &defines);

    return .{
        .needed = try needed.toOwnedSlice(),
        .runpath = try runpath.toOwnedSlice(),
        .rpath = try rpath.toOwnedSlice(),
        .interp = try interp.toOwnedSlice(),
        .isa = isa,
        .soname = try soname.toOwnedSlice(),
        .class = if (header.is_64) .@"64" else .@"32",
        .machine = header.machine,
        .endian = header.endian,
        .needed_versions = needs,
        .defined_versions = try defines.toOwnedSlice(),
    };
}

/// Reads an ELF file natively without external tools, releasing the temporary file buffer.
/// Only parsed strings and collections are retained in `allocator` (normally an arena).
pub fn metadata(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Metadata {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(1024 * 1024 * 1024));
    defer std.heap.page_allocator.free(bytes);
    return metadataBytes(allocator, bytes);
}

fn region(bytes: []const u8, offset: u64, size: u64) ![]const u8 {
    const start = std.math.cast(usize, offset) orelse return error.InvalidElf;
    const length = std.math.cast(usize, size) orelse return error.InvalidElf;
    if (start > bytes.len or length > bytes.len - start) return error.InvalidElf;
    return bytes[start..][0..length];
}

fn read(comptime T: type, bytes: []const u8, offset: u64) !T {
    const slice = try region(bytes, offset, @sizeOf(T));
    return std.mem.bytesToValue(T, slice[0..@sizeOf(T)]);
}

fn write(comptime T: type, bytes: []u8, offset: u64, value: T) !void {
    @memcpy(@constCast(try region(bytes, offset, @sizeOf(T))), std.mem.asBytes(&value));
}

fn plus(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b) catch error.InvalidElf;
}

fn aligned(value: u64, alignment: u64) !u64 {
    return (try plus(value, alignment - 1)) & ~(alignment - 1);
}

fn fileOffset(phdrs: []const Phdr, address: u64, size: u64) !u64 {
    for (phdrs) |p| {
        if (p.type != .LOAD or address < p.vaddr) continue;
        const delta = address - p.vaddr;
        if (delta <= p.filesz and size <= p.filesz - delta) return plus(p.offset, delta);
    }
    return error.InvalidElf;
}

fn testImage(allocator: std.mem.Allocator, spare_dynamic_slots: bool) ![]u8 {
    const bytes = try allocator.alloc(u8, 4096);
    @memset(bytes, 0);
    var header: Ehdr = std.mem.zeroes(Ehdr);
    header.ident.magic = elf.MAGIC.*;
    header.ident.class = .@"64";
    header.ident.data = .@"2LSB";
    header.ident.version = 1;
    header.type = .DYN;
    header.machine = .X86_64;
    header.version = 1;
    header.ehsize = @sizeOf(Ehdr);
    header.phoff = @sizeOf(Ehdr);
    header.phentsize = @sizeOf(Phdr);
    header.phnum = 4;
    try write(Ehdr, bytes, 0, header);
    const load: Phdr = .{
        .type = .LOAD,
        .flags = .{ .R = true, .W = true },
        .offset = 0,
        .vaddr = 0,
        .paddr = 0,
        .filesz = bytes.len,
        .memsz = 6144,
        .@"align" = 4096,
    };
    var interp = load;
    interp.type = .INTERP;
    interp.offset = 512;
    interp.vaddr = 512;
    interp.filesz = 7;
    interp.memsz = 7;
    interp.@"align" = 1;
    var dyn = load;
    dyn.type = .DYNAMIC;
    dyn.offset = 768;
    dyn.vaddr = 768;
    dyn.filesz = (if (spare_dynamic_slots) @as(u64, 8) else 4) * @sizeOf(Dyn);
    dyn.memsz = dyn.filesz;
    dyn.@"align" = 8;
    var relro = dyn;
    relro.type = elf.PT.GNU_RELRO;
    for ([_]Phdr{ interp, load, dyn, relro }, 0..) |p, index|
        try write(Phdr, bytes, header.phoff + index * @sizeOf(Phdr), p);
    @memcpy(bytes[512..][0..7], "/ld.so\x00");
    const strings = "\x00libc.so.6\x00";
    @memcpy(bytes[1024..][0..strings.len], strings);
    const tags = [_]Dyn{
        .{ .d_tag = elf.DT_STRTAB, .d_val = 1024 },
        .{ .d_tag = elf.DT_STRSZ, .d_val = strings.len },
        .{ .d_tag = elf.DT_NEEDED, .d_val = 1 },
        .{ .d_tag = elf.DT_NULL, .d_val = 0 },
    };
    for (tags, 0..) |d, index| try write(Dyn, bytes, dyn.offset + index * @sizeOf(Dyn), d);
    @memcpy(bytes[2048..][0..13], "code-sentinel");
    return bytes;
}

fn testMetadataImage(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try testImage(allocator, true);
    const strings = "\x00libanswer.so\x00$ORIGIN/../lib\x00legacy\x00fixture.so\x00V1\x00V2\x00";
    @memcpy(bytes[1024..][0..strings.len], strings);
    var header = try read(Ehdr, bytes, 0);
    header.phnum = 5;
    try write(Ehdr, bytes, 0, header);
    var dynamic = try read(Phdr, bytes, header.phoff + 2 * @sizeOf(Phdr));
    dynamic.filesz = 16 * @sizeOf(Dyn);
    dynamic.memsz = dynamic.filesz;
    try write(Phdr, bytes, header.phoff + 2 * @sizeOf(Phdr), dynamic);
    const entries = [_]Dyn{
        .{ .d_tag = elf.DT_STRTAB, .d_val = 1024 },
        .{ .d_tag = elf.DT_STRSZ, .d_val = strings.len },
        .{ .d_tag = elf.DT_NEEDED, .d_val = std.mem.indexOf(u8, strings, "libanswer.so").? },
        .{ .d_tag = elf.DT_RUNPATH, .d_val = std.mem.indexOf(u8, strings, "$ORIGIN").? },
        .{ .d_tag = elf.DT_RPATH, .d_val = std.mem.indexOf(u8, strings, "legacy").? },
        .{ .d_tag = elf.DT_SONAME, .d_val = std.mem.indexOf(u8, strings, "fixture.so").? },
        .{ .d_tag = elf.DT_VERNEED, .d_val = 1280 },
        .{ .d_tag = elf.DT_VERNEEDNUM, .d_val = 1 },
        .{ .d_tag = elf.DT_VERDEF, .d_val = 1344 },
        .{ .d_tag = elf.DT_VERDEFNUM, .d_val = 2 },
        .{ .d_tag = elf.DT_NULL, .d_val = 0 },
    };
    @memset(bytes[768..1024], 0);
    for (entries, 0..) |entry, index| try write(Dyn, bytes, 768 + index * @sizeOf(Dyn), entry);
    try write(elf.Verneed, bytes, 1280, .{
        .version = 1,
        .cnt = 1,
        .file = @intCast(std.mem.indexOf(u8, strings, "libanswer.so").?),
        .aux = @sizeOf(elf.Verneed),
        .next = 0,
    });
    try write(elf.Vernaux, bytes, 1296, .{
        .hash = 0,
        .flags = 0,
        .other = 1,
        .name = @intCast(std.mem.indexOf(u8, strings, "V1").?),
        .next = 0,
    });
    try write(elf.Verdef, bytes, 1344, .{
        .version = 1,
        .flags = 0,
        .ndx = .GLOBAL,
        .cnt = 1,
        .hash = 0,
        .aux = @sizeOf(elf.Verdef),
        .next = 28,
    });
    try write(elf.Verdaux, bytes, 1364, .{ .name = @intCast(std.mem.indexOf(u8, strings, "V1").?), .next = 0 });
    try write(elf.Verdef, bytes, 1372, .{
        .version = 1,
        .flags = 0,
        .ndx = .GLOBAL,
        .cnt = 2,
        .hash = 0,
        .aux = @sizeOf(elf.Verdef),
        .next = 0,
    });
    try write(elf.Verdaux, bytes, 1392, .{ .name = @intCast(std.mem.indexOf(u8, strings, "V2").?), .next = 8 });
    try write(elf.Verdaux, bytes, 1400, .{ .name = @intCast(std.mem.indexOf(u8, strings, "V1").?), .next = 0 });
    var note = try read(Phdr, bytes, header.phoff + @sizeOf(Phdr));
    note.type = .NOTE;
    note.offset = 1536;
    note.vaddr = 1536;
    note.filesz = 48;
    note.memsz = 48;
    note.@"align" = 8;
    try write(Phdr, bytes, header.phoff + 4 * @sizeOf(Phdr), note);
    try write(elf.Elf64_Nhdr, bytes, 1536, .{ .n_namesz = 4, .n_descsz = 32, .n_type = NT_GNU_PROPERTY_TYPE_0 });
    @memcpy(bytes[1548..1552], "GNU\x00");
    // ISA-used=v4 is optional; only ISA-needed=baseline may affect the audit.
    const properties = [_]u32{ 0xc0010002, 4, 8, 0, GNU_PROPERTY_X86_ISA_1_NEEDED, 4, X86_ISA_BASELINE, 0 };
    for (properties, 0..) |value, index| std.mem.writeInt(u32, bytes[1552 + index * 4 ..][0..4], value, .little);
    return bytes;
}

test "dynamic segment padding follows a complete terminator and cannot replace it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try testImage(a, false);
    const header = try read(Ehdr, bytes, 0);
    const location = header.phoff + 2 * @sizeOf(Phdr);
    var dynamic = try read(Phdr, bytes, location);
    dynamic.filesz += 7;
    dynamic.memsz = dynamic.filesz;
    try write(Phdr, bytes, location, dynamic);
    _ = try metadataBytes(a, bytes);
    // Truncate in the final DT_NULL: even a zero tag needs its complete entry.
    dynamic.filesz = 3 * @sizeOf(Dyn) + 7;
    dynamic.memsz = dynamic.filesz;
    try write(Phdr, bytes, location, dynamic);
    try std.testing.expectError(error.InvalidElf, metadataBytes(a, bytes));
}

test "native metadata resolves sectionless dynamic strings, symbol versions and required ISA" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = try testMetadataImage(allocator);
    const scratch = try allocator.dupe(u8, bytes);
    const meta = try metadataBytes(allocator, scratch);
    @memset(scratch, 0); // Metadata must own its strings independently of the input buffer.
    try std.testing.expectEqual(elf.CLASS.@"64", meta.class);
    try std.testing.expectEqual(elf.EM.X86_64, meta.machine);
    try std.testing.expectEqual(std.builtin.Endian.little, meta.endian);
    try std.testing.expectEqualStrings("libanswer.so", meta.needed[0]);
    try std.testing.expectEqualStrings("$ORIGIN/../lib", meta.runpath[0]);
    try std.testing.expectEqualStrings("legacy", meta.rpath[0]);
    try std.testing.expectEqualStrings("fixture.so", meta.soname[0]);
    try std.testing.expectEqualStrings("/ld.so", meta.interp[0]);
    try std.testing.expectEqual(X86_ISA_BASELINE, meta.isa);
    const required = meta.needed_versions.get("libanswer.so").?;
    try std.testing.expectEqual(@as(usize, 1), required.len);
    try std.testing.expectEqualStrings("V1", required[0]);
    try std.testing.expectEqual(@as(usize, 2), meta.defined_versions.len);
    try std.testing.expectEqualStrings("V1", meta.defined_versions[0]);
    try std.testing.expectEqualStrings("V2", meta.defined_versions[1]);
    const json = try std.json.Stringify.valueAlloc(allocator, meta, .{});
    const report = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    try std.testing.expectEqualStrings("V1", report.object.get("needed_versions").?.object.get("libanswer.so").?.array.items[0].string);
    std.mem.writeInt(u32, bytes[1576..1580], 4, .little);
    try std.testing.expectEqual(@as(u32, 4), (try metadataBytes(allocator, bytes)).isa);
}

fn testWriteEndian(bytes: []u8, offset: usize, value: anytype, endian: std.builtin.Endian) !void {
    var writer: std.Io.Writer = .fixed(bytes[offset..]);
    try writer.writeStruct(value, endian);
}

test "native metadata supports ELF32 and ELF64 byte orders and minimal static headers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        const bytes = try allocator.alloc(u8, 1024);
        @memset(bytes, 0);
        var header: elf.Elf32_Ehdr = std.mem.zeroes(elf.Elf32_Ehdr);
        @memcpy(header.e_ident[0..4], elf.MAGIC);
        header.e_ident[elf.EI.CLASS] = elf.ELFCLASS32;
        header.e_ident[elf.EI.DATA] = if (endian == .little) elf.ELFDATA2LSB else elf.ELFDATA2MSB;
        header.e_ident[elf.EI.VERSION] = 1;
        header.e_version = 1;
        header.e_type = .DYN;
        header.e_machine = .PPC;
        header.e_ehsize = @sizeOf(elf.Elf32_Ehdr);
        try testWriteEndian(bytes, 0, header, endian);
        const minimal = try metadataBytes(allocator, bytes[0..@sizeOf(elf.Elf32_Ehdr)]);
        try std.testing.expectEqual(@as(usize, 0), minimal.needed.len);
        header.e_phoff = @sizeOf(elf.Elf32_Ehdr);
        header.e_phentsize = @sizeOf(elf.Elf32.Phdr);
        header.e_phnum = 2;
        try testWriteEndian(bytes, 0, header, endian);
        var load: elf.Elf32.Phdr = std.mem.zeroes(elf.Elf32.Phdr);
        load.type = .LOAD;
        load.filesz = @intCast(bytes.len);
        load.memsz = @intCast(bytes.len);
        try testWriteEndian(bytes, header.e_phoff, load, endian);
        var dynamic = load;
        dynamic.type = .DYNAMIC;
        dynamic.offset = 256;
        dynamic.filesz = 4 * @sizeOf(elf.Elf32_Dyn);
        dynamic.memsz = dynamic.filesz;
        try testWriteEndian(bytes, header.e_phoff + @sizeOf(elf.Elf32.Phdr), dynamic, endian);
        const strings = "\x00lib32.so\x00";
        @memcpy(bytes[512..][0..strings.len], strings);
        const entries = [_]elf.Elf32_Dyn{
            .{ .d_tag = elf.DT_STRTAB, .d_val = 512 },
            .{ .d_tag = elf.DT_STRSZ, .d_val = strings.len },
            .{ .d_tag = elf.DT_NEEDED, .d_val = 1 },
            .{ .d_tag = elf.DT_NULL, .d_val = 0 },
        };
        for (entries, 0..) |entry, index| try testWriteEndian(bytes, 256 + index * @sizeOf(elf.Elf32_Dyn), entry, endian);
        const meta = try metadataBytes(allocator, bytes);
        try std.testing.expectEqual(elf.CLASS.@"32", meta.class);
        try std.testing.expectEqual(elf.EM.PPC, meta.machine);
        try std.testing.expectEqual(endian, meta.endian);
        try std.testing.expectEqualStrings("lib32.so", meta.needed[0]);
    }
    const bytes = try testMetadataImage(allocator);
    var header = try read(elf.Elf64_Ehdr, bytes, 0);
    header.e_ident[elf.EI.DATA] = elf.ELFDATA2MSB;
    header.e_machine = .PPC64;
    try testWriteEndian(bytes, 0, header, .big);
    for (0..header.e_phnum) |index| {
        const offset = header.e_phoff + index * @sizeOf(Phdr);
        try testWriteEndian(bytes, offset, try read(Phdr, bytes, offset), .big);
    }
    for (0..16) |index| {
        const offset = 768 + index * @sizeOf(Dyn);
        try testWriteEndian(bytes, offset, try read(Dyn, bytes, offset), .big);
    }
    try testWriteEndian(bytes, 1280, try read(elf.Verneed, bytes, 1280), .big);
    try testWriteEndian(bytes, 1296, try read(elf.Vernaux, bytes, 1296), .big);
    for ([_]usize{ 1344, 1372 }) |offset|
        try testWriteEndian(bytes, offset, try read(elf.Verdef, bytes, offset), .big);
    for ([_]usize{ 1364, 1392, 1400 }) |offset|
        try testWriteEndian(bytes, offset, try read(elf.Verdaux, bytes, offset), .big);
    try testWriteEndian(bytes, 1536, try read(elf.Elf64_Nhdr, bytes, 1536), .big);
    const meta = try metadataBytes(allocator, bytes);
    try std.testing.expectEqual(elf.CLASS.@"64", meta.class);
    try std.testing.expectEqual(elf.EM.PPC64, meta.machine);
    try std.testing.expectEqual(std.builtin.Endian.big, meta.endian);
    try std.testing.expectEqualStrings("libanswer.so", meta.needed[0]);
    try std.testing.expectEqualStrings("V1", meta.needed_versions.get("libanswer.so").?[0]);
    try std.testing.expectEqualStrings("V2", meta.defined_versions[1]);
}

test "native metadata rejects out-of-bounds tables, unterminated strings and malformed version and property records" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try testMetadataImage(allocator);
    for ([_]usize{ 0, 4, 63, 256, 1024 }) |length|
        try std.testing.expectError(error.InvalidElf, metadataBytes(allocator, original[0..length]));
    const bytes = try allocator.dupe(u8, original);
    var header = try read(Ehdr, bytes, 0);
    header.phoff = std.math.maxInt(u64);
    try write(Ehdr, bytes, 0, header);
    try std.testing.expectError(error.InvalidElf, metadataBytes(allocator, bytes));
    @memcpy(bytes, original);
    try write(Dyn, bytes, 768, .{ .d_tag = elf.DT_STRTAB, .d_val = std.math.maxInt(u64) });
    try std.testing.expectError(error.InvalidElf, metadataBytes(allocator, bytes));
    @memcpy(bytes, original);
    // The required version's final NUL lies just outside DT_STRSZ.
    const strings = "\x00libanswer.so\x00$ORIGIN/../lib\x00legacy\x00fixture.so\x00V1\x00V2\x00";
    try write(Dyn, bytes, 768 + @sizeOf(Dyn), .{ .d_tag = elf.DT_STRSZ, .d_val = strings.len - 1 });
    try std.testing.expectError(error.InvalidElf, metadataBytes(allocator, bytes));
    @memcpy(bytes, original);
    var need = try read(elf.Verneed, bytes, 1280);
    need.cnt = 2; // The first auxiliary entry has next=0, so the chain is truncated.
    try write(elf.Verneed, bytes, 1280, need);
    try std.testing.expectError(error.InvalidElf, metadataBytes(allocator, bytes));
    @memcpy(bytes, original);
    std.mem.writeInt(u32, bytes[1572..1576], 8, .little); // ISA-needed must contain exactly one word.
    try std.testing.expectError(error.InvalidElf, metadataBytes(allocator, bytes));
    @memcpy(bytes, original);
    for (0..16) |index| try write(Dyn, bytes, 768 + index * @sizeOf(Dyn), .{ .d_tag = elf.DT_NEEDED, .d_val = 1 });
    try std.testing.expectError(error.InvalidElf, metadataBytes(allocator, bytes));
}
