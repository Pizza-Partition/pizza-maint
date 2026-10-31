//! Generate the read-only libntfs runtime ABI; no CLI algorithms are embedded.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.InvalidArguments;
    try std.Io.Dir.cwd().createDirPath(init.io, args[1]);
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer dir.close(init.io);
    try dir.writeFile(init.io, .{ .sub_path = "pizza-runtime.h", .data = RUNTIME_HEADER });
    try dir.writeFile(init.io, .{ .sub_path = "runtime.c", .data = try std.mem.concat(a, u8, &.{ RUNTIME, "\n", DEVICE_RUNTIME }) });
}
const RUNTIME_HEADER =
    \\#include <setjmp.h>
    \\#include <stdio.h>
    \\#include <stdarg.h>
    \\extern jmp_buf pizza_ntfs_jump;
    \\int pizza_ntfs_print(const char *, ...);
    \\int pizza_ntfs_fprint(FILE *, const char *, ...);
    \\int pizza_ntfs_vprint(FILE *, const char *, va_list);
;
const RUNTIME =
    \\#include "pizza-runtime.h"
    \\#include <errno.h>
    \\#include <stdlib.h>
    \\#include "volume.h"
    \\#include "device_io.h"
    \\#include "logfile.h"
    \\#include "logging.h"
    \\jmp_buf pizza_ntfs_jump;
    \\__attribute__((noreturn)) void pizza_ntfs_exit(int status) { longjmp(pizza_ntfs_jump, 1); }
    \\int pizza_ntfs_print(const char *format, ...) { return 0; }
    \\int pizza_ntfs_fprint(FILE *stream, const char *format, ...) { return 0; }
    \\int pizza_ntfs_vprint(FILE *stream, const char *format, va_list ap) { return 0; }
    \\ntfs_volume *pizza_ntfs_mount_core(int writable) {
    \\    struct ntfs_device *dev;
    \\    if (setjmp(pizza_ntfs_jump)) return NULL;
    \\    ntfs_log_set_handler(ntfs_log_handler_null);
    \\    dev = ntfs_device_alloc("pizza:ntfs", 0, &ntfs_device_default_io_ops, NULL);
    \\    if (!dev) return NULL;
    \\    return ntfs_device_mount(dev, NTFS_MNT_FORENSIC | (writable ? 0 : NTFS_MNT_RDONLY));
    \\}
    \\int pizza_ntfs_close_core(ntfs_volume *vol) {
    \\    if (setjmp(pizza_ntfs_jump)) return -1;
    \\    return ntfs_umount(vol, 0);
    \\}
    \\int pizza_ntfs_health_core(ntfs_volume *vol) {
    \\    ntfs_inode *ni; ntfs_attr *na; RESTART_PAGE_HEADER *rp = NULL;
    \\    int result = -1;
    \\    if (setjmp(pizza_ntfs_jump)) return -1;
    \\    if (ntfs_volume_check_hiberfile(vol, 0)) return -2;
    \\    ni = ntfs_inode_open(vol, FILE_LogFile);
    \\    if (!ni) return -1;
    \\    na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    \\    if (na && ntfs_check_logfile(na, &rp) && ntfs_is_logfile_clean(na, rp)
    \\        && !(rp && rp->major_ver == const_cpu_to_le16(2))) result = 0;
    \\    if (na) ntfs_attr_close(na);
    \\    ntfs_inode_close(ni);
    \\    return result;
    \\}
    \\int pizza_ntfs_restore_flags_core(ntfs_volume *vol, unsigned short flags) {
    \\    if (setjmp(pizza_ntfs_jump)) return -1;
    \\    return ntfs_volume_write_flags(vol, flags);
    \\}
;

const DEVICE_RUNTIME =
    \\#include <sys/stat.h>
    \\#include <linux/fs.h>
    \\#include <linux/hdreg.h>
    \\#include <string.h>
    \\extern unsigned long long pizza_ntfs_capacity(void);
    \\extern unsigned int pizza_ntfs_sector(void);
    \\int pizza_ntfs_stat(struct ntfs_device *dev, struct stat *st) {
    \\    memset(st, 0, sizeof(*st)); st->st_mode = S_IFBLK | 0600;
    \\    st->st_size = pizza_ntfs_capacity(); st->st_blocks = st->st_size / 512;
    \\    st->st_blksize = pizza_ntfs_sector(); return 0;
    \\}
    \\int pizza_ntfs_ioctl(struct ntfs_device *dev, unsigned long request, void *arg) {
    \\    if (!arg) { errno = EINVAL; return -1; }
    \\    switch (request) {
    \\    case BLKGETSIZE64: *(unsigned long long*)arg = pizza_ntfs_capacity(); return 0;
    \\    case BLKGETSIZE: *(unsigned long*)arg = pizza_ntfs_capacity() / 512; return 0;
    \\    case BLKSSZGET: *(int*)arg = pizza_ntfs_sector(); return 0;
    \\    case BLKBSZSET: return 0;
    \\    case HDIO_GETGEO: { struct hd_geometry *g = arg; memset(g, 0, sizeof(*g)); g->heads = 255; g->sectors = 63; return 0; }
    \\    default: errno = EOPNOTSUPP; return -1;
    \\    }
    \\}
;
