//! Consumes an attested pizza-bundle release and adds this checkout's application.
const std = @import("std");

pub fn add(b: *std.Build, tool: *std.Build.Step.Compile, init_binary: *std.Build.Step.Compile, maintenance: std.Build.LazyPath) *std.Build.Step {
    const fetch = b.addRunArtifact(tool);
    fetch.addArgs(&.{ "fetch-bundle", "--lock" });
    fetch.setCwd(b.path("."));
    fetch.addFileArg(b.path("config/bundle/release.json"));
    fetch.addArg("--destination");
    const downloaded_runtime = fetch.addOutputDirectoryArg2("runtime", .{});
    const candidate = b.option([]const u8, "candidate-runtime", "Explicit local CI runtime candidate directory (not a downloaded release)");
    const runtime: std.Build.LazyPath = if (candidate) |path| .{ .cwd_relative = path } else downloaded_runtime;
    const runtime_step = b.step("runtime-deps", "Download and verify the pinned pizza-bundle release");
    runtime_step.dependOn(&fetch.step);
    runtime_step.dependOn(&b.addInstallDirectory(.{ .source_dir = downloaded_runtime, .install_dir = .prefix, .install_subdir = "runtime/dependencies" }).step);
    const prepare = b.addRunArtifact(tool);
    prepare.setCwd(b.path("."));
    prepare.addArgs(&.{ "prepare-bundle", "--runtime" });
    prepare.addDirectoryArg2(runtime, .{});
    if (candidate != null) prepare.addArg("--candidate-runtime");
    prepare.addArg("--init");
    prepare.addArtifactArg(init_binary);
    prepare.addArg("--maintenance");
    prepare.addFileArg(maintenance);
    prepare.addArg("--destination");
    const directory = prepare.addOutputDirectoryArg2("bundle", .{});
    prepare.addFileInput(b.path("config/bundle/release.json"));
    const pack = b.addRunArtifact(tool);
    pack.setCwd(b.path("."));
    pack.addArgs(&.{ "pack-bundle", "--bundle" });
    pack.addDirectoryArg2(directory, .{});
    pack.addArg("--output");
    const archive = pack.addOutputFileArg2("bundle.tar.gz", .{});
    const step = b.step("bundle", "Assemble Pizza with the verified runtime release");
    step.dependOn(&b.addInstallFileWithDir(archive, .prefix, "share/pizza/bundle.tar.gz").step);
    const copy = b.addSystemCommand(&.{ "cp", "-a" });
    copy.addDirectoryArg2(directory, .{});
    copy.addDirectoryArg2(b.graph.path(.install_prefix, "runtime/bundle"), .{});
    // Replace the previously installed tree, never merge stale dependency files.
    const remove = b.addSystemCommand(&.{ "rm", "-rf" });
    remove.addDirectoryArg2(b.graph.path(.install_prefix, "runtime/bundle"), .{});
    remove.step.dependOn(&pack.step);
    const parent = b.addSystemCommand(&.{ "mkdir", "-p" });
    parent.addDirectoryArg2(b.graph.path(.install_prefix, "runtime"), .{});
    parent.step.dependOn(&remove.step);
    copy.step.dependOn(&parent.step);
    step.dependOn(&copy.step);
    const image = b.addRunArtifact(tool);
    image.setCwd(b.path("."));
    image.addArgs(&.{ "image", "--bundle" });
    image.addDirectoryArg2(directory, .{});
    if (candidate != null) image.addArg("--candidate-runtime");
    image.addArg("--output");
    const image_file = image.addOutputFileArg2("maint.img", .{});
    const image_step = b.step("image", "Append Pizza to the attested base initramfs");
    image_step.dependOn(&b.addInstallFileWithDir(image_file, .prefix, "share/pizza/maint.img").step);
    image_step.dependOn(&b.addInstallFileWithDir(image_file.dirname().path(b, "maint.img.pizza.json"), .prefix, "share/pizza/maint.img.pizza.json").step);
    image_step.dependOn(&b.addInstallFileWithDir(directory.path(b, "vmlinuz"), .prefix, "share/pizza/vmlinuz").step);
    const uki = b.addRunArtifact(tool);
    uki.setCwd(b.path("."));
    uki.addArgs(&.{ "image", "--bundle" });
    uki.addDirectoryArg2(directory, .{});
    if (candidate != null) uki.addArg("--candidate-runtime");
    uki.addArg("--output");
    _ = uki.addOutputFileArg2("maint.img", .{});
    uki.addArg("--uki-output");
    const uki_file = uki.addOutputFileArg2("maint.efi", .{});
    if (b.option([]const u8, "ukify", "systemd ukify executable")) |value| uki.addArgs(&.{ "--ukify", value });
    if (b.option([]const u8, "uki-stub", "Explicit x86-64 systemd EFI stub")) |value| {
        uki.addArg("--stub");
        uki.addFileArg(.{ .cwd_relative = value });
    }
    const uki_step = b.step("uki", "Build a verified block-aligned maintenance UKI");
    uki_step.dependOn(&b.addInstallFileWithDir(uki_file, .prefix, "share/pizza/maint.efi").step);
    uki_step.dependOn(&b.addInstallFileWithDir(uki_file.dirname().path(b, "maint.efi.pizza.json"), .prefix, "share/pizza/maint.efi.pizza.json").step);
    return step;
}
