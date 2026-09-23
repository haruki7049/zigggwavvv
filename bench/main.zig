//! Speed and memory benchmark for zigggwavvv.
//!
//! Measures:
//!   - Write throughput (MiB/s, realtime multiplier) and peak live heap allocation
//!   - Read throughput (MiB/s, realtime multiplier) and peak live heap allocation
//!   - Process peak RSS (ru_maxrss)
//!
//! Usage:
//!   zig build bench -Doptimize=ReleaseFast
//!   zig build bench -Doptimize=ReleaseFast -- [options]
//!
//! Options:
//!   --file=<path>       Benchmark a specific WAV file instead of synthetic audio
//!   --duration=<sec>    Duration of synthetic audio in seconds (default: 10)
//!   --iterations=<n>    Number of benchmark iterations (default: 5)
//!   --help              Display this help message

const std = @import("std");
const builtin = @import("builtin");
const zigggwavvv = @import("zigggwavvv");
const riff = @import("riff");

const WaveF64 = zigggwavvv.Wave(f64);
const FormatCode = zigggwavvv.FormatCode;

/// Allocator wrapper that tracks live allocated bytes, peak live bytes, and allocation counts.
const TrackingAllocator = struct {
    child: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    total_allocated: usize = 0,
    alloc_count: usize = 0,
    free_count: usize = 0,

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn reset(self: *TrackingAllocator) void {
        self.peak_bytes = self.live_bytes;
        self.total_allocated = 0;
        self.alloc_count = 0;
        self.free_count = 0;
    }

    fn recordGrowth(self: *TrackingAllocator, old_len: usize, new_len: usize) void {
        self.live_bytes = self.live_bytes - old_len + new_len;
        if (new_len > old_len) {
            self.total_allocated += (new_len - old_len);
        }
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr) orelse return null;
        self.recordGrowth(0, len);
        self.alloc_count += 1;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr)) return false;
        self.recordGrowth(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        self.recordGrowth(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
        self.free_count += 1;
    }
};

const BenchResult = struct {
    best_ns: i96,
    avg_ns: i96,
    peak_live_bytes: usize,
    alloc_count: usize,
};

fn nsToMs(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn bytesToMib(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

/// Peak resident set size of this process.
fn peakRssBytes() u64 {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const maxrss: u64 = @intCast(usage.maxrss);
    return if (builtin.os.tag.isDarwin()) maxrss else maxrss * 1024;
}

/// Synthesize a multi-channel sine wave for testing.
fn synthesizeWave(
    allocator: std.mem.Allocator,
    format_code: FormatCode,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    duration_sec: f64,
) !WaveF64 {
    const frames = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sample_rate)) * duration_sec));
    const total_samples = frames * channels;

    const samples = try allocator.alloc(f64, total_samples);
    errdefer allocator.free(samples);

    for (0..frames) |frame_idx| {
        const t = @as(f64, @floatFromInt(frame_idx)) / @as(f64, @floatFromInt(sample_rate));
        for (0..channels) |ch| {
            const freq = 440.0 * (1.0 + 0.5 * @as(f64, @floatFromInt(ch)));
            samples[frame_idx * channels + ch] = std.math.sin(t * freq * 2.0 * std.math.pi) * 0.75;
        }
    }

    return WaveF64.init(.{
        .format_code = format_code,
        .sample_rate = sample_rate,
        .channels = channels,
        .bits = bits,
        .samples = samples,
    });
}

fn benchWrite(
    io: std.Io,
    wave: WaveF64,
    tracking: *TrackingAllocator,
    iterations: usize,
) !struct { result: BenchResult, encoded_bytes: []u8 } {
    const track_alloc = tracking.allocator();
    var best_ns: i96 = std.math.maxInt(i96);
    var total_ns: i96 = 0;
    var max_peak_live: usize = 0;
    var total_allocs: usize = 0;
    var last_encoded: ?[]u8 = null;

    for (0..iterations) |_| {
        if (last_encoded) |prev| {
            tracking.child.free(prev);
            last_encoded = null;
        }
        tracking.reset();

        var out = std.Io.Writer.Allocating.init(tracking.child);
        errdefer out.deinit();

        const start = std.Io.Timestamp.now(io, .awake);
        try wave.write(&out.writer, .{ .allocator = track_alloc });
        const elapsed = start.untilNow(io, .awake).toNanoseconds();

        best_ns = @min(best_ns, elapsed);
        total_ns += elapsed;
        max_peak_live = @max(max_peak_live, tracking.peak_bytes);
        total_allocs += tracking.alloc_count;

        last_encoded = try out.toOwnedSlice();
    }

    return .{
        .result = .{
            .best_ns = best_ns,
            .avg_ns = @divTrunc(total_ns, @as(i96, @intCast(iterations))),
            .peak_live_bytes = max_peak_live,
            .alloc_count = total_allocs / iterations,
        },
        .encoded_bytes = last_encoded.?,
    };
}

fn benchRead(
    io: std.Io,
    encoded_wav: []const u8,
    tracking: *TrackingAllocator,
    iterations: usize,
) !BenchResult {
    const track_alloc = tracking.allocator();
    var best_ns: i96 = std.math.maxInt(i96);
    var total_ns: i96 = 0;
    var max_peak_live: usize = 0;
    var total_allocs: usize = 0;

    for (0..iterations) |_| {
        tracking.reset();

        var reader: std.Io.Reader = .fixed(encoded_wav);

        const start = std.Io.Timestamp.now(io, .awake);
        const wave = try WaveF64.read(track_alloc, &reader);
        const elapsed = start.untilNow(io, .awake).toNanoseconds();

        best_ns = @min(best_ns, elapsed);
        total_ns += elapsed;
        max_peak_live = @max(max_peak_live, tracking.peak_bytes);
        total_allocs += tracking.alloc_count;

        wave.deinit(track_alloc);
    }

    return .{
        .best_ns = best_ns,
        .avg_ns = @divTrunc(total_ns, @as(i96, @intCast(iterations))),
        .peak_live_bytes = max_peak_live,
        .alloc_count = total_allocs / iterations,
    };
}

fn runScenario(
    io: std.Io,
    out: *std.Io.Writer,
    tracking: *TrackingAllocator,
    title: []const u8,
    wave: WaveF64,
    iterations: usize,
) !void {
    const duration_sec = @as(f64, @floatFromInt(wave.samples.len / wave.channels)) / @as(f64, @floatFromInt(wave.sample_rate));
    const bytes_per_sample: usize = @as(usize, wave.bits) / 8;
    const raw_audio_bytes = wave.samples.len * bytes_per_sample;
    const decoded_f64_bytes = wave.samples.len * @sizeOf(f64);

    try out.print("\n--- {s} ---\n", .{title});
    try out.print("  Spec: {d} Hz | {d} ch | {d}-bit {t} | duration: {d:.2} s | raw audio: {d:.2} MiB\n", .{
        wave.sample_rate,
        wave.channels,
        wave.bits,
        wave.format_code,
        duration_sec,
        bytesToMib(raw_audio_bytes),
    });

    // Benchmark Write
    const write_res = try benchWrite(io, wave, tracking, iterations);
    defer tracking.child.free(write_res.encoded_bytes);

    const write_mib_s = bytesToMib(raw_audio_bytes) / (nsToMs(write_res.result.best_ns) / 1000.0);
    const write_rt = duration_sec / (nsToMs(write_res.result.best_ns) / 1000.0);

    try out.print("  WRITE (f64 -> WAV bytes):\n", .{});
    try out.print("    best: {d:.3} ms | avg: {d:.3} ms | throughput: {d:.1} MiB/s ({d:.0}x realtime)\n", .{
        nsToMs(write_res.result.best_ns),
        nsToMs(write_res.result.avg_ns),
        write_mib_s,
        write_rt,
    });
    try out.print("    peak heap live: {d:.2} MiB ({d:.2}x raw) | avg {d} allocs\n", .{
        bytesToMib(write_res.result.peak_live_bytes),
        @as(f64, @floatFromInt(write_res.result.peak_live_bytes)) / @as(f64, @floatFromInt(raw_audio_bytes)),
        write_res.result.alloc_count,
    });

    // Benchmark Read
    const read_res = try benchRead(io, write_res.encoded_bytes, tracking, iterations);
    const read_mib_s = bytesToMib(raw_audio_bytes) / (nsToMs(read_res.best_ns) / 1000.0);
    const read_rt = duration_sec / (nsToMs(read_res.best_ns) / 1000.0);

    try out.print("  READ (WAV bytes -> f64):\n", .{});
    try out.print("    best: {d:.3} ms | avg: {d:.3} ms | throughput: {d:.1} MiB/s ({d:.0}x realtime)\n", .{
        nsToMs(read_res.best_ns),
        nsToMs(read_res.avg_ns),
        read_mib_s,
        read_rt,
    });
    try out.print("    peak heap live: {d:.2} MiB (raw {d:.2} MiB + decoded {d:.2} MiB = {d:.2} MiB min)\n", .{
        bytesToMib(read_res.peak_live_bytes),
        bytesToMib(raw_audio_bytes),
        bytesToMib(decoded_f64_bytes),
        bytesToMib(raw_audio_bytes + decoded_f64_bytes),
    });
    try out.print("    avg {d} allocs\n", .{read_res.alloc_count});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var file_path: ?[]const u8 = null;
    var duration_sec: f64 = 10.0;
    var iterations: usize = 5;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--file=")) {
            file_path = arg["--file=".len..];
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            duration_sec = try std.fmt.parseFloat(f64, arg["--duration=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--iterations=")) {
            iterations = try std.fmt.parseInt(usize, arg["--iterations=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\zigggwavvv benchmark runner
                \\
                \\Usage:
                \\  zig build bench -Doptimize=ReleaseFast -- [options]
                \\
                \\Options:
                \\  --file=<path>       Benchmark a specific WAV file
                \\  --duration=<sec>    Duration of synthetic audio in seconds (default: 10)
                \\  --iterations=<n>    Number of iterations per test (default: 5)
                \\  --help, -h          Print this help message
                \\
            , .{});
            return;
        } else {
            std.debug.print("unknown option: {s}\nUse --help for usage.\n", .{arg});
            std.process.exit(1);
        }
    }

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_writer.interface;

    try out.print("================================================================================\n", .{});
    try out.print(" zigggwavvv Performance & Memory Benchmark\n", .{});
    try out.print(" (iterations: {d}, target: {s}-{s})\n", .{ iterations, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
    try out.print("================================================================================\n", .{});

    var tracking: TrackingAllocator = .{ .child = gpa };

    if (file_path) |path| {
        try out.print("Target file: {s}\n", .{path});
        const file_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(file_bytes);

        var reader: std.Io.Reader = .fixed(file_bytes);
        const wave = try WaveF64.read(gpa, &reader);
        defer wave.deinit(gpa);

        try runScenario(io, out, &tracking, "Custom File Benchmark", wave, iterations);
    } else {
        const scenarios = [_]struct {
            title: []const u8,
            format_code: FormatCode,
            sample_rate: u32,
            channels: u16,
            bits: u16,
        }{
            .{ .title = "Scenario 1: 16-bit PCM (CD Quality, Stereo)", .format_code = .pcm, .sample_rate = 44100, .channels = 2, .bits = 16 },
            .{ .title = "Scenario 2: 24-bit PCM (Studio Quality, Stereo)", .format_code = .pcm, .sample_rate = 48000, .channels = 2, .bits = 24 },
            .{ .title = "Scenario 3: 32-bit IEEE Float (DAW Quality, Stereo)", .format_code = .ieee_float, .sample_rate = 48000, .channels = 2, .bits = 32 },
        };

        for (scenarios) |sc| {
            const wave = try synthesizeWave(gpa, sc.format_code, sc.sample_rate, sc.channels, sc.bits, duration_sec);
            defer wave.deinit(gpa);

            try runScenario(io, out, &tracking, sc.title, wave, iterations);
        }
    }

    try out.print("\n================================================================================\n", .{});
    try out.print("Overall Process Peak RSS: {d:.2} MiB\n", .{bytesToMib(@intCast(peakRssBytes()))});
    try out.print("================================================================================\n", .{});
    try out.flush();
}
