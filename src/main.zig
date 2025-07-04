const std = @import("std");
const posix = std.posix;
const libcoro = @import("zigcoro");
const os = std.os;
const IoUring = os.linux.IoUring;
const c = @cImport({
    @cInclude("fcntl.h");
});

const PORT = 8080;
const BACKLOG = 2048;
const STACK_SIZE = 128 * 1024;

const ClientArgs = struct {
    fd: posix.fd_t,
    ring: *IoUring,
};

fn queue_read(ring: *IoUring, op_map: *std.AutoHashMap(u64, void), fd: posix.fd_t, buf: []u8, op_id: *u64) !void {
    const sqe = try ring.get_sqe();
    sqe.prep_recv(fd, buf, 0);
    sqe.user_data = op_id.*;
    try op_map.put(op_id.*, {});
    op_id.* += 1;
}

fn queue_write(ring: *IoUring, op_map: *std.AutoHashMap(u64, void), fd: posix.fd_t, response: []const u8, op_id: *u64, offset: usize) !void {
    const sqe = try ring.get_sqe();
    sqe.prep_send(fd, response[offset..], 0);
    sqe.user_data = op_id.*;
    try op_map.put(op_id.*, {});
    op_id.* += 1;
}

fn handle_client_entry(args: *ClientArgs) void {
    handle_client_coro(args.fd, args.ring);
}

fn handle_client_coro(fd: posix.fd_t, ring: *IoUring) void {
    defer posix.close(fd);

    var read_buf: [1024]u8 = undefined;
    var op_map = std.AutoHashMap(u64, void).init(std.heap.page_allocator);
    var op_id: u64 = 1;
    queue_read(ring, &op_map, fd, &read_buf, &op_id) catch return;
    _ = ring.submit() catch return;

    var cqes_read: [1]os.linux.io_uring_cqe = undefined;
    const n_read = ring.copy_cqes(&cqes_read, 1) catch return;
    if (n_read == 0 or cqes_read[0].res <= 0) return;

    var date_buf: [64]u8 = undefined;
    const date_str = format_date_gmt(&date_buf) catch {
        std.debug.print("Failed to format date\n", .{});
        return;
    };

    var response_buf: [256]u8 = undefined;
    const response_slice = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\n" ++
        "Server: Zig\r\n" ++
        "Date: {s}\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n\r\n" ++
        "Hello, World!", .{date_str}) catch return;

    queue_write(ring, &op_map, fd, response_slice, &op_id, 0) catch return;

    _ = ring.submit() catch return;

    var cqes_write: [1]os.linux.io_uring_cqe = undefined;
    _ = ring.copy_cqes(&cqes_write, 1) catch return;
}

fn format_date_gmt(buf: *[64]u8) ![]u8 {
    const timestamp = std.time.timestamp(); // seconds since epoch

    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    // Fallback logic assuming constant values:
    const SECONDS_PER_DAY = 86400;
    const SECONDS_PER_HOUR = 3600;
    const SECONDS_PER_MINUTE = 60;

    const seconds_in_day = @mod(timestamp, SECONDS_PER_DAY);

    const hour = @divFloor(seconds_in_day, SECONDS_PER_HOUR);
    const minute = @divFloor(@mod(seconds_in_day, SECONDS_PER_HOUR), SECONDS_PER_MINUTE);
    const second = @mod(seconds_in_day, SECONDS_PER_MINUTE);
    // Use constant date for testing (e.g., 3 Jul 2025, Wed)
    const weekday_index = @as(u8, 3); // "Wed"
    const day = 3;
    const month_index = 6; // July (zero-based)
    const year = 2025;
    return std.fmt.bufPrint(
        buf,
        "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekdays[weekday_index],
            day,
            months[month_index],
            year,
            hour,
            minute,
            second,
        },
    );
}

fn server_loop(ring: *IoUring, exec: *libcoro.Executor) !void {
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    _ = try posix.fcntl(sockfd, c.F_SETFL, c.O_NONBLOCK);

    var addr: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, PORT),
        .addr = 0,
    };
    try posix.bind(sockfd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try posix.listen(sockfd, BACKLOG);

    std.debug.print("z server listening on 0.0.0.0:{}\n", .{PORT});

    while (true) {
        var client_addr: posix.sockaddr.in = undefined;
        var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const fd = posix.accept(sockfd, @ptrCast(&client_addr), &client_len, 0) catch continue;

        const stack = libcoro.stackAlloc(std.heap.page_allocator, STACK_SIZE) catch {
            posix.close(fd);
            continue;
        };

        const args = try std.heap.page_allocator.create(ClientArgs);
        args.* = .{ .fd = fd, .ring = ring };

        _ = libcoro.xasync(handle_client_entry, .{args}, stack) catch {
            posix.close(fd);
        };

        _ = exec.tick();
    }
}

pub fn main() !void {
    var ring = try IoUring.init(4096, 0);
    defer ring.deinit();

    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{
        .stack_allocator = std.heap.page_allocator,
        .executor = &exec,
    });

    try server_loop(&ring, &exec);
}
