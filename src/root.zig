const std = @import("std");
const riff = @import("riff");

/// Audio encoding format
pub const FormatCode = enum(u16) {
    pcm = 1,
    ieee_float = 3,
    _, // Unsupported
};

/// WAV structure representing audio properties and normalized samples
pub const Wave = struct {
    format_code: FormatCode,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    samples: []f128,

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

    var format_code: FormatCode = undefined;
    var sample_rate: u32 = undefined;
    var channels: u16 = undefined;
    var bits: u16 = undefined;
    var samples: []f128 = undefined;

    for (r.chunks) |c| {
        const id = c.chunk.four_cc.inner;

        if (std.mem.eql(u8, &id, "fmt ")) {
            const data = c.chunk.data;

            format_code = @enumFromInt(std.mem.readInt(u16, data[0..2], .little));
            channels = std.mem.readInt(u16, data[2..4], .little);
            sample_rate = std.mem.readInt(u32, data[4..8], .little);
            bits = std.mem.readInt(u16, data[14..16], .little);
        } else if (std.mem.eql(u8, &id, "data")) {
            const data = c.chunk.data;

            const samples_count = switch (bits) {
                8 => data.len, // 8bit PCM
                16 => data.len / 2, // 16bit PCM
                24 => data.len / 3, // 24bit PCM
                32 => switch (format_code) {
                    .pcm => data.len / 4, // 32bit PCM
                    .ieee_float => return error.NotImplemented, // 32bit IEEE Float
                    else => return error.UnsupportedFormatCode,
                },
                else => return error.UnsupportedBits,
            };
            var samples_list: []f128 = try allocator.alloc(f128, samples_count);
            errdefer allocator.free(samples_list);

            var i: usize = 0;
            while (i < samples_count) : (i += 1) {
                switch (bits) {
                    8 => {
                        const val = data[i];
                        samples_list[i] = @as(f128, @floatFromInt(val)) / std.math.maxInt(u8);
                    },
                    16 => {
                        const bytes_number = 2; // A i16 wave data's sample takes 2
                        const val = std.mem.readInt(i16, data[i * bytes_number .. (i + 1) * bytes_number][0..2], .little);
                        samples_list[i] = @as(f128, @floatFromInt(val)) / std.math.maxInt(i16);
                    },
                    24 => {
                        const bytes_number = 3; // A i24 wave data's sample takes 3
                        const val = std.mem.readInt(i24, data[i * bytes_number .. (i + 1) * bytes_number][0..bytes_number], .little);
                        samples_list[i] = @as(f128, @floatFromInt(val)) / std.math.maxInt(i24);
                    },
                    32 => switch (format_code) {
                        .pcm => {
                            const bytes_number = 4; // A i32 wave data's sample takes 4
                            const val = std.mem.readInt(i32, data[i * bytes_number .. (i + 1) * bytes_number][0..bytes_number], .little);
                            samples_list[i] = @as(f128, @floatFromInt(val)) / std.math.maxInt(i32);
                        },
                        .ieee_float => return error.NotImplemented,
                        else => return error.UnsupportedFormatCode,
                    },
                    else => return error.UnsupportedBits,
                }
            }

            samples = samples_list;
        }
    }

    return Wave{
        .format_code = format_code,
        .sample_rate = sample_rate,
        .channels = channels,
        .bits = bits,
        .samples = samples,
    };
}

test "read 8bit_pcm.wav" {
    const allocator = std.testing.allocator;

    const wavedata = @embedFile("./assets/8bit_pcm.wav");
    var reader = std.Io.Reader.fixed(wavedata);
    const result: Wave = try read(allocator, &reader);
    defer result.deinit(allocator);

    try std.testing.expectEqual(.pcm, result.format_code);
    try std.testing.expectEqual(44100, result.sample_rate);
    try std.testing.expectEqual(1, result.channels);
    try std.testing.expectEqual(8, result.bits);

    const expected_samples = &[_]f128{
        0.498039215686274509803921568627451,
        0.52549019607843137254901960784313725,
        0.5490196078431372549019607843137255,
        0.57647058823529411764705882352941175,
        0.6,
        0.6235294117647058823529411764705882,
        0.6470588235294117647058823529411764,
        0.6705882352941176470588235294117647,
        0.6941176470588235294117647058823529,
        0.7137254901960784313725490196078431,
    };
    try std.testing.expectEqualSlices(f128, expected_samples, result.samples);
}

test "read 16bit_pcm.wav" {
    const allocator = std.testing.allocator;

    const wavedata = @embedFile("./assets/16bit_pcm.wav");
    var reader = std.Io.Reader.fixed(wavedata);
    const result: Wave = try read(allocator, &reader);
    defer result.deinit(allocator);

    try std.testing.expectEqual(.pcm, result.format_code);
    try std.testing.expectEqual(44100, result.sample_rate);
    try std.testing.expectEqual(1, result.channels);
    try std.testing.expectEqual(16, result.bits);

    const expected_samples = &[_]f128{
        0.000030518509475997192297128208258308664,
        0.05005035554063539536729026154362621,
        0.10010071108127079073458052308725242,
        0.14954069643238624225592822046571245,
        0.19855342265083773308511612292855616,
        0.24668111209448530533768730735190894,
        0.2938322092349009674367503891109958,
        0.3399456770531327249977111117893002,
        0.3845942564165166173284096804712058,
        0.42780846583452864162114322336497085,
    };
    try std.testing.expectEqualSlices(f128, expected_samples, result.samples);
}

test "read 24bit_pcm.wav" {
    const allocator = std.testing.allocator;

    const wavedata = @embedFile("./assets/24bit_pcm.wav");
    var reader = std.Io.Reader.fixed(wavedata);
    const result: Wave = try read(allocator, &reader);
    defer result.deinit(allocator);

    try std.testing.expectEqual(.pcm, result.format_code);
    try std.testing.expectEqual(44100, result.sample_rate);
    try std.testing.expectEqual(1, result.channels);
    try std.testing.expectEqual(24, result.bits);

    const expected_samples = &[_]f128{
        0,
        0.050118690743290274535450283938680163,
        0.1000403285074625620201303982890127,
        0.1495694100343477766928406587649177,
        0.19851007443786554787940357677979192,
        0.24667170604130101696264946015470744,
        0.2938635699586355636877493486105619,
        0.3399014878155574578711340273778471,
        0.38460354621452644044476037559036917,
        0.4277952227348354738754598945927494,
    };
    try std.testing.expectEqualSlices(f128, expected_samples, result.samples);
}

test "read 32bit_pcm.wav" {
    const allocator = std.testing.allocator;

    const wavedata = @embedFile("./assets/32bit_pcm.wav");
    var reader = std.Io.Reader.fixed(wavedata);
    const result: Wave = try read(allocator, &reader);
    defer result.deinit(allocator);

    try std.testing.expectEqual(.pcm, result.format_code);
    try std.testing.expectEqual(44100, result.sample_rate);
    try std.testing.expectEqual(1, result.channels);
    try std.testing.expectEqual(32, result.bits);

    const expected_samples = &[_]f128{
        0,
        0.050118658714982987714457785577726453,
        0.10004042093643938234841422287207759,
        0.14956915385535413113206351694281378,
        0.1985102743834770630968162152435706,
        0.2466715277389956301725449181033973,
        0.29386368407582104395880412494708046,
        0.33990132824513191741198856263048415,
        0.38460361975459550495939119949908516,
        0.427794963320621737893960316616092,
    };
    try std.testing.expectEqualSlices(f128, expected_samples, result.samples);
}
