//! Release notes from `git log` output; nothing here runs git or talks to GitHub.
const std = @import("std");
const eql = std.mem.eql;

/// Each commit is hash NUL subject NUL body, ended by a record separator, so no message text is ambiguous.
pub const log_format = "--format=%h%x00%s%x00%b%x1e";

/// The release before `tag` in `tags`, which git sorted oldest first; null for the first release.
pub fn previous(tags: []const []const u8, tag: []const u8) error{UnknownTag}!?[]const u8 {
    for (tags, 0..) |t, i| if (eql(u8, t, tag)) return if (i == 0) null else tags[i - 1];
    return error.UnknownTag;
}

fn isTrailer(line: []const u8) bool {
    for ([_][]const u8{ "co-authored-by:", "signed-off-by:" }) |key| if (std.ascii.startsWithIgnoreCase(line, key)) return true;
    return false;
}

/// One bullet per commit, newest first, with its body indented beneath and attribution trailers removed.
pub fn render(allocator: std.mem.Allocator, log: []const u8, repo: []const u8, tag: []const u8, since: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    var commits = std.mem.splitScalar(u8, log, 0x1e);
    while (commits.next()) |raw| {
        const commit = std.mem.trimStart(u8, raw, "\n");
        if (commit.len == 0) continue;
        var fields = std.mem.splitScalar(u8, commit, 0);
        const hash = fields.next().?;
        const subject = fields.next() orelse "";
        try w.print("- {s} ({s})\n", .{ subject, hash });
        var started = false;
        var gap = false;
        var lines = std.mem.splitScalar(u8, fields.rest(), '\n');
        while (lines.next()) |line| {
            const text = std.mem.trimEnd(u8, line, " \t\r");
            if (isTrailer(std.mem.trimStart(u8, text, " \t"))) continue;
            if (text.len == 0) {
                gap = started;
                continue;
            }
            if (!started or gap) try w.writeByte('\n');
            started = true;
            gap = false;
            try w.print("  {s}\n", .{text});
        }
        try w.writeByte('\n');
    }
    if (since) |prior| {
        try w.print("**Full Changelog**: https://github.com/{s}/compare/{s}...{s}\n", .{ repo, prior, tag });
    } else try w.print("**Full Changelog**: https://github.com/{s}/commits/{s}\n", .{ repo, tag });
    return out.written();
}

test "the previous release is the tag sorted before it" {
    const tags = [_][]const u8{ "v0.1.0", "v0.1.9", "v0.1.10" };
    try std.testing.expectEqual(@as(?[]const u8, null), try previous(&tags, "v0.1.0"));
    try std.testing.expectEqualStrings("v0.1.9", (try previous(&tags, "v0.1.10")).?);
    try std.testing.expectError(error.UnknownTag, previous(&tags, "v2.0.0"));
}

test "subjects become bullets, bodies are indented and trailers are dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const log = "642861d\x00Use commit messages as release notes\x00Commits go straight to main.\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n\x1e\n" ++
        "aade153\x00Support command aliases\x00Signed-off-by: Someone <a@b.c>\n\x1e\n" ++
        "0ff1350\x00Drop Zig 0.16\x00First line\nsecond line\n\nNext paragraph\n\x1e\n";
    try std.testing.expectEqualStrings(
        "- Use commit messages as release notes (642861d)\n\n  Commits go straight to main.\n\n" ++
            "- Support command aliases (aade153)\n\n" ++
            "- Drop Zig 0.16 (0ff1350)\n\n  First line\n  second line\n\n  Next paragraph\n\n" ++
            "**Full Changelog**: https://github.com/benomahony/zclig/compare/v0.1.0...v0.1.1\n",
        try render(arena.allocator(), log, "benomahony/zclig", "v0.1.1", "v0.1.0"),
    );
}

test "the first release links to its history and an empty range is just the link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("**Full Changelog**: https://github.com/o/r/commits/v0.1.0\n", try render(arena.allocator(), "", "o/r", "v0.1.0", null));
}
