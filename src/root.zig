//! zigggwavvv - A Zig library for reading and writing WAV audio files
//!
//! This library provides functionality to parse and generate WAV (Waveform Audio File Format)
//! files using the RIFF container format. It supports both PCM and IEEE float audio formats
//! with various bit depths (8, 16, 24, 32, and 64-bit).
//!
//! The library provides flexible type support for audio sample processing, allowing you to
//! choose the sample precision (f64, f80, or f128) based on your needs.
//!
//! ## Main Features
//! - Read WAV files with `Wave(T).read()` method
//! - Write WAV files with `wave.write()` method
//! - Support for PCM format (8, 16, 24, 32-bit)
//! - Support for IEEE float format (32, 64-bit)
//! - Flexible sample type support (f64, f80, f128)
//! - Optional fact and PEAK chunk generation for writing
//!
//! ## Example Usage
//! ```zig
//! const wave = try Wave(f128).read(allocator, reader);
//! defer wave.deinit(allocator);
//! // Process wave.samples...
//! ```

const std = @import("std");
const riff = @import("riff");

/// Audio encoding format
pub const FormatCode = enum(u16) {
    pcm = 1,
    ieee_float = 3,
    _, // Unsupported
};

/// WAV structure representing audio properties and samples of type T
pub fn Wave(comptime T: type) type {
    if (@typeInfo(T) != .float)
        @compileError("Wave(T) requires a floating point type, found " ++ @typeName(T));

    return struct {
        const Self = @This();

        format_code: FormatCode,
        sample_rate: u32,
        channels: u16,
        bits: u16,
        samples: []T,

        /// Deinitializes the Wave structure and frees the allocated samples memory
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.samples);
        }

        pub const InitOptions = struct {
            format_code: FormatCode,
            sample_rate: u32,
            channels: u16,
            bits: u16,
            samples: []T,
        };

        pub fn init(options: InitOptions) Self {
            return .{
                .format_code = options.format_code,
                .sample_rate = options.sample_rate,
                .channels = options.channels,
                .bits = options.bits,
                .samples = options.samples,
            };
        }

        /// Reads a WAV file from the provided reader and returns a Wave structure.
        ///
        /// This function parses the RIFF/WAVE file format and extracts audio data,
        /// converting samples to normalized values of the specified type T. Supports PCM
        /// and IEEE float formats with 8, 16, 24, 32, and 64-bit sample depths.
        ///
        /// The sample data type is the type parameter T of `Wave(T)` (e.g., f64, f80, f128).
        ///
        /// Parameters:
        ///   - allocator: Memory allocator for sample data
        ///   - reader: Reader interface providing the WAV file data
        ///
        /// Returns:
        ///   - Wave(T) structure containing the parsed audio data with samples of type T
        ///
        /// Errors:
        ///   - InvalidFormat: Not a valid WAVE file
        ///   - UnsupportedFormatCode: Audio format not supported
        ///   - UnsupportedBits: Bit depth not supported
        pub fn read(allocator: std.mem.Allocator, reader: anytype) anyerror!Self {
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
            var samples: []T = undefined;
            var fmt_read = false;
            var data_read = false;
            errdefer if (data_read) allocator.free(samples);

            for (r.chunks) |c| {
                // Skip chunks that are not plain chunks, such as LIST
                const chunk = switch (c) {
                    .chunk => |chunk| chunk,
                    else => continue,
                };
                const id = chunk.four_cc.inner;

                if (std.mem.eql(u8, &id, "fmt ")) {
                    const data = chunk.data;

                    if (data.len < 16)
                        return error.InvalidFormat;

                    format_code = @enumFromInt(std.mem.readInt(u16, data[0..2], .little));
                    channels = std.mem.readInt(u16, data[2..4], .little);
                    sample_rate = std.mem.readInt(u32, data[4..8], .little);
                    bits = std.mem.readInt(u16, data[14..16], .little);
                    fmt_read = true;

                    // We only support PCM and IEEE Float
                    if (format_code != .pcm and format_code != .ieee_float)
                        return error.UnsupportedFormatCode;

                    // We only support 8, 16, 24, 32 and 64 bits
                    const supported_bits: []const u16 = &[_]u16{ 8, 16, 24, 32, 64 };
                    for (supported_bits) |v| {
                        if (v == bits)
                            break;
                    } else return error.UnsupportedBits;
                } else if (std.mem.eql(u8, &id, "data")) {
                    const data = chunk.data;

                    // The fmt chunk must precede the data chunk
                    if (!fmt_read)
                        return error.InvalidFormat;

                    // A WAV file has exactly one data chunk
                    if (data_read)
                        return error.InvalidFormat;

                    const samples_count = switch (bits) {
                        8 => data.len, // 8bit
                        16 => data.len / 2, // 16bit
                        24 => data.len / 3, // 24bit
                        32 => data.len / 4, // 32bit
                        64 => data.len / 8, // 64bit
                        else => unreachable,
                    };
                    var samples_list: []T = try allocator.alloc(T, samples_count);
                    errdefer allocator.free(samples_list);

                    for (0..samples_count) |i|
                        samples_list[i] = try decodeSample(bits, format_code, data, i);

                    samples = samples_list;
                    data_read = true;
                }
            }

            if (!fmt_read or !data_read)
                return error.InvalidFormat;

            return Wave(T).init(.{
                .format_code = format_code,
                .sample_rate = sample_rate,
                .channels = channels,
                .bits = bits,
                .samples = samples,
            });
        }

        /// Decodes the `i`-th sample of a data chunk into a normalized value of type T
        fn decodeSample(bits: u16, format_code: FormatCode, data: []const u8, i: usize) error{UnsupportedFormatCode}!T {
            switch (bits) {
                8 => switch (format_code) {
                    .pcm => {
                        const val: u8 = data[i];
                        return @as(T, @floatFromInt(val)) / std.math.maxInt(u8);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                16 => switch (format_code) {
                    .pcm => {
                        const bytes_number = 2; // A i16 wave data's sample takes 2
                        const val: i16 = std.mem.readInt(i16, data[i * bytes_number ..][0..bytes_number], .little);
                        return @as(T, @floatFromInt(val)) / std.math.maxInt(i16);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                24 => switch (format_code) {
                    .pcm => {
                        const bytes_number = 3; // A i24 wave data's sample takes 3
                        const val: i24 = std.mem.readInt(i24, data[i * bytes_number ..][0..bytes_number], .little);
                        return @as(T, @floatFromInt(val)) / std.math.maxInt(i24);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                32 => switch (format_code) {
                    .pcm => {
                        const bytes_number = 4; // A i32 wave data's sample takes 4
                        const val: i32 = std.mem.readInt(i32, data[i * bytes_number ..][0..bytes_number], .little);
                        return @as(T, @floatFromInt(val)) / std.math.maxInt(i32);
                    },
                    .ieee_float => {
                        const bytes_number = 4;
                        const val: f32 = @bitCast(std.mem.readInt(u32, data[i * bytes_number ..][0..bytes_number], .little));
                        return @as(T, val);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                64 => switch (format_code) {
                    .ieee_float => {
                        const bytes_number = 8;
                        const val: f64 = @bitCast(std.mem.readInt(u64, data[i * bytes_number ..][0..bytes_number], .little));
                        return @as(T, val);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                else => unreachable,
            }
        }

        /// Appends a chunk with a copy of `payload`, freeing the copy if appending fails
        fn appendChunk(
            list: *std.array_list.Aligned(riff.Chunk, null),
            allocator: std.mem.Allocator,
            id: []const u8,
            payload: []const u8,
        ) !void {
            const data = try allocator.dupe(u8, payload);
            errdefer allocator.free(data);
            try list.append(allocator, .{ .chunk = .{ .four_cc = try riff.FourCC.new(id), .data = data } });
        }

        /// Options for writing WAV files
        pub const WriteOptions = struct {
            /// Memory allocator for temporary buffers during writing
            allocator: std.mem.Allocator,
            /// Include 'fact' chunk in the output (typically used for non-PCM formats)
            use_fact: bool = false,
            /// Include 'PEAK' chunk containing peak amplitude information
            use_peak: bool = false,
            /// Timestamp for the PEAK chunk (Unix time or 0)
            peak_timestamp: u32 = 0,
        };

        /// Writes a Wave structure to a WAV file format.
        ///
        /// This function converts the normalized samples of type T back to the format specified
        /// by the Wave structure's fields (format_code, bits, channels, sample_rate) and
        /// writes a complete RIFF/WAVE file with appropriate chunks (fmt, data, and
        /// optionally fact and PEAK chunks).
        ///
        /// Parameters:
        ///   - self: The Wave(T) structure containing the audio data to write
        ///   - writer: Writer interface where the WAV file will be written
        ///   - options: WriteOptions specifying allocator and optional chunks
        ///
        /// Errors:
        ///   - UnsupportedFormatCode: Audio format not supported for writing
        ///   - UnsupportedBits: Bit depth not supported for writing
        ///   - InvalidChannels: The number of channels is 0
        pub fn write(
            self: Self,
            writer: anytype,
            options: WriteOptions,
        ) anyerror!void {
            if (self.channels == 0)
                return error.InvalidChannels;

            // Validate the format before writing anything, so that it is rejected even when there are no samples
            switch (self.bits) {
                8, 16, 24 => if (self.format_code != .pcm) return error.UnsupportedFormatCode,
                32 => if (self.format_code != .pcm and self.format_code != .ieee_float) return error.UnsupportedFormatCode,
                64 => if (self.format_code != .ieee_float) return error.UnsupportedFormatCode,
                else => return error.UnsupportedBits,
            }

            var chunk_list: std.array_list.Aligned(riff.Chunk, null) = .empty;
            errdefer {
                for (chunk_list.items) |c| c.deinit(options.allocator);
                chunk_list.deinit(options.allocator);
            }

            const bits_per_sample: u16 = self.bits;
            const block_align = self.channels * (bits_per_sample / 8);
            const bytes_per_sec = self.sample_rate * block_align;

            // Wave fmt chunk
            {
                var fmt_payload = std.Io.Writer.Allocating.init(options.allocator);
                defer fmt_payload.deinit();
                const fw = &fmt_payload.writer;

                try fw.writeInt(u16, @intFromEnum(self.format_code), .little);
                try fw.writeInt(u16, self.channels, .little);
                try fw.writeInt(u32, self.sample_rate, .little);
                try fw.writeInt(u32, bytes_per_sec, .little);
                try fw.writeInt(u16, block_align, .little);
                try fw.writeInt(u16, bits_per_sample, .little);

                try appendChunk(&chunk_list, options.allocator, "fmt ", fmt_payload.written());
            }

            // Wave fact chunk
            if (options.use_fact) {
                var fact_payload = std.Io.Writer.Allocating.init(options.allocator);
                defer fact_payload.deinit();
                const fw = &fact_payload.writer;

                try fw.writeInt(u32, @intCast(self.samples.len / self.channels), .little);
                try appendChunk(&chunk_list, options.allocator, "fact", fact_payload.written());
            }

            // Wave PEAK chunk
            if (options.use_peak) {
                var peak_payload = std.Io.Writer.Allocating.init(options.allocator);
                defer peak_payload.deinit();
                const pw = &peak_payload.writer;

                // Version (usually 1)
                try pw.writeInt(u32, 1, .little);
                // Timestamp (Unix time or 0)
                try pw.writeInt(u32, options.peak_timestamp, .little);

                // Calculate peak for each channel
                for (0..self.channels) |ch| {
                    var max_val: f32 = 0;
                    var max_pos: u32 = 0;

                    var i: usize = ch;
                    while (i < self.samples.len) : (i += self.channels) {
                        const abs_val = @abs(@as(f32, @floatCast(self.samples[i])));
                        if (abs_val > max_val) {
                            max_val = abs_val;
                            max_pos = @intCast(i / self.channels);
                        }
                    }

                    try pw.writeAll(std.mem.asBytes(&max_val));
                    try pw.writeInt(u32, max_pos, .little);
                }

                try appendChunk(&chunk_list, options.allocator, "PEAK", peak_payload.written());
            }

            // Wave data chunk
            {
                var data_payload = std.Io.Writer.Allocating.init(options.allocator);
                defer data_payload.deinit();
                const dw = &data_payload.writer;

                for (self.samples) |s| {
                    switch (self.bits) {
                        8 => switch (self.format_code) {
                            .pcm => {
                                const val: u8 = @intFromFloat(std.math.clamp(s * std.math.maxInt(u8), 0, std.math.maxInt(u8) - 1));
                                try dw.writeInt(u8, val, .little);
                            },
                            else => return error.UnsupportedFormatCode,
                        },
                        16 => switch (self.format_code) {
                            .pcm => {
                                const val: i16 = @intFromFloat(std.math.clamp(s * std.math.maxInt(i16), -std.math.maxInt(i16), std.math.maxInt(i16) - 1));
                                try dw.writeInt(i16, val, .little);
                            },
                            else => return error.UnsupportedFormatCode,
                        },
                        24 => switch (self.format_code) {
                            .pcm => {
                                const val: i24 = @intFromFloat(std.math.clamp(s * std.math.maxInt(i24), -std.math.maxInt(i24), std.math.maxInt(i24) - 1));
                                try dw.writeInt(i24, val, .little);
                            },
                            else => return error.UnsupportedFormatCode,
                        },
                        32 => switch (self.format_code) {
                            .pcm => {
                                const val: i32 = @intFromFloat(std.math.clamp(s * std.math.maxInt(i32), -std.math.maxInt(i32), std.math.maxInt(i32) - 1));
                                try dw.writeInt(i32, val, .little);
                            },
                            .ieee_float => {
                                const val: f32 = @floatCast(s);
                                try dw.writeInt(u32, @bitCast(val), .little);
                            },
                            else => return error.UnsupportedFormatCode,
                        },
                        64 => switch (self.format_code) {
                            .ieee_float => {
                                const val: f64 = @floatCast(s);
                                try dw.writeInt(u64, @bitCast(val), .little);
                            },
                            else => return error.UnsupportedFormatCode,
                        },
                        else => return error.UnsupportedBits,
                    }
                }

                try appendChunk(&chunk_list, options.allocator, "data", data_payload.written());
            }

            const wave_riff = riff.Chunk{ .riff = .{ .four_cc = try riff.FourCC.new("WAVE"), .chunks = try chunk_list.toOwnedSlice(options.allocator) } };
            defer wave_riff.deinit(options.allocator);

            try riff.write(wave_riff, options.allocator, writer);
        }

        test "read 8bit_pcm.wav" {
            const allocator = std.testing.allocator;

            const wavedata = @embedFile("./assets/8bit_pcm.wav");
            var reader = std.Io.Reader.fixed(wavedata);
            const result: Wave(T) = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(.pcm, result.format_code);
            try std.testing.expectEqual(44100, result.sample_rate);
            try std.testing.expectEqual(1, result.channels);
            try std.testing.expectEqual(8, result.bits);

            const expected_samples = &[_]T{
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
            try std.testing.expectEqualSlices(T, expected_samples, result.samples);
        }

        test "write and read multichannel samples" {
            const allocator = std.testing.allocator;

            var samples = [_]T{ 0, 0.5, 0.25, -0.5 };
            const wave = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 2,
                .bits = 16,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try wave.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = true,
                .use_peak = true,
            });

            // RIFF header (12) + fmt (24) + fact (12) + PEAK (8 + 8 + 8 * 2 channels) + data (8 + 8)
            try std.testing.expectEqual(96, w.writer.buffered().len);

            var reader = std.Io.Reader.fixed(w.writer.buffered());
            const result = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(2, result.channels);
            try std.testing.expectEqual(samples.len, result.samples.len);
            for (samples, result.samples) |expected, actual| {
                try std.testing.expectApproxEqAbs(expected, actual, 1.0 / 32767.0);
            }
        }

        test "write and read empty samples" {
            const allocator = std.testing.allocator;

            var samples = [_]T{};
            const wave = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 1,
                .bits = 16,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try wave.write(&w.writer, .{ .allocator = allocator });

            var reader = std.Io.Reader.fixed(w.writer.buffered());
            const result = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(0, result.samples.len);
        }

        test "read 16bit_pcm.wav" {
            const allocator = std.testing.allocator;

            const wavedata = @embedFile("./assets/16bit_pcm.wav");
            var reader = std.Io.Reader.fixed(wavedata);
            const result: Wave(T) = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(.pcm, result.format_code);
            try std.testing.expectEqual(44100, result.sample_rate);
            try std.testing.expectEqual(1, result.channels);
            try std.testing.expectEqual(16, result.bits);

            const expected_samples = &[_]T{
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
            try std.testing.expectEqualSlices(T, expected_samples, result.samples);
        }

        test "read 24bit_pcm.wav" {
            const allocator = std.testing.allocator;

            const wavedata = @embedFile("./assets/24bit_pcm.wav");
            var reader = std.Io.Reader.fixed(wavedata);
            const result: Wave(T) = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(.pcm, result.format_code);
            try std.testing.expectEqual(44100, result.sample_rate);
            try std.testing.expectEqual(1, result.channels);
            try std.testing.expectEqual(24, result.bits);

            const expected_samples = &[_]T{
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
            try std.testing.expectEqualSlices(T, expected_samples, result.samples);
        }

        test "read 32bit_pcm.wav" {
            const allocator = std.testing.allocator;

            const wavedata = @embedFile("./assets/32bit_pcm.wav");
            var reader = std.Io.Reader.fixed(wavedata);
            const result: Wave(T) = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(.pcm, result.format_code);
            try std.testing.expectEqual(44100, result.sample_rate);
            try std.testing.expectEqual(1, result.channels);
            try std.testing.expectEqual(32, result.bits);

            const expected_samples = &[_]T{
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
            try std.testing.expectEqualSlices(T, expected_samples, result.samples);
        }

        test "read 32bit_ieee_float.wav" {
            const allocator = std.testing.allocator;

            const wavedata = @embedFile("./assets/32bit_ieee_float.wav");
            var reader = std.Io.Reader.fixed(wavedata);
            const result = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(.ieee_float, result.format_code);
            try std.testing.expectEqual(44100, result.sample_rate);
            try std.testing.expectEqual(1, result.channels);
            try std.testing.expectEqual(32, result.bits);

            const expected_samples = &[_]T{
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
            try std.testing.expectEqualSlices(T, expected_samples, result.samples);
        }

        test "read 64bit_ieee_float.wav" {
            const allocator = std.testing.allocator;

            const wavedata = @embedFile("./assets/64bit_ieee_float.wav");
            var reader = std.Io.Reader.fixed(wavedata);
            const result = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(.ieee_float, result.format_code);
            try std.testing.expectEqual(44100, result.sample_rate);
            try std.testing.expectEqual(1, result.channels);
            try std.testing.expectEqual(64, result.bits);

            const expected_samples = &[_]T{
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
            try std.testing.expectEqualSlices(T, expected_samples, result.samples);
        }

        test "write 8bit_pcm.wav" {
            const allocator = std.testing.allocator;

            var samples = [_]T{
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
            const result: Wave(T) = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 1,
                .bits = 8,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try result.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = false,
            });

            const expected = @embedFile("./assets/8bit_pcm.wav");
            try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
        }

        test "write fails with zero channels" {
            const allocator = std.testing.allocator;

            var samples = [_]T{};
            const wave = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 0,
                .bits = 16,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try std.testing.expectError(error.InvalidChannels, wave.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = true,
                .use_peak = true,
            }));
        }

        test "write fails with unsupported bits or format code even without samples" {
            const allocator = std.testing.allocator;

            const cases = [_]struct { FormatCode, u16, anyerror }{
                .{ .pcm, 12, error.UnsupportedBits },
                .{ .pcm, 64, error.UnsupportedFormatCode },
                .{ .ieee_float, 16, error.UnsupportedFormatCode },
                .{ @enumFromInt(2), 16, error.UnsupportedFormatCode },
            };

            for (cases) |case| {
                var samples = [_]T{};
                const wave = Wave(T).init(.{
                    .format_code = case[0],
                    .sample_rate = 44100,
                    .channels = 1,
                    .bits = case[1],
                    .samples = &samples,
                });

                var w = std.Io.Writer.Allocating.init(allocator);
                defer w.deinit();
                try std.testing.expectError(case[2], wave.write(&w.writer, .{ .allocator = allocator }));
            }
        }

        fn testWriteOnce(allocator: std.mem.Allocator) !void {
            var samples = [_]T{ 0, 0.25, 0.5, 0.75 };
            const wave = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 2,
                .bits = 16,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            // std.Io.Writer.Allocating reports an allocation failure as WriteFailed
            wave.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = true,
                .use_peak = true,
            }) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
        }

        test "write does not leak when an allocation fails" {
            try std.testing.checkAllAllocationFailures(std.testing.allocator, testWriteOnce, .{});
        }

        test "write 16bit_pcm.wav" {
            const allocator = std.testing.allocator;

            var samples = [_]T{
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
            const result: Wave(T) = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 1,
                .bits = 16,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try result.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = false,
            });

            const expected = @embedFile("./assets/16bit_pcm.wav");
            try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
        }

        test "write clamps negative samples to zero for 8bit pcm" {
            const allocator = std.testing.allocator;

            var samples = [_]T{ -1, -0.5, 0 };
            const wave = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 1,
                .bits = 8,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try wave.write(&w.writer, .{ .allocator = allocator });

            // RIFF header (12) + fmt chunk (24) + data chunk header (8); the data chunk is then padded to an even length
            const data_offset = 44;
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0 }, w.writer.buffered()[data_offset .. data_offset + samples.len]);
        }

        test "write 24bit_pcm.wav" {
            const allocator = std.testing.allocator;

            var samples = [_]T{
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
            const result: Wave(T) = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 1,
                .bits = 24,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try result.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = false,
            });

            const expected = @embedFile("./assets/24bit_pcm.wav");
            try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
        }

        test "write then read round-trips every supported format" {
            const allocator = std.testing.allocator;

            const cases = [_]struct { format_code: FormatCode, bits: u16, tolerance: T }{
                .{ .format_code = .pcm, .bits = 8, .tolerance = 1.0 / 255.0 },
                .{ .format_code = .pcm, .bits = 16, .tolerance = 1.0 / 32767.0 },
                .{ .format_code = .pcm, .bits = 24, .tolerance = 1.0 / 8388607.0 },
                .{ .format_code = .pcm, .bits = 32, .tolerance = 1.0 / 2147483647.0 },
                .{ .format_code = .ieee_float, .bits = 32, .tolerance = 0 },
                .{ .format_code = .ieee_float, .bits = 64, .tolerance = 0 },
            };

            // Non-negative values, so that 8bit PCM (unsigned) is covered as well
            var samples = [_]T{ 0, 0.25, 0.5, 0.75 };

            for (cases) |case| {
                const wave = Wave(T).init(.{
                    .format_code = case.format_code,
                    .sample_rate = 44100,
                    .channels = 1,
                    .bits = case.bits,
                    .samples = &samples,
                });

                var w = std.Io.Writer.Allocating.init(allocator);
                defer w.deinit();
                try wave.write(&w.writer, .{ .allocator = allocator });

                var reader = std.Io.Reader.fixed(w.writer.buffered());
                const result = try Wave(T).read(allocator, &reader);
                defer result.deinit(allocator);

                try std.testing.expectEqual(case.format_code, result.format_code);
                try std.testing.expectEqual(case.bits, result.bits);
                try std.testing.expectEqual(@as(u32, 44100), result.sample_rate);
                try std.testing.expectEqual(@as(u16, 1), result.channels);
                try std.testing.expectEqual(samples.len, result.samples.len);
                for (samples, result.samples) |expected, actual| {
                    try std.testing.expectApproxEqAbs(expected, actual, case.tolerance);
                }
            }
        }

        test "write 32bit_pcm.wav" {
            const allocator = std.testing.allocator;

            var samples = [_]T{
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
            const result: Wave(T) = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 1,
                .bits = 32,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try result.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = false,
            });

            const expected = @embedFile("./assets/32bit_pcm.wav");
            try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
        }

        test "write 32bit_ieee_float.wav" {
            const allocator = std.testing.allocator;

            var samples = [_]T{
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
            const result: Wave(T) = Wave(T).init(.{
                .format_code = .ieee_float,
                .sample_rate = 44100,
                .channels = 1,
                .bits = 32,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try result.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = true,
                .use_peak = true,
                .peak_timestamp = 0x695DE0F8,
            });

            const expected = @embedFile("./assets/32bit_ieee_float.wav");
            try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
        }

        test "write 64bit_ieee_float.wav" {
            const allocator = std.testing.allocator;

            var samples = [_]T{
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
            const result: Wave(T) = Wave(T).init(.{
                .format_code = .ieee_float,
                .sample_rate = 44100,
                .channels = 1,
                .bits = 64,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try result.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = true,
                .use_peak = true,
                .peak_timestamp = 0x695DE11A,
            });

            const expected = @embedFile("./assets/64bit_ieee_float.wav");
            try std.testing.expectEqualSlices(u8, expected, w.writer.buffered());
        }

        fn testChunk(id: []const u8, data: []const u8) !riff.Chunk {
            return .{ .chunk = .{ .four_cc = try riff.FourCC.new(id), .data = data } };
        }

        fn testBuildWave(allocator: std.mem.Allocator, chunks: []const riff.Chunk) ![]u8 {
            const root = riff.Chunk{ .riff = .{ .four_cc = try riff.FourCC.new("WAVE"), .chunks = chunks } };
            var w = std.Io.Writer.Allocating.init(allocator);
            errdefer w.deinit();
            try riff.write(root, allocator, &w.writer);
            return w.toOwnedSlice();
        }

        // 16bit PCM, mono, 44100Hz
        const test_fmt_payload = [_]u8{ 1, 0, 1, 0, 0x44, 0xAC, 0, 0, 0x88, 0x58, 0x01, 0, 2, 0, 16, 0 };
        // Two 16bit samples: 0 and 32767
        const test_data_payload = [_]u8{ 0, 0, 0xFF, 0x7F };

        test "read ignores a LIST chunk" {
            const allocator = std.testing.allocator;

            const list_children = [_]riff.Chunk{try testChunk("ISFT", "zigggwavvv\x00")};
            const chunks = [_]riff.Chunk{
                try testChunk("fmt ", &test_fmt_payload),
                .{ .list = .{ .four_cc = try riff.FourCC.new("INFO"), .chunks = &list_children } },
                try testChunk("data", &test_data_payload),
            };
            const bytes = try testBuildWave(allocator, &chunks);
            defer allocator.free(bytes);

            var reader = std.Io.Reader.fixed(bytes);
            const result = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqualSlices(T, &[_]T{ 0, 1 }, result.samples);
        }

        test "read fails without a fmt chunk" {
            const allocator = std.testing.allocator;

            const chunks = [_]riff.Chunk{try testChunk("data", &test_data_payload)};
            const bytes = try testBuildWave(allocator, &chunks);
            defer allocator.free(bytes);

            var reader = std.Io.Reader.fixed(bytes);
            try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
        }

        test "read fails without a data chunk" {
            const allocator = std.testing.allocator;

            const chunks = [_]riff.Chunk{try testChunk("fmt ", &test_fmt_payload)};
            const bytes = try testBuildWave(allocator, &chunks);
            defer allocator.free(bytes);

            var reader = std.Io.Reader.fixed(bytes);
            try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
        }

        test "read fails when the data chunk precedes the fmt chunk" {
            const allocator = std.testing.allocator;

            const chunks = [_]riff.Chunk{
                try testChunk("data", &test_data_payload),
                try testChunk("fmt ", &test_fmt_payload),
            };
            const bytes = try testBuildWave(allocator, &chunks);
            defer allocator.free(bytes);

            var reader = std.Io.Reader.fixed(bytes);
            try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
        }

        test "read fails with a fmt chunk shorter than 16 bytes" {
            const allocator = std.testing.allocator;

            const chunks = [_]riff.Chunk{
                try testChunk("fmt ", test_fmt_payload[0..8]),
                try testChunk("data", &test_data_payload),
            };
            const bytes = try testBuildWave(allocator, &chunks);
            defer allocator.free(bytes);

            var reader = std.Io.Reader.fixed(bytes);
            try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
        }

        test "read fails with a truncated file" {
            const allocator = std.testing.allocator;

            const wavedata = @embedFile("./assets/16bit_pcm.wav");
            var reader = std.Io.Reader.fixed(wavedata[0 .. wavedata.len - 4]);
            if (Wave(T).read(allocator, &reader)) |result| {
                result.deinit(allocator);
                return error.TestUnexpectedResult;
            } else |_| {}
        }

        test "read fails with multiple data chunks" {
            const allocator = std.testing.allocator;

            const chunks = [_]riff.Chunk{
                try testChunk("fmt ", &test_fmt_payload),
                try testChunk("data", &test_data_payload),
                try testChunk("data", &test_data_payload),
            };
            const bytes = try testBuildWave(allocator, &chunks);
            defer allocator.free(bytes);

            var reader = std.Io.Reader.fixed(bytes);
            try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
        }
    };
}

test "Each Wave's child type of samples' array" {
    _ = Wave(f128);
    _ = Wave(f80);
    _ = Wave(f64);
    //_ = Wave(f32); // f32 cannot cover i32's max value, 2147483647
}
