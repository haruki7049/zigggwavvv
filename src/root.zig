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

pub const FromBytesError = riff.Error || error{
    InvalidFormat,
    NotImplemented,
};

pub fn from_bytes(allocator: std.mem.Allocator, bytes: []const u8) FromBytesError!Wave {
    const root_chunk = try riff.from_slice(allocator, bytes);
    defer root_chunk.deinit(allocator);

    const r = switch (root_chunk) {
        .riff => |r| if (std.mem.eql(u8, &r.four_cc, "WAVE")) r else return error.InvalidFormat,
        else => return error.InvalidFormat,
    };

    var sample_rate: u32 = undefined;
    var channels: u16 = undefined;
    var bits: Bits = undefined;
    var samples: []f32 = undefined;

    for (r.chunks) |c| {
        const id = c.chunk.four_cc;

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
                const val = std.mem.readInt();
                samples_list[i] = @floatFromInt(val);
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
