const std = @import("std");
const http = @import("http.zig");
const hyperloglog = @import("hyperloglog");

const MAX_LOG_LINE_LEN: usize = 1 << 10;

const HourCounter = struct {
    value: usize,
    total: usize,
};

const MethodCounter = struct {
    value: http.Method,
    total: usize,
};

const VersionCounter = struct {
    value: http.Version,
    total: usize,
};

const StatusCounter = struct {
    value: u10,
    total: usize,
};

const Report = struct {
    log_byte_length: usize,
    elapsed_seconds: f64,
    total_bytes_served: usize,
    lines: struct {
        ipv4: usize,
        ipv6: usize,
        valid: usize,
        invalid: usize,
        total: usize,
    },
    visits: struct {
        ipv4: usize,
        ipv6: usize,
        total: usize,
    },
    hour_counters: []const HourCounter,
    method_counters: []const MethodCounter,
    version_counters: []const VersionCounter,
    status_counters: []const StatusCounter,
};

/// Analyze CLF server log.
pub fn analyze(allocator: std.mem.Allocator, reader: anytype, writer: anytype) !void {
    var version_counters = std.enums.EnumArray(http.Version, usize).initFill(0);
    var method_counters = std.enums.EnumArray(http.Method, usize).initFill(0);
    var status_counters = std.enums.EnumArray(http.Status, usize).initFill(0);
    var hour_counters = [1]usize{0} ** 24;
    var total_bytes_served: usize = 0;
    var num_invalid_lines: usize = 0;
    var log_byte_length: usize = 0;
    var num_ipv4_hits: usize = 0;
    var num_ipv6_hits: usize = 0;
    const hasher_seed: u64 = 0;

    var hll_ipv4 = try hyperloglog.DefaultHyperLogLog.init(allocator);
    defer hll_ipv4.deinit();

    var hll_ipv6 = try hyperloglog.DefaultHyperLogLog.init(allocator);
    defer hll_ipv6.deinit();

    var timer = try std.time.Timer.start();
    const start_time = timer.lap();

    // Parse log lines.
    var line_buf: [MAX_LOG_LINE_LEN]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| : (log_byte_length += line.len + 1) {
        if (std.mem.indexOfScalar(u8, line, ' ')) |host_end_idx| {
            // Parse host IP address.
            var is_ipv4 = true;
            const address = std.net.Address.parseIp4(line[0..host_end_idx], 8080) catch blk: {
                const address = std.net.Address.parseIp6(line[0..host_end_idx], 8080) catch {
                    num_invalid_lines += 1;
                    continue;
                };
                is_ipv4 = false;
                break :blk address;
            };
            const hashed_address = blk: {
                var hasher = std.hash.Wyhash.init(hasher_seed);
                if (is_ipv4) {
                    std.hash.autoHash(&hasher, address.in.sa.addr);
                } else {
                    std.hash.autoHash(&hasher, address.in6.sa.addr);
                }
                break :blk hasher.final();
            };
            if (is_ipv4) {
                num_ipv4_hits += 1;
                try hll_ipv4.addHashed(hashed_address);
            } else {
                num_ipv6_hits += 1;
                try hll_ipv6.addHashed(hashed_address);
            }

            // Parse hour.
            if (std.mem.indexOfScalarPos(u8, line, host_end_idx, '[')) |date_start_idx| {
                if (std.fmt.parseUnsigned(u5, line[date_start_idx + 13 .. date_start_idx + 15], 10) catch null) |hour| {
                    hour_counters[hour] += 1;
                }
            }

            // Parse request.
            if (std.mem.indexOfScalarPos(u8, line, host_end_idx, '"')) |request_start_idx| {
                // Parse method.
                const method_end_idx = std.mem.indexOfScalarPos(u8, line, request_start_idx, ' ').?;
                if (std.meta.stringToEnum(http.Method, line[request_start_idx + 1 .. method_end_idx])) |method| {
                    method_counters.getPtr(method).* += 1;
                }

                // Parse version.
                const path_end_idx = std.mem.indexOfScalarPos(u8, line, method_end_idx + 1, ' ').?;
                const version_end_idx = std.mem.indexOfScalarPos(u8, line, path_end_idx, '"').?;
                if (std.meta.stringToEnum(http.Version, line[path_end_idx + 1 .. version_end_idx])) |version| {
                    version_counters.getPtr(version).* += 1;
                }

                // Parse status code.
                const request_end_idx = std.mem.indexOfScalarPos(u8, line, request_start_idx + 1, '"').?;
                const status_code_end_idx = std.mem.indexOfScalarPos(u8, line, request_end_idx + 2, ' ').?;
                if (std.fmt.parseUnsigned(u10, line[request_end_idx + 2 .. status_code_end_idx], 10) catch null) |status_code| {
                    if (std.meta.intToEnum(http.Status, status_code) catch null) |status| {
                        status_counters.getPtr(status).* += 1;
                    }
                }

                // Parse file size.
                const file_size_end_idx = std.mem.indexOfScalarPos(u8, line, status_code_end_idx + 1, ' ').?;
                if (std.fmt.parseUnsigned(usize, line[status_code_end_idx + 1 .. file_size_end_idx], 10) catch null) |file_size| {
                    total_bytes_served += file_size;
                }
            }
        } else {
            num_invalid_lines += 1;
        }
    }

    // Select non-zero hour counters.
    var nonzero_hour_counters = std.BoundedArray(HourCounter, hour_counters.len){};
    for (hour_counters, 0..) |hour_counter, i| {
        if (hour_counter > 0) {
            nonzero_hour_counters.appendAssumeCapacity(.{ .value = i, .total = hour_counter });
        }
    }

    // Select non-zero method counters.
    var nonzero_method_counters = std.BoundedArray(MethodCounter, std.meta.fields(http.Method).len){};
    var method_counters_iter = method_counters.iterator();
    while (method_counters_iter.next()) |method_counter| {
        if (method_counter.value.* > 0) {
            nonzero_method_counters.appendAssumeCapacity(.{ .value = method_counter.key, .total = method_counter.value.* });
        }
    }

    // Select non-zero version counters.
    var nonzero_version_counters = std.BoundedArray(VersionCounter, std.meta.fields(http.Version).len){};
    var version_counters_iter = version_counters.iterator();
    while (version_counters_iter.next()) |version_counter| {
        if (version_counter.value.* > 0) {
            nonzero_version_counters.appendAssumeCapacity(.{ .value = version_counter.key, .total = version_counter.value.* });
        }
    }

    // Select non-zero status counters.
    var nonzero_status_counters = std.BoundedArray(StatusCounter, std.meta.fields(http.Status).len){};
    var status_counters_iter = status_counters.iterator();
    while (status_counters_iter.next()) |status_counter| {
        if (status_counter.value.* > 0) {
            nonzero_status_counters.appendAssumeCapacity(.{ .value = @intFromEnum(status_counter.key), .total = status_counter.value.* });
        }
    }

    // Create log report.
    const report = Report{
        .log_byte_length = log_byte_length,
        .total_bytes_served = total_bytes_served,
        .elapsed_seconds = @as(f64, @floatFromInt(timer.read() - start_time)) / @as(f64, @floatFromInt(std.time.ns_per_s)),
        .lines = .{
            .ipv4 = num_ipv4_hits,
            .ipv6 = num_ipv6_hits,
            .valid = num_ipv4_hits + num_ipv6_hits,
            .invalid = num_invalid_lines,
            .total = num_ipv4_hits + num_ipv6_hits + num_invalid_lines,
        },
        .visits = .{
            .ipv4 = hll_ipv4.cardinality(),
            .ipv6 = hll_ipv6.cardinality(),
            .total = hll_ipv4.cardinality() + hll_ipv6.cardinality(),
        },
        .hour_counters = nonzero_hour_counters.constSlice(),
        .method_counters = nonzero_method_counters.constSlice(),
        .version_counters = nonzero_version_counters.constSlice(),
        .status_counters = nonzero_status_counters.constSlice(),
    };

    // Serialize log report to JSON.
    try std.json.stringify(report, .{ .whitespace = .indent_4 }, writer);
}
