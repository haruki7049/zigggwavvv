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

    // The decoder and the encoder normalize with 32-bit integer constants (`maxInt(i32)`), which f16 and f32 cannot represent
    if (@typeInfo(T).float.bits < 64)
        @compileError("Wave(T) requires a floating point type with at least 64 bits (f64, f80 or f128), found " ++ @typeName(T));

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

        /// Errors returned by `read`
        pub const ReadError = error{
            OutOfMemory,
            InvalidFormat,
            SizeMismatch,
            ReadFailed,
            EndOfStream,
            UnsupportedFormatCode,
            UnsupportedBits,
        };

        /// Errors returned by `write`
        pub const WriteError = error{
            OutOfMemory,
            InvalidFormat,
            InvalidChannels,
            SizeOverflow,
            UnsupportedFormatCode,
            UnsupportedBits,
            WriteFailed,
        };

        /// The largest data chunk that leaves room for the other chunks within a RIFF size of 32 bits
        const max_data_bytes: usize = std.math.maxInt(u32) - 1024;

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
        /// and IEEE float formats with 8, 16, 24, 32, and 64-bit sample depths. A
        /// WAVE_FORMAT_EXTENSIBLE fmt chunk is accepted when its sub-format is PCM or IEEE
        /// float; `format_code` of the result is then that sub-format.
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
        /// Errors (see `ReadError`):
        ///   - OutOfMemory: Allocation failed
        ///   - InvalidFormat: Not a valid WAVE file
        ///   - SizeMismatch: A chunk size does not match the file size
        ///   - ReadFailed: The reader failed
        ///   - EndOfStream: The reader ended before the whole file was read
        ///   - UnsupportedFormatCode: Audio format not supported
        ///   - UnsupportedBits: Bit depth not supported
        pub fn read(allocator: std.mem.Allocator, reader: anytype) ReadError!Self {
            const root_chunk = riff.read(allocator, reader) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.SizeMismatch => error.SizeMismatch,
                error.ReadFailed => error.ReadFailed,
                error.EndOfStream => error.EndOfStream,
                else => error.InvalidFormat,
            };
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

                    const tag = std.mem.readInt(u16, data[0..2], .little);
                    format_code = if (tag == wave_format_extensible)
                        try extensibleFormatCode(data)
                    else
                        @enumFromInt(tag);
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

                    // A file without channels or without a sample rate is not a usable WAV file
                    if (channels == 0 or sample_rate == 0)
                        return error.InvalidFormat;
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

        /// The format tag of a WAVE_FORMAT_EXTENSIBLE fmt chunk, whose real format is stored in a sub-format GUID
        const wave_format_extensible: u16 = 0xFFFE;

        /// The last 14 bytes of the sub-format GUIDs that wrap a plain format code (the first 2 bytes are the format code)
        const sub_format_guid_suffix = [_]u8{ 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71 };

        /// Reads the format code out of a WAVE_FORMAT_EXTENSIBLE fmt chunk.
        /// Only sub-formats that wrap a plain format code (such as PCM or IEEE float) are understood.
        fn extensibleFormatCode(data: []const u8) error{ InvalidFormat, UnsupportedFormatCode }!FormatCode {
            // 16 bytes of WAVEFORMATEX, cbSize (2), valid bits (2), channel mask (4) and the sub-format GUID (16)
            if (data.len < 40)
                return error.InvalidFormat;

            const cb_size = std.mem.readInt(u16, data[16..18], .little);
            if (cb_size < 22)
                return error.InvalidFormat;

            if (!std.mem.eql(u8, data[26..40], &sub_format_guid_suffix))
                return error.UnsupportedFormatCode;

            return @enumFromInt(std.mem.readInt(u16, data[24..26], .little));
        }

        /// Appends a chunk that takes ownership of `data`, freeing it if appending fails
        fn appendChunk(
            list: *std.array_list.Aligned(riff.Chunk, null),
            allocator: std.mem.Allocator,
            id: []const u8,
            data: []u8,
        ) !void {
            errdefer allocator.free(data);
            try list.append(allocator, .{ .chunk = .{ .four_cc = try riff.FourCC.new(id), .data = data } });
        }

        /// Encodes one normalized sample of type T into `w` as the given (bits, format_code)
        fn encodeSample(bits: u16, format_code: FormatCode, s: T, w: *std.Io.Writer) !void {
            switch (bits) {
                8 => switch (format_code) {
                    .pcm => {
                        const val: u8 = @intFromFloat(std.math.clamp(s * std.math.maxInt(u8), 0, std.math.maxInt(u8) - 1));
                        try w.writeInt(u8, val, .little);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                16 => switch (format_code) {
                    .pcm => {
                        const val: i16 = @intFromFloat(std.math.clamp(s * std.math.maxInt(i16), -std.math.maxInt(i16), std.math.maxInt(i16) - 1));
                        try w.writeInt(i16, val, .little);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                24 => switch (format_code) {
                    .pcm => {
                        const val: i24 = @intFromFloat(std.math.clamp(s * std.math.maxInt(i24), -std.math.maxInt(i24), std.math.maxInt(i24) - 1));
                        try w.writeInt(i24, val, .little);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                32 => switch (format_code) {
                    .pcm => {
                        const val: i32 = @intFromFloat(std.math.clamp(s * std.math.maxInt(i32), -std.math.maxInt(i32), std.math.maxInt(i32) - 1));
                        try w.writeInt(i32, val, .little);
                    },
                    .ieee_float => {
                        const val: f32 = @floatCast(s);
                        try w.writeInt(u32, @bitCast(val), .little);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                64 => switch (format_code) {
                    .ieee_float => {
                        const val: f64 = @floatCast(s);
                        try w.writeInt(u64, @bitCast(val), .little);
                    },
                    else => return error.UnsupportedFormatCode,
                },
                else => return error.UnsupportedBits,
            }
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
        /// Errors (see `WriteError`):
        ///   - OutOfMemory: Allocation failed
        ///   - InvalidFormat: A chunk identifier could not be built
        ///   - InvalidChannels: The number of channels is 0
        ///   - SizeOverflow: A size (block align, byte rate, frame count or data size) does not fit its RIFF field
        ///   - UnsupportedFormatCode: Audio format not supported for writing
        ///   - UnsupportedBits: Bit depth not supported for writing
        ///   - WriteFailed: The writer failed
        pub fn write(
            self: Self,
            writer: anytype,
            options: WriteOptions,
        ) WriteError!void {
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
            const bytes_per_sample: u16 = bits_per_sample / 8;

            // The sizes below are stored in 16- and 32-bit fields, so reject values that do not fit
            const block_align = std.math.mul(u16, self.channels, bytes_per_sample) catch return error.SizeOverflow;
            const bytes_per_sec = std.math.mul(u32, self.sample_rate, block_align) catch return error.SizeOverflow;
            const data_bytes = std.math.mul(usize, self.samples.len, bytes_per_sample) catch return error.SizeOverflow;
            if (data_bytes > max_data_bytes)
                return error.SizeOverflow;
            const frame_count = std.math.cast(u32, self.samples.len / self.channels) orelse return error.SizeOverflow;

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

                try appendChunk(&chunk_list, options.allocator, "fmt ", try fmt_payload.toOwnedSlice());
            }

            // Wave fact chunk
            if (options.use_fact) {
                var fact_payload = std.Io.Writer.Allocating.init(options.allocator);
                defer fact_payload.deinit();
                const fw = &fact_payload.writer;

                try fw.writeInt(u32, frame_count, .little);
                try appendChunk(&chunk_list, options.allocator, "fact", try fact_payload.toOwnedSlice());
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

                try appendChunk(&chunk_list, options.allocator, "PEAK", try peak_payload.toOwnedSlice());
            }

            // Wave data chunk
            {
                var data_payload = std.Io.Writer.Allocating.init(options.allocator);
                defer data_payload.deinit();
                const dw = &data_payload.writer;

                for (self.samples) |s|
                    try encodeSample(self.bits, self.format_code, s, dw);

                try appendChunk(&chunk_list, options.allocator, "data", try data_payload.toOwnedSlice());
            }

            const wave_riff = riff.Chunk{ .riff = .{ .four_cc = try riff.FourCC.new("WAVE"), .chunks = try chunk_list.toOwnedSlice(options.allocator) } };
            defer wave_riff.deinit(options.allocator);

            riff.write(wave_riff, options.allocator, writer) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.WriteFailed,
            };
        }

        /// A WAV asset together with the values `read` must return and the options `write` must use to reproduce it
        const WavCase = struct {
            asset: []const u8,
            format_code: FormatCode,
            bits: u16,
            samples: []const T,
            use_fact: bool,
            use_peak: bool,
            peak_timestamp: u32 = 0,
        };

        const wav_cases = [_]WavCase{
            .{
                .asset = @embedFile("./assets/8bit_pcm.wav"),
                .format_code = .pcm,
                .bits = 8,
                .samples = &[_]T{
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
                },
                .use_fact = false,
                .use_peak = false,
            },
            .{
                .asset = @embedFile("./assets/16bit_pcm.wav"),
                .format_code = .pcm,
                .bits = 16,
                .samples = &[_]T{
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
                },
                .use_fact = false,
                .use_peak = false,
            },
            .{
                .asset = @embedFile("./assets/24bit_pcm.wav"),
                .format_code = .pcm,
                .bits = 24,
                .samples = &[_]T{
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
                },
                .use_fact = false,
                .use_peak = false,
            },
            .{
                .asset = @embedFile("./assets/32bit_pcm.wav"),
                .format_code = .pcm,
                .bits = 32,
                .samples = &[_]T{
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
                },
                .use_fact = false,
                .use_peak = false,
            },
            .{
                .asset = @embedFile("./assets/32bit_ieee_float.wav"),
                .format_code = .ieee_float,
                .bits = 32,
                .samples = &[_]T{
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
                },
                .use_fact = true,
                .use_peak = true,
                .peak_timestamp = 0x695DE0F8,
            },
            .{
                .asset = @embedFile("./assets/64bit_ieee_float.wav"),
                .format_code = .ieee_float,
                .bits = 64,
                .samples = &[_]T{
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
                },
                .use_fact = true,
                .use_peak = true,
                .peak_timestamp = 0x695DE11A,
            },
        };

        test "read every asset" {
            const allocator = std.testing.allocator;

            for (wav_cases) |c| {
                var reader = std.Io.Reader.fixed(c.asset);
                const result: Wave(T) = try Wave(T).read(allocator, &reader);
                defer result.deinit(allocator);

                try std.testing.expectEqual(c.format_code, result.format_code);
                try std.testing.expectEqual(44100, result.sample_rate);
                try std.testing.expectEqual(1, result.channels);
                try std.testing.expectEqual(c.bits, result.bits);
                try std.testing.expectEqualSlices(T, c.samples, result.samples);
            }
        }

        test "write every asset" {
            const allocator = std.testing.allocator;

            for (wav_cases) |c| {
                const samples = try allocator.dupe(T, c.samples);
                defer allocator.free(samples);

                const result: Wave(T) = Wave(T).init(.{
                    .format_code = c.format_code,
                    .sample_rate = 44100,
                    .channels = 1,
                    .bits = c.bits,
                    .samples = samples,
                });

                var w = std.Io.Writer.Allocating.init(allocator);
                defer w.deinit();
                try result.write(&w.writer, .{
                    .allocator = allocator,
                    .use_fact = c.use_fact,
                    .use_peak = c.use_peak,
                    .peak_timestamp = c.peak_timestamp,
                });

                try std.testing.expectEqualSlices(u8, c.asset, w.writer.buffered());
            }
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

        test "write fails when block_align or bytes_per_sec does not fit" {
            const allocator = std.testing.allocator;

            var samples = [_]T{0.1};
            const cases = [_]struct { sample_rate: u32, channels: u16, bits: u16, format_code: FormatCode }{
                // block_align (u16) overflows
                .{ .sample_rate = 44100, .channels = 40000, .bits = 64, .format_code = .ieee_float },
                // bytes_per_sec (u32) overflows
                .{ .sample_rate = 2_000_000_000, .channels = 1, .bits = 32, .format_code = .pcm },
            };

            for (cases) |c| {
                const wave = Wave(T).init(.{
                    .format_code = c.format_code,
                    .sample_rate = c.sample_rate,
                    .channels = c.channels,
                    .bits = c.bits,
                    .samples = &samples,
                });

                var w = std.Io.Writer.Allocating.init(allocator);
                defer w.deinit();
                try std.testing.expectError(error.SizeOverflow, wave.write(&w.writer, .{ .allocator = allocator }));
            }
        }

        test "write accepts values close to the limits" {
            const allocator = std.testing.allocator;

            var samples = [_]T{0.1};
            const wave = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 1_000_000_000,
                .channels = 1,
                .bits = 32,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try wave.write(&w.writer, .{ .allocator = allocator, .use_fact = true });
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

        test "read fails with zero channels or a zero sample rate" {
            const allocator = std.testing.allocator;

            const Patch = struct { offset: usize, len: usize };
            const patches = [_]Patch{
                .{ .offset = 2, .len = 2 }, // channels
                .{ .offset = 4, .len = 4 }, // sample_rate
            };

            for (patches) |p| {
                var fmt_payload = test_fmt_payload;
                @memset(fmt_payload[p.offset .. p.offset + p.len], 0);

                const chunks = [_]riff.Chunk{
                    try testChunk("fmt ", &fmt_payload),
                    try testChunk("data", &test_data_payload),
                };
                const bytes = try testBuildWave(allocator, &chunks);
                defer allocator.free(bytes);

                var reader = std.Io.Reader.fixed(bytes);
                try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
            }
        }

        /// A 40 byte WAVE_FORMAT_EXTENSIBLE fmt chunk for mono 44100Hz with the given bits and sub-format code
        fn extensibleFmtPayload(bits: u16, sub_format: u16) [40]u8 {
            var p: [40]u8 = @splat(0);
            std.mem.writeInt(u16, p[0..2], 0xFFFE, .little);
            std.mem.writeInt(u16, p[2..4], 1, .little);
            std.mem.writeInt(u32, p[4..8], 44100, .little);
            std.mem.writeInt(u32, p[8..12], @as(u32, 44100) * (bits / 8), .little);
            std.mem.writeInt(u16, p[12..14], bits / 8, .little);
            std.mem.writeInt(u16, p[14..16], bits, .little);
            std.mem.writeInt(u16, p[16..18], 22, .little); // cbSize
            std.mem.writeInt(u16, p[18..20], bits, .little); // valid bits
            std.mem.writeInt(u32, p[20..24], 4, .little); // channel mask (front center)
            std.mem.writeInt(u16, p[24..26], sub_format, .little);
            @memcpy(p[26..40], &[_]u8{ 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71 });
            return p;
        }

        test "read accepts a WAVE_FORMAT_EXTENSIBLE fmt chunk with a PCM sub-format" {
            const allocator = std.testing.allocator;

            const fmt_payload = extensibleFmtPayload(16, 1);
            const chunks = [_]riff.Chunk{
                try testChunk("fmt ", &fmt_payload),
                try testChunk("data", &test_data_payload),
            };
            const bytes = try testBuildWave(allocator, &chunks);
            defer allocator.free(bytes);

            var reader = std.Io.Reader.fixed(bytes);
            const result = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(.pcm, result.format_code);
            try std.testing.expectEqual(44100, result.sample_rate);
            try std.testing.expectEqual(1, result.channels);
            try std.testing.expectEqual(16, result.bits);

            // The samples are the same as the ones of the plain PCM fmt chunk
            const plain_chunks = [_]riff.Chunk{
                try testChunk("fmt ", &test_fmt_payload),
                try testChunk("data", &test_data_payload),
            };
            const plain_bytes = try testBuildWave(allocator, &plain_chunks);
            defer allocator.free(plain_bytes);
            var plain_reader = std.Io.Reader.fixed(plain_bytes);
            const plain = try Wave(T).read(allocator, &plain_reader);
            defer plain.deinit(allocator);
            try std.testing.expectEqualSlices(T, plain.samples, result.samples);
        }

        test "read accepts a WAVE_FORMAT_EXTENSIBLE fmt chunk with an IEEE float sub-format" {
            const allocator = std.testing.allocator;

            const fmt_payload = extensibleFmtPayload(32, 3);
            const float_data = std.mem.toBytes(@as(f32, 0.5));
            const chunks = [_]riff.Chunk{
                try testChunk("fmt ", &fmt_payload),
                try testChunk("data", &float_data),
            };
            const bytes = try testBuildWave(allocator, &chunks);
            defer allocator.free(bytes);

            var reader = std.Io.Reader.fixed(bytes);
            const result = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expectEqual(.ieee_float, result.format_code);
            try std.testing.expectEqual(32, result.bits);
            try std.testing.expectEqualSlices(T, &[_]T{0.5}, result.samples);
        }

        test "read rejects invalid WAVE_FORMAT_EXTENSIBLE fmt chunks" {
            const allocator = std.testing.allocator;

            // Too short to hold the extension
            {
                const fmt_payload = extensibleFmtPayload(16, 1);
                const chunks = [_]riff.Chunk{
                    try testChunk("fmt ", fmt_payload[0..24]),
                    try testChunk("data", &test_data_payload),
                };
                const bytes = try testBuildWave(allocator, &chunks);
                defer allocator.free(bytes);
                var reader = std.Io.Reader.fixed(bytes);
                try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
            }

            // cbSize is smaller than the extension
            {
                var fmt_payload = extensibleFmtPayload(16, 1);
                std.mem.writeInt(u16, fmt_payload[16..18], 0, .little);
                const chunks = [_]riff.Chunk{
                    try testChunk("fmt ", &fmt_payload),
                    try testChunk("data", &test_data_payload),
                };
                const bytes = try testBuildWave(allocator, &chunks);
                defer allocator.free(bytes);
                var reader = std.Io.Reader.fixed(bytes);
                try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
            }

            // The GUID is not a wrapped format code
            {
                var fmt_payload = extensibleFmtPayload(16, 1);
                fmt_payload[30] = 0xFF;
                const chunks = [_]riff.Chunk{
                    try testChunk("fmt ", &fmt_payload),
                    try testChunk("data", &test_data_payload),
                };
                const bytes = try testBuildWave(allocator, &chunks);
                defer allocator.free(bytes);
                var reader = std.Io.Reader.fixed(bytes);
                try std.testing.expectError(error.UnsupportedFormatCode, Wave(T).read(allocator, &reader));
            }

            // A sub-format that is not supported
            {
                const fmt_payload = extensibleFmtPayload(16, 2);
                const chunks = [_]riff.Chunk{
                    try testChunk("fmt ", &fmt_payload),
                    try testChunk("data", &test_data_payload),
                };
                const bytes = try testBuildWave(allocator, &chunks);
                defer allocator.free(bytes);
                var reader = std.Io.Reader.fixed(bytes);
                try std.testing.expectError(error.UnsupportedFormatCode, Wave(T).read(allocator, &reader));
            }
        }

        // The tests below pin down how `read` behaves with different `reader` types.
        // `read` only relies on `reader.buffered()` (through riff_zig), so it sees
        // the bytes already in the reader's buffer and never fills the reader itself.

        test "read accepts any type with a buffered() method" {
            const allocator = std.testing.allocator;

            const BufferedOnly = struct {
                bytes: []const u8,

                pub fn buffered(self: @This()) []const u8 {
                    return self.bytes;
                }
            };

            const wavedata = @embedFile("./assets/16bit_pcm.wav");
            const result = try Wave(T).read(allocator, BufferedOnly{ .bytes = wavedata });
            defer result.deinit(allocator);

            try std.testing.expectEqual(16, result.bits);
        }

        test "read fails on an empty reader" {
            const allocator = std.testing.allocator;

            var reader = std.Io.Reader.fixed("");
            try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
        }

        test "read from a file reader needs the buffer to be filled first" {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            const wavedata = @embedFile("./assets/16bit_pcm.wav");

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "input.wav", .data = wavedata });

            const file = try tmp.dir.openFile(io, "input.wav", .{});
            defer file.close(io);

            // Nothing has been read from the file yet, so `buffered()` is empty
            {
                var buffer: [wavedata.len]u8 = undefined;
                var file_reader = file.reader(io, &buffer);
                try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &file_reader.interface));
            }

            // Once the whole file is in the buffer, the same reader type works
            {
                var buffer: [wavedata.len]u8 = undefined;
                var file_reader = file.reader(io, &buffer);
                try file_reader.interface.fill(wavedata.len);

                const result = try Wave(T).read(allocator, &file_reader.interface);
                defer result.deinit(allocator);

                try std.testing.expectEqual(16, result.bits);
            }
        }
    };
}

test "Each Wave's child type of samples' array" {
    _ = Wave(f128);
    _ = Wave(f80);
    _ = Wave(f64);
    //_ = Wave(f32); // f32 cannot cover i32's max value, 2147483647
}
