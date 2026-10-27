const std = @import("std");

/// The platforms a release ships for. Linux builds link musl statically, so one binary runs on
/// any distribution.
const release_targets = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "linux-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "macos-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .name = "macos-aarch64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The release workflow passes the version it is about to tag; any other build is a dev build.
    const version = b.option([]const u8, "version", "The version commit-notes --version reports, as a release sets it") orelse "dev";
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{ .name = "commit-notes", .root_module = module(b, target, optimize, build_info) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run commit-notes").dependOn(&run.step);

    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src") }, .check = true });
    const test_step = b.step("test", "Check formatting and run the unit tests");
    test_step.dependOn(&fmt.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module(b, target, optimize, build_info) })).step);

    const only = b.option([]const u8, "platform", "Build only this release platform, such as linux-x86_64; the release workflow builds each on its own runner");
    const release = b.step("release", "Build every released platform into zig-out/release");
    for (release_targets) |platform| {
        if (only) |name| if (!std.mem.eql(u8, name, platform.name)) continue;
        const release_target = b.resolveTargetQuery(platform.query);
        const binary = b.addExecutable(.{ .name = "commit-notes", .root_module = module(b, release_target, .ReleaseSafe, build_info) });
        binary.root_module.strip = true;
        release.dependOn(&b.addInstallArtifact(binary, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
            .dest_sub_path = b.fmt("commit-notes-{s}{s}", .{ platform.name, release_target.result.exeFileExt() }),
            .pdb_dir = .disabled,
        }).step);
    }
    if (only) |name| if (release.dependencies.items.len != 1) std.debug.panic("-Dplatform={s} matches no release platform; name one from release_targets, such as linux-x86_64", .{name});
}

fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, build_info: *std.Build.Step.Options) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zclig", .module = b.dependency("zclig", .{ .target = target, .optimize = optimize }).module("zclig") }},
    });
    mod.addOptions("build_info", build_info);
    return mod;
}
