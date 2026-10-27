//! Writes GitHub release notes from the commit messages since the previous release tag.
const std = @import("std");
const cli = @import("zclig");
const build_info = @import("build_info");
const notes = @import("notes.zig");
const eql = std.mem.eql;

const State = struct { io: std.Io };
fn state(ctx: *cli.Context) *State {
    return @ptrCast(@alignCast(ctx.runtime.user_data.?));
}
const WriteOptions = struct { tags: []const []const u8, pattern: []const u8 = "v[0-9]*", repo: ?[]const u8 = null };
const BackfillOptions = struct { pattern: []const u8 = "v[0-9]*", repo: ?[]const u8 = null };
const Release = struct { tag: []const u8, since: ?[]const u8, action: []const u8, notes: []const u8 };

fn toolFailure(ctx: *cli.Context, argv: []const []const u8, detail: []const u8) error{UserFailure} {
    const message = std.fmt.allocPrint(ctx.allocator, "{s} {s} failed: {s}", .{ argv[0], argv[1], std.mem.trim(u8, detail, " \n") }) catch "A git or gh command failed.";
    return ctx.fail(.failure, message, if (eql(u8, argv[0], "git"))
        "Run commit-notes in a clone with full history and tags; in GitHub Actions, check out with fetch-depth: 0."
    else
        "Check that gh is signed in (gh auth status), or set GH_TOKEN to a token that can write releases.");
}
fn run(ctx: *cli.Context, argv: []const []const u8) ![]const u8 {
    const result = std.process.run(ctx.allocator, state(ctx).io, .{ .argv = argv, .stdout_limit = .limited(64 << 20), .stderr_limit = .limited(1 << 20) }) catch |err|
        return toolFailure(ctx, argv, @errorName(err));
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    return toolFailure(ctx, argv, result.stderr);
}
fn lines(ctx: *cli.Context, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| try list.append(ctx.allocator, line);
    return list.items;
}
fn repository(ctx: *cli.Context, repo: ?[]const u8) ![]const u8 {
    return repo orelse std.mem.trim(u8, try run(ctx, &.{ "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" }), " \n");
}
fn plan(ctx: *cli.Context, wanted: []const []const u8, pattern: []const u8, repo: []const u8) ![]Release {
    const tags = try lines(ctx, try run(ctx, &.{ "git", "tag", "--list", pattern, "--sort=v:refname" }));
    const rows = try ctx.allocator.alloc(Release, wanted.len);
    for (wanted, rows) |tag, *row| {
        try ctx.checkCancelled();
        const since = notes.previous(tags, tag) catch return ctx.fail(.usage, try std.fmt.allocPrint(ctx.allocator, "'{s}' is not a tag matching {s}.", .{ tag, pattern }), "Fetch the tags (git fetch --tags), or pass --pattern to match how this repository names releases.");
        const range = if (since) |prior| try std.fmt.allocPrint(ctx.allocator, "{s}..{s}", .{ prior, tag }) else tag;
        const log = try run(ctx, &.{ "git", "log", "--no-merges", notes.log_format, range, "--" });
        row.* = .{ .tag = tag, .since = since, .action = "would write", .notes = try notes.render(ctx.allocator, log, repo, tag, since) };
    }
    return rows;
}
fn publish(ctx: *cli.Context, rows: []Release, repo: []const u8) !void {
    const io = state(ctx).io;
    for (rows, 0..) |*row, i| {
        try ctx.checkCancelled();
        try ctx.progress("Writing release notes", i, rows.len);
        const argv: []const []const u8 = &.{ "gh", "release", "edit", row.tag, "--repo", repo, "--notes-file", "-" };
        var child = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .ignore, .stderr = .inherit }) catch |err| return toolFailure(ctx, argv, @errorName(err));
        defer if (child.id != null) child.kill(io);
        child.stdin.?.writeStreamingAll(io, row.notes) catch |err| return toolFailure(ctx, argv, @errorName(err));
        child.stdin.?.close(io);
        child.stdin = null;
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return toolFailure(ctx, argv, "see its message above");
        row.action = "wrote";
    }
    try ctx.progress("Writing release notes", rows.len, rows.len);
}
fn previewWrite(ctx: *cli.Context, opts: WriteOptions) ![]const Release {
    return plan(ctx, opts.tags, opts.pattern, try repository(ctx, opts.repo));
}
fn write(ctx: *cli.Context, opts: WriteOptions) ![]const Release {
    const repo = try repository(ctx, opts.repo);
    const rows = try plan(ctx, opts.tags, opts.pattern, repo);
    try publish(ctx, rows, repo);
    return rows;
}
fn releases(ctx: *cli.Context, repo: []const u8) ![]const []const u8 {
    return lines(ctx, try run(ctx, &.{ "gh", "release", "list", "--repo", repo, "--limit", "10000", "--json", "tagName", "-q", ".[].tagName" }));
}
fn previewBackfill(ctx: *cli.Context, opts: BackfillOptions) ![]const Release {
    const repo = try repository(ctx, opts.repo);
    return plan(ctx, try releases(ctx, repo), opts.pattern, repo);
}
fn backfill(ctx: *cli.Context, opts: BackfillOptions) ![]const Release {
    const repo = try repository(ctx, opts.repo);
    const rows = try plan(ctx, try releases(ctx, repo), opts.pattern, repo);
    try publish(ctx, rows, repo);
    return rows;
}
fn human(ctx: *cli.Context, rows: []const Release) !void {
    const w = ctx.runtime.out.writer;
    for (rows) |row| {
        const since = row.since orelse "the first commit";
        if (eql(u8, row.action, "wrote")) {
            try w.print("Wrote the notes for {s} (since {s}).\n", .{ row.tag, since });
        } else try w.print("Notes for {s} (since {s}):\n\n{s}\n", .{ row.tag, since, row.notes });
    }
}
fn readLine(ctx: *cli.Context) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(state(ctx).io, &buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return ctx.fail(.usage, "Could not read confirmation.", "Pass --yes to confirm noninteractively.");
    return ctx.allocator.dupe(u8, std.mem.trim(u8, line, "\r"));
}

const pattern_info: cli.OptionInfo = .{ .name = "pattern", .help = "Glob of the tags that count as releases", .example = "v[0-9]*" };
const repo_info: cli.OptionInfo = .{ .name = "repo", .help = "Repository as owner/name; defaults to this clone's", .example = "benomahony/zclig", .env = "GITHUB_REPOSITORY" };
pub const app: cli.App = .{
    .name = "commit-notes",
    .version = build_info.version,
    .description = "Write GitHub release notes from the commit messages since the previous release",
    .support = "https://github.com/benomahony/commit-notes/issues",
    .commands = &.{
        cli.command(WriteOptions, Release, .{
            .name = "write",
            .description = "Write the notes for the given releases",
            .examples = &.{ "commit-notes write v1.2.0 --dry-run", "commit-notes write v1.2.0" },
            .positional = .{ .name = "tags", .metavar = "TAG", .help = "Release tags to write notes for", .min = 1 },
            .options = &.{ pattern_info, repo_info },
        }, .{ .run = write, .dry_run = previewWrite, .human = human }),
        cli.command(BackfillOptions, Release, .{
            .name = "backfill",
            .description = "Rewrite the notes of every release in the repository",
            .examples = &.{ "commit-notes backfill --dry-run", "commit-notes backfill --yes" },
            .options = &.{ pattern_info, repo_info },
            .destructive = "The notes of every release in the repository will be replaced.",
        }, .{ .run = backfill, .dry_run = previewBackfill, .human = human }),
    },
};
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(70);
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    var err = std.Io.File.stderr().writer(init.io, &err_buffer);
    var host: State = .{ .io = init.io };
    var rt = cli.native.runtime(init, &out.interface, &err.interface);
    rt.user_data = &host;
    rt.read_line = readLine;
    std.process.exit(@backingInt(app.run(init.gpa, args[1..], rt)));
}

test {
    _ = notes;
}
test "usage errors and confirmation stop before git or gh run" {
    try cli.conformance.check(std.testing.allocator, app, &.{
        .{ .args = &.{"--version"}, .stdout_contains = "commit-notes dev", .stderr_empty = true },
        .{ .args = &.{ "write", "--help" }, .stdout_contains = "--dry-run", .stderr_empty = true },
        .{ .args = &.{"write"}, .exit = .usage, .stdout_empty = true, .stderr_contains = "needs at least 1 TAG" },
        .{ .args = &.{ "backfill", "--no-input" }, .exit = .usage, .stdout_empty = true, .stderr_contains = "--yes" },
    });
}
