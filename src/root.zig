const std = @import("std");
const riff = @import("riff");

/// Audio sample bit depth
pub const Bits = enum {
    u8,
    i16,
    i24,
    f32,

    pub fn to_format_code(bits: Bits) FormatCode {
        return switch (bits) {
            .u8, .i16, .i24 => .pcm,
            .f32 => .ieee_float,
        };
    }
};

/// Audio encoding format
pub const FormatCode = enum(u16) {
    pcm = 1,
    ieee_float = 3,
    _,
};

/// WAV structure representing audio properties and normalized samples
pub const Wave = struct {
    sample_rate: u32,
    channels: u16,
    bits: Bits,
    samples: []f32,

    pub fn deinit(self: Wave, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }
};

pub fn read(allocator: std.mem.Allocator, reader: anytype) anyerror!Wave {
    const root_chunk = try riff.read(allocator, reader);
    defer root_chunk.deinit(allocator);

    const r = switch (root_chunk) {
        .riff => |r| if (std.mem.eql(u8, &r.four_cc.inner, "WAVE")) r else return error.InvalidFormat,
        else => return error.InvalidFormat,
    };

    var sample_rate: u32 = undefined;
    var channels: u16 = undefined;
    var bits: Bits = undefined;
    var samples: []f32 = undefined;

    for (r.chunks) |c| {
        const id = c.chunk.four_cc.inner;

        if (std.mem.eql(u8, &id, "fmt ")) {
            const data = c.chunk.data;

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

            const samples_count = switch (bits) {
                .i16 => data.len / 2,
                else => return error.NotImplemented,
            };
            var samples_list: []f32 = try allocator.alloc(f32, samples_count);

            var i: usize = 0;
            while (i < samples_count) : (i += 1) {
                const val = std.mem.readInt(i16, data[i * 2 .. (i + 1) * 2][0..2], .little);
                samples_list[i] = @as(f32, @floatFromInt(val)) / 32768.0;
            }

            samples = samples_list;
        }
    }

    return Wave{
        .sample_rate = sample_rate,
        .channels = channels,
        .bits = bits,
        .samples = samples,
    };
}

test "read i16_pcm.wav" {
    const allocator = std.testing.allocator;

    const wavedata = @embedFile("./assets/i16_pcm.wav");
    var reader = std.Io.Reader.fixed(wavedata);
    const result: Wave = try read(allocator, &reader);
    defer result.deinit(allocator);

    try std.testing.expectEqual(44100, result.sample_rate);
    try std.testing.expectEqual(1, result.channels);
    try std.testing.expectEqual(.i16, result.bits);

    const expected_samples = &[_]f32{ 0.000030517578, 0.050048828, 0.100097656, 0.14953613, 0.19854736, 0.24667358, 0.29382324, 0.3399353, 0.38458252, 0.4277954 };
    try std.testing.expectEqualSlices(f32, expected_samples, result.samples);
}
