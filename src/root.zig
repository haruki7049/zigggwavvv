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
                .u8 => data.len,
                .i16 => data.len / 2,
                else => return error.NotImplemented,
            };
            var samples_list: []f32 = try allocator.alloc(f32, samples_count);
            errdefer allocator.free(samples_list);

            var i: usize = 0;
            while (i < samples_count) : (i += 1) {
                switch (bits) {
                    .u8 => {
                        const val = data[i];
                        samples_list[i] = @as(f32, @floatFromInt(val)) / std.math.maxInt(u8);
                    },
                    .i16 => {
                        const val = std.mem.readInt(i16, data[i * 2 .. (i + 1) * 2][0..2], .little);
                        samples_list[i] = @as(f32, @floatFromInt(val)) / std.math.maxInt(i16);
                    },
                    else => return error.NotImplemented,
                }
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

test "read 16bit_pcm.wav" {
    const allocator = std.testing.allocator;

    const wavedata = @embedFile("./assets/16bit_pcm.wav");
    var reader = std.Io.Reader.fixed(wavedata);
    const result: Wave = try read(allocator, &reader);
    defer result.deinit(allocator);

    try std.testing.expectEqual(44100, result.sample_rate);
    try std.testing.expectEqual(1, result.channels);
    try std.testing.expectEqual(.i16, result.bits);

    const expected_samples = &[_]f32{
        0.00003051851,
        0.050050355,
        0.10010071,
        0.1495407,
        0.19855343,
        0.24668111,
        0.2938322,
        0.33994567,
        0.38459426,
        0.42780846,
    };
    try std.testing.expectEqualSlices(f32, expected_samples, result.samples);
}

test "read 8bit_pcm.wav" {
    const allocator = std.testing.allocator;

    const wavedata = @embedFile("./assets/8bit_pcm.wav");
    var reader = std.Io.Reader.fixed(wavedata);
    const result: Wave = try read(allocator, &reader);
    defer result.deinit(allocator);

    try std.testing.expectEqual(44100, result.sample_rate);
    try std.testing.expectEqual(1, result.channels);
    try std.testing.expectEqual(.u8, result.bits);

    const expected_samples = &[_]f32{
        0.49803922,
        0.5254902,
        0.54901963,
        0.5764706,
        0.6,
        0.62352943,
        0.64705884,
        0.67058825,
        0.69411767,
        0.7137255,
    };
    try std.testing.expectEqualSlices(f32, expected_samples, result.samples);
}
