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

            // We only support PCM and IEEE Float
            if (format_code != .pcm and format_code != .ieee_float)
                return error.UnsupportedFormatCode;

            // We only support 8, 16, 24 and 32 bits
            const supported_bits: []const u16 = &[_]u16{ 8, 16, 24, 32 };
            for (supported_bits) |v| {
                if (v == bits)
                    break;
            } else return error.UnsupportedBits;
        } else if (std.mem.eql(u8, &id, "data")) {
            const data = c.chunk.data;

            const samples_count = switch (bits) {
                8 => data.len, // 8bit
                16 => data.len / 2, // 16bit
                24 => data.len / 3, // 24bit
                32 => data.len / 4, // 32bit
                else => unreachable,
            };
            var samples_list: []f128 = try allocator.alloc(f128, samples_count);
            errdefer allocator.free(samples_list);

            for (0..samples_count) |i| {
                switch (bits) {
                    8 => {
                        const val: u8 = data[i];
                        samples_list[i] = @as(f128, @floatFromInt(val)) / std.math.maxInt(u8);
                    },
                    16 => {
                        const bytes_number = 2; // A i16 wave data's sample takes 2
                        const val: i16 = std.mem.readInt(i16, data[i * bytes_number .. (i + 1) * bytes_number][0..2], .little);
                        samples_list[i] = @as(f128, @floatFromInt(val)) / std.math.maxInt(i16);
                    },
                    24 => {
                        const bytes_number = 3; // A i24 wave data's sample takes 3
                        const val: i24 = std.mem.readInt(i24, data[i * bytes_number .. (i + 1) * bytes_number][0..bytes_number], .little);
                        samples_list[i] = @as(f128, @floatFromInt(val)) / std.math.maxInt(i24);
                    },
                    32 => switch (format_code) {
                        .pcm => {
                            const bytes_number = 4; // A i32 wave data's sample takes 4
                            const val: i32 = std.mem.readInt(i32, data[i * bytes_number .. (i + 1) * bytes_number][0..bytes_number], .little);
                            samples_list[i] = @as(f128, @floatFromInt(val)) / std.math.maxInt(i32);
                        },
                        .ieee_float => {
                            const bytes_number = 4;
                            const val: f32 = @bitCast(std.mem.readInt(u32, data[i * bytes_number .. (i + 1) * bytes_number][0..bytes_number], .little));
                            samples_list[i] = @as(f128, val);
                        },
                        else => unreachable,
                    },
                    else => unreachable,
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

test "read 32bit_ieee_float.wav" {
    const allocator = std.testing.allocator;

    const wavedata = @embedFile("./assets/32bit_ieee_float.wav");
    var reader = std.Io.Reader.fixed(wavedata);
    const result = try read(allocator, &reader);
    defer result.deinit(allocator);

    try std.testing.expectEqual(.ieee_float, result.format_code);
    try std.testing.expectEqual(44100, result.sample_rate);
    try std.testing.expectEqual(1, result.channels);
    try std.testing.expectEqual(32, result.bits);

    const expected_samples = &[_]f128{
        0,
        0.0501186586916446685791015625,
        0.10004042088985443115234375,
        0.14956915378570556640625,
        0.19851027429103851318359375,
        0.2466715276241302490234375,
        0.2938636839389801025390625,
        0.33990132808685302734375,
        0.38460361957550048828125,
        0.4277949631214141845703125,
    };
    try std.testing.expectEqualSlices(f128, expected_samples, result.samples);
}

test "Fail to read 64bit_ieee_float.wav" {
    const allocator = std.testing.allocator;

    const wavedata = @embedFile("./assets/64bit_ieee_float.wav");
    var reader = std.Io.Reader.fixed(wavedata);
    const result = read(allocator, &reader);

    try std.testing.expectError(error.UnsupportedBits, result);
}

pub fn write(wave: Wave, writer: anytype, allocator: std.mem.Allocator) anyerror!void {
    const bits_per_sample: u16 = wave.bits;
    const block_align = wave.channels * (bits_per_sample / 8);
    const bytes_per_sec = wave.sample_rate * block_align;

    // Wave fmt chunk
    var fmt_payload = std.Io.Writer.Allocating.init(allocator);
    defer fmt_payload.deinit();
    const fw = &fmt_payload.writer;

    try fw.writeInt(u16, @intFromEnum(wave.format_code), .little);
    try fw.writeInt(u16, wave.channels, .little);
    try fw.writeInt(u32, wave.sample_rate, .little);
    try fw.writeInt(u32, bytes_per_sec, .little);
    try fw.writeInt(u16, block_align, .little);
    try fw.writeInt(u16, bits_per_sample, .little);

    // Wave data chunk
    var data_payload = std.Io.Writer.Allocating.init(allocator);
    defer data_payload.deinit();
    const dw = &data_payload.writer;

    for (wave.samples) |s| {
        switch (wave.bits) {
            8 => switch (wave.format_code) {
                .pcm => {
                    const val: u8 = @intFromFloat(std.math.clamp(s * std.math.maxInt(u8), -std.math.maxInt(u8), std.math.maxInt(u8) - 1));
                    try dw.writeInt(u8, val, .little);
                },
                else => return error.UnsupportedFormatCode,
            },
            16 => switch (wave.format_code) {
                .pcm => {
                    const val: i16 = @intFromFloat(std.math.clamp(s * std.math.maxInt(i16), -std.math.maxInt(i16), std.math.maxInt(i16) - 1));
                    try dw.writeInt(i16, val, .little);
                },
                else => return error.UnsupportedFormatCode,
            },
            24 => switch (wave.format_code) {
                .pcm => {
                    const val: i24 = @intFromFloat(std.math.clamp(s * std.math.maxInt(i24), -std.math.maxInt(i24), std.math.maxInt(i24) - 1));
                    try dw.writeInt(i24, val, .little);
                },
                else => return error.UnsupportedFormatCode,
            },
            32 => switch (wave.format_code) {
                .pcm => {
                    const val: i32 = @intFromFloat(std.math.clamp(s * std.math.maxInt(i32), -std.math.maxInt(i32), std.math.maxInt(i32) - 1));
                    try dw.writeInt(i32, val, .little);
                },
                else => return error.UnsupportedFormatCode,
            },
            else => return error.UnsupportedBits,
        }
    }

    const chunks = try allocator.alloc(riff.Chunk, 2);
    chunks[0] = .{ .chunk = .{ .four_cc = try riff.FourCC.new("fmt "), .data = try allocator.dupe(u8, fmt_payload.written()) } };
    chunks[1] = .{ .chunk = .{ .four_cc = try riff.FourCC.new("data"), .data = try allocator.dupe(u8, data_payload.written()) } };

    const wave_riff = riff.Chunk{ .riff = .{ .four_cc = try riff.FourCC.new("WAVE"), .chunks = chunks } };
    defer wave_riff.deinit(allocator);

    try riff.write(wave_riff, allocator, writer);
}

test "write 8bit_pcm.wav" {
    const allocator = std.testing.allocator;

    var samples = [_]f128{
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
    const result: Wave = Wave{
        .format_code = .pcm,
        .sample_rate = 44100,
        .channels = 1,
        .bits = 8,
        .samples = &samples,
    };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(result, &w.writer, allocator);

    const expected = @embedFile("./assets/8bit_pcm.wav");
    try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
}

test "write 16bit_pcm.wav" {
    const allocator = std.testing.allocator;

    var samples = [_]f128{
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
    const result: Wave = Wave{
        .format_code = .pcm,
        .sample_rate = 44100,
        .channels = 1,
        .bits = 16,
        .samples = &samples,
    };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(result, &w.writer, allocator);

    const expected = @embedFile("./assets/16bit_pcm.wav");
    try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
}

test "write 24bit_pcm.wav" {
    const allocator = std.testing.allocator;

    var samples = [_]f128{
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
    const result: Wave = Wave{
        .format_code = .pcm,
        .sample_rate = 44100,
        .channels = 1,
        .bits = 24,
        .samples = &samples,
    };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(result, &w.writer, allocator);

    const expected = @embedFile("./assets/24bit_pcm.wav");
    try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
}

test "write 32bit_pcm.wav" {
    const allocator = std.testing.allocator;

    var samples = [_]f128{
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
    const result: Wave = Wave{
        .format_code = .pcm,
        .sample_rate = 44100,
        .channels = 1,
        .bits = 32,
        .samples = &samples,
    };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(result, &w.writer, allocator);

    const expected = @embedFile("./assets/32bit_pcm.wav");
    try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
}
