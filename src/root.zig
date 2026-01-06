const std = @import("std");
const riff = @import("riff");

/// Audio sample bit depth
pub const Bits = enum {
    u8,
    i16,
    i24,
    f32,
};

/// Audio encoding format
pub const FormatCode = enum(u16) {
    pcm = 1,
    ieee_float = 3,
    alaw = 6,
    mulaw = 7,
};

/// WAV structure representing audio properties and normalized samples
pub const Wave = struct {
    format_code: FormatCode,
    sample_rate: u32,
    channels: u16,
    bits: Bits,
    samples: []f32,

    pub fn deinit(self: Wave, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }
};

/// Deserialize a WAV file from a byte slice
pub fn from_bytes(allocator: std.mem.Allocator, bytes: []const u8) !Wave {
    const root_chunk = try riff.from_slice(allocator, bytes);
    defer root_chunk.deinit(allocator);

    const r = switch (root_chunk) {
        .riff => |r| if (std.mem.eql(u8, &r.four_cc, "WAVE")) r else return error.InvalidFormat,
        else => return error.InvalidFormat,
    };

    var format_code: FormatCode = .pcm;
    var sample_rate: u32 = 0;
    var channels: u16 = 0;
    var bits: Bits = .i16;
    var samples: ?[]f32 = null;

    for (r.chunks) |c| {
        const id = c.chunk.four_cc;
        if (std.mem.eql(u8, &id, "fmt ")) {
            const data = c.chunk.data;
            format_code = @enumFromInt(std.mem.readInt(u16, data[0..2], .little));
            channels = std.mem.readInt(u16, data[2..4], .little);
            sample_rate = std.mem.readInt(u32, data[4..8], .little);
            bits = switch (std.mem.readInt(u16, data[14..16], .little)) {
                8 => .u8,
                16 => .i16,
                24 => .i24,
                32 => .f32,
                else => return error.UnsupportedBitDepth,
            };
        } else if (std.mem.eql(u8, &id, "data")) {
            const data = c.chunk.data;
            const s_count = switch (bits) {
                .i16 => data.len / 2,
                else => return error.NotImplemented,
            };
            var s_list = try allocator.alloc(f32, s_count);
            var i: usize = 0;
            while (i < s_count) : (i += 1) {
                const val = std.mem.readInt(i16, data[i * 2 .. (i + 1) * 2][0..2], .little);
                s_list[i] = @as(f32, @floatFromInt(val)) / 32768.0;
            }
            samples = s_list;
        }
    }

    return Wave{
        .format_code = format_code,
        .sample_rate = sample_rate,
        .channels = channels,
        .bits = bits,
        .samples = samples orelse return error.DataChunkNotFound,
    };
}

/// Serialize a Wave structure to a WAV format byte array
pub fn to_bytes(allocator: std.mem.Allocator, wave: Wave) ![]u8 {
    const bits_per_sample: u16 = switch (wave.bits) {
        .u8 => 8,
        .i16 => 16,
        .i24 => 24,
        .f32 => 32,
    };
    const block_align = wave.channels * (bits_per_sample / 8);
    const bytes_per_sec = wave.sample_rate * block_align;

    // Build fmt chunk data
    var fmt_payload: std.array_list.Aligned(u8, null) = .empty;
    defer fmt_payload.deinit(allocator);
    const fw = fmt_payload.writer(allocator);
    try fw.writeInt(u16, @intFromEnum(wave.format_code), .little);
    try fw.writeInt(u16, wave.channels, .little);
    try fw.writeInt(u32, wave.sample_rate, .little);
    try fw.writeInt(u32, bytes_per_sec, .little);
    try fw.writeInt(u16, block_align, .little);
    try fw.writeInt(u16, bits_per_sample, .little);

    // Build data chunk payload
    var data_payload: std.array_list.Aligned(u8, null) = .empty;
    defer data_payload.deinit(allocator);
    for (wave.samples) |s| {
        const val: i16 = @intFromFloat(std.math.clamp(s * 32768.0, -32768.0, 32767.0));
        try data_payload.writer(allocator).writeInt(i16, val, .little);
    }

    const chunks = try allocator.alloc(riff.Chunk, 2);
    chunks[0] = .{ .chunk = .{ .four_cc = "fmt ".*, .data = try allocator.dupe(u8, fmt_payload.items) } };
    chunks[1] = .{ .chunk = .{ .four_cc = "data".*, .data = try allocator.dupe(u8, data_payload.items) } };

    const wave_riff = riff.Chunk{ .riff = .{ .four_cc = "WAVE".*, .chunks = chunks } };
    defer wave_riff.deinit(allocator);

    var output: std.array_list.Aligned(u8, null) = .empty;
    try riff.to_writer(wave_riff, allocator, output.writer(allocator));
    return output.toOwnedSlice(allocator);
}

// Helper: Create dummy samples for testing
fn create_dummy_samples(allocator: std.mem.Allocator, count: usize) ![]f32 {
    const samples = try allocator.alloc(f32, count);
    for (samples, 0..) |*s, i| {
        // Simple sawtooth wave
        s.* = @as(f32, @floatFromInt(i % 10)) / 10.0;
    }
    return samples;
}

test "Wave serialization and deserialization (Roundtrip)" {
    const allocator = std.testing.allocator;

    // 1. Setup original Wave data
    const original_samples = try create_dummy_samples(allocator, 100);
    const original_wave = Wave{
        .format_code = .pcm,
        .sample_rate = 44100,
        .channels = 1,
        .bits = .i16,
        .samples = original_samples,
    };
    // Note: We don't deinit original_wave here because we'll free original_samples later

    // 2. Serialize to bytes
    const wav_bytes = try to_bytes(allocator, original_wave);
    defer allocator.free(wav_bytes);

    // 3. Deserialize from bytes
    const decoded_wave = try from_bytes(allocator, wav_bytes);
    defer decoded_wave.deinit(allocator);

    // 4. Verification
    try std.testing.expectEqual(original_wave.format_code, decoded_wave.format_code);
    try std.testing.expectEqual(original_wave.sample_rate, decoded_wave.sample_rate);
    try std.testing.expectEqual(original_wave.channels, decoded_wave.channels);
    try std.testing.expectEqual(original_wave.bits, decoded_wave.bits);
    try std.testing.expectEqual(original_wave.samples.len, decoded_wave.samples.len);

    // Check sample accuracy (with small epsilon for float conversion)
    for (original_wave.samples, 0..) |s, i| {
        try std.testing.expectApproxEqAbs(s, decoded_wave.samples[i], 0.0001);
    }

    allocator.free(original_samples);
}
