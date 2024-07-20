const std = @import("std");
const clap = @import("clap");
const loog = @import("loog.zig");

const PARAMS = clap.parseParamsComptime(
    \\-h, --help   Display help.
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
    const allocator = arena.allocator();
    defer arena.deinit();

    var res = try clap.parse(clap.Help, &PARAMS, clap.parsers.default, .{ .allocator = allocator });
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
    var buf_reader = std.io.bufferedReader(log_file.reader());
    defer log_file.close();

    const report_file = try cur_dir.createFile(report_file_path, .{});
    defer report_file.close();

    try loog.analyze(allocator, buf_reader.reader(), report_file.writer());
}
