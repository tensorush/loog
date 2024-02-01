const std = @import("std");
const clap = @import("clap");
const loog = @import("loog.zig");

const MAX_LOG_LEN: usize = 1 << 22;

const PARAMS = clap.parseParamsComptime(
    \\-h, --help   Display help menu.
    \\<str>        Input CLF log file path.
    \\<str>        Output JSON report file path.
    \\
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Memory leak has occurred!");
    };

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &PARAMS, clap.parsers.default, .{ .allocator = allocator, .diagnostic = &diag }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    var log_file_path: []const u8 = "example/loog.log";
    var report_file_path: []const u8 = "example/loog.json";

    if (res.positionals.len > 0) {
        log_file_path = res.positionals[0];
        report_file_path = res.positionals[1];
    }

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &PARAMS, .{});
    }

    const cur_dir = std.fs.cwd();

    const log_file = try cur_dir.openFile(log_file_path, .{});
    const log = try log_file.readToEndAlloc(allocator, MAX_LOG_LEN);
    log_file.close();

    const report_file = try cur_dir.createFile(report_file_path, .{});
    defer report_file.close();

    try loog.analyze(allocator, log, report_file.writer());
}
