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
        samples: []const T,

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
            UnsupportedFormatCode,
            UnsupportedBits,
        };

        /// Errors returned by `write`
        pub const WriteError = error{
            OutOfMemory,
            InvalidFormat,
            InvalidChannels,
            InvalidSampleCount,
            SizeOverflow,
            UnsupportedFormatCode,
            UnsupportedBits,
            NonFiniteSample,
            WriteFailed,
        };

        /// The largest data chunk that leaves room for the other chunks within a RIFF size of 32 bits
        const max_data_bytes: usize = std.math.maxInt(u32) - 1024;

        pub const InitOptions = struct {
            format_code: FormatCode,
            sample_rate: u32,
            channels: u16,
            bits: u16,
            samples: []const T,
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
        /// The data chunk must hold a whole number of frames (one sample per channel); a
        /// short trailing frame is rejected as `InvalidFormat` rather than dropped. The fmt
        /// chunk's `block_align` and `byte_rate` fields are not validated against `channels`
        /// and `bits`: they are not used to decode the data chunk, and some encoders get them
        /// wrong, so a mismatch there does not by itself make a file unreadable.
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
        ///   - UnsupportedFormatCode: Audio format not supported
        ///   - UnsupportedBits: Bit depth not supported
        fn mapStreamError(err: riff.stream.Error) ReadError {
            return switch (err) {
                error.SizeMismatch => error.SizeMismatch,
                error.ReadFailed => error.ReadFailed,
                else => error.InvalidFormat,
            };
        }

        pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) ReadError!Self {
            var it = riff.stream.Iterator.init(reader, .{});

            // The root container must be a RIFF WAVE
            const top_event = (it.next() catch |err| return mapStreamError(err)) orelse return error.InvalidFormat;
            switch (top_event) {
                .begin_container => |c| {
                    if (c.kind != .riff or !std.mem.eql(u8, &c.four_cc.inner, "WAVE"))
                        return error.InvalidFormat;
                },
                else => return error.InvalidFormat,
            }

            var format_code: FormatCode = undefined;
            var sample_rate: u32 = undefined;
            var channels: u16 = undefined;
            var bits: u16 = undefined;
            var samples: []T = undefined;
            var fmt_read = false;
            var data_read = false;
            errdefer if (data_read) allocator.free(samples);

            while (it.next() catch |err| return mapStreamError(err)) |ev| {
                switch (ev) {
                    .chunk => |c| {
                        // Only consider chunks at depth 1 (direct children of RIFF WAVE)
                        if (it.depth != 1) continue;

                        const id = c.four_cc.inner;
                        if (std.mem.eql(u8, &id, "fmt ")) {
                            if (c.size < 16)
                                return error.InvalidFormat;

                            var sub_buf: [64]u8 = undefined;
                            const data_reader = it.dataReader(&sub_buf) catch |err| return switch (err) {
                                error.SizeMismatch => error.SizeMismatch,
                                error.ReadFailed => error.ReadFailed,
                                else => error.InvalidFormat,
                            };

                            var fmt_buf: [64]u8 = undefined;
                            const to_read = @min(c.size, fmt_buf.len);
                            data_reader.readSliceAll(fmt_buf[0..to_read]) catch |err| return switch (err) {
                                error.EndOfStream => error.SizeMismatch,
                                error.ReadFailed => error.ReadFailed,
                            };
                            const fmt_data = fmt_buf[0..to_read];

                            const tag = std.mem.readInt(u16, fmt_data[0..2], .little);
                            format_code = if (tag == wave_format_extensible)
                                try extensibleFormatCode(fmt_data)
                            else
                                @enumFromInt(tag);
                            channels = std.mem.readInt(u16, fmt_data[2..4], .little);
                            sample_rate = std.mem.readInt(u32, fmt_data[4..8], .little);
                            bits = std.mem.readInt(u16, fmt_data[14..16], .little);
                            fmt_read = true;

                            // We only support PCM and IEEE Float
                            if (format_code != .pcm and format_code != .ieee_float)
                                return error.UnsupportedFormatCode;

                            // We only support some combinations of bit depth and format code
                            try checkSupported(bits, format_code);

                            // A file without channels or without a sample rate is not a usable WAV file
                            if (channels == 0 or sample_rate == 0)
                                return error.InvalidFormat;
                        } else if (std.mem.eql(u8, &id, "data")) {
                            // The fmt chunk must precede the data chunk
                            if (!fmt_read)
                                return error.InvalidFormat;

                            // A WAV file has exactly one data chunk
                            if (data_read)
                                return error.InvalidFormat;

                            const bytes_per_sample: usize = switch (bits) {
                                8 => 1,
                                16 => 2,
                                24 => 3,
                                32 => 4,
                                64 => 8,
                                else => unreachable,
                            };

                            const frame_size = bytes_per_sample * channels;
                            if (c.size % frame_size != 0)
                                return error.InvalidFormat;

                            const samples_count = c.size / bytes_per_sample;
                            var samples_list: []T = try allocator.alloc(T, samples_count);
                            errdefer allocator.free(samples_list);

                            if (samples_count > 0) {
                                var sub_buf: [1024]u8 = undefined;
                                const data_reader = it.dataReader(&sub_buf) catch |err| return switch (err) {
                                    error.SizeMismatch => error.SizeMismatch,
                                    error.ReadFailed => error.ReadFailed,
                                    else => error.InvalidFormat,
                                };

                                var block_buf: [4096]u8 = undefined;
                                const block_samples = block_buf.len / bytes_per_sample;

                                var samples_decoded: usize = 0;
                                while (samples_decoded < samples_count) {
                                    const samples_to_read = @min(block_samples, samples_count - samples_decoded);
                                    const bytes_to_read = samples_to_read * bytes_per_sample;
                                    const chunk_bytes = block_buf[0..bytes_to_read];
                                    data_reader.readSliceAll(chunk_bytes) catch |err| return switch (err) {
                                        error.EndOfStream => error.SizeMismatch,
                                        error.ReadFailed => error.ReadFailed,
                                    };
                                    for (0..samples_to_read) |i| {
                                        samples_list[samples_decoded + i] = decodeSample(bits, format_code, chunk_bytes, i);
                                    }
                                    samples_decoded += samples_to_read;
                                }
                            }

                            samples = samples_list;
                            data_read = true;
                        }
                    },
                    .begin_container, .end_container => {},
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

        /// Checks that (bits, format_code) is a combination that `read` and `write` support:
        /// 8, 16 and 24 bits as PCM, 32 bits as PCM or IEEE float, and 64 bits as IEEE float.
        /// `decodeSample` and `encodeSample` rely on this check.
        fn checkSupported(bits: u16, format_code: FormatCode) error{ UnsupportedBits, UnsupportedFormatCode }!void {
            switch (bits) {
                8, 16, 24 => if (format_code != .pcm) return error.UnsupportedFormatCode,
                32 => if (format_code != .pcm and format_code != .ieee_float) return error.UnsupportedFormatCode,
                64 => if (format_code != .ieee_float) return error.UnsupportedFormatCode,
                else => return error.UnsupportedBits,
            }
        }

        /// Decodes the `i`-th sample of a data chunk into a normalized value of type T
        fn decodeSample(bits: u16, format_code: FormatCode, data: []const u8, i: usize) T {
            switch (bits) {
                8 => switch (format_code) {
                    .pcm => {
                        // 8-bit PCM is unsigned, with 128 as the zero level (silence)
                        const val: i16 = @as(i16, data[i]) - 128;
                        return @as(T, @floatFromInt(val)) / std.math.maxInt(i8);
                    },
                    else => unreachable, // rejected by checkSupported
                },
                16 => switch (format_code) {
                    .pcm => {
                        const bytes_number = 2; // A i16 wave data's sample takes 2
                        const val: i16 = std.mem.readInt(i16, data[i * bytes_number ..][0..bytes_number], .little);
                        return @as(T, @floatFromInt(val)) / std.math.maxInt(i16);
                    },
                    else => unreachable, // rejected by checkSupported
                },
                24 => switch (format_code) {
                    .pcm => {
                        const bytes_number = 3; // A i24 wave data's sample takes 3
                        const val: i24 = std.mem.readInt(i24, data[i * bytes_number ..][0..bytes_number], .little);
                        return @as(T, @floatFromInt(val)) / std.math.maxInt(i24);
                    },
                    else => unreachable, // rejected by checkSupported
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
                    else => unreachable, // rejected by checkSupported
                },
                64 => switch (format_code) {
                    .ieee_float => {
                        const bytes_number = 8;
                        const val: f64 = @bitCast(std.mem.readInt(u64, data[i * bytes_number ..][0..bytes_number], .little));
                        return @as(T, val);
                    },
                    else => unreachable, // rejected by checkSupported
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

        /// Encodes one normalized sample of type T into `w` as the given (bits, format_code)
        fn encodeSample(bits: u16, format_code: FormatCode, s: T, w: *std.Io.Writer) !void {
            switch (bits) {
                8 => switch (format_code) {
                    .pcm => {
                        if (!std.math.isFinite(s)) return error.NonFiniteSample;
                        // 8-bit PCM is unsigned, with 128 as the zero level (silence)
                        const centered: i16 = @intFromFloat(@round(std.math.clamp(s * std.math.maxInt(i8), -std.math.maxInt(i8), std.math.maxInt(i8))));
                        const val: u8 = @intCast(centered + 128);
                        try w.writeInt(u8, val, .little);
                    },
                    else => unreachable, // rejected by checkSupported
                },
                16 => switch (format_code) {
                    .pcm => {
                        if (!std.math.isFinite(s)) return error.NonFiniteSample;
                        const val: i16 = @intFromFloat(@round(std.math.clamp(s * std.math.maxInt(i16), -std.math.maxInt(i16), std.math.maxInt(i16))));
                        try w.writeInt(i16, val, .little);
                    },
                    else => unreachable, // rejected by checkSupported
                },
                24 => switch (format_code) {
                    .pcm => {
                        if (!std.math.isFinite(s)) return error.NonFiniteSample;
                        const val: i24 = @intFromFloat(@round(std.math.clamp(s * std.math.maxInt(i24), -std.math.maxInt(i24), std.math.maxInt(i24))));
                        try w.writeInt(i24, val, .little);
                    },
                    else => unreachable, // rejected by checkSupported
                },
                32 => switch (format_code) {
                    .pcm => {
                        if (!std.math.isFinite(s)) return error.NonFiniteSample;
                        const val: i32 = @intFromFloat(@round(std.math.clamp(s * std.math.maxInt(i32), -std.math.maxInt(i32), std.math.maxInt(i32))));
                        try w.writeInt(i32, val, .little);
                    },
                    .ieee_float => {
                        const val: f32 = @floatCast(s);
                        try w.writeInt(u32, @bitCast(val), .little);
                    },
                    else => unreachable, // rejected by checkSupported
                },
                64 => switch (format_code) {
                    .ieee_float => {
                        const val: f64 = @floatCast(s);
                        try w.writeInt(u64, @bitCast(val), .little);
                    },
                    else => unreachable, // rejected by checkSupported
                },
                else => unreachable, // rejected by checkSupported
            }
        }

        /// Encodes the 16-byte payload of the fmt chunk directly into a stack buffer without heap allocation.
        fn writeFmtBytes(self: Self, block_align: u16, bytes_per_sec: u32) [16]u8 {
            var buf: [16]u8 = undefined;
            std.mem.writeInt(u16, buf[0..2], @intFromEnum(self.format_code), .little);
            std.mem.writeInt(u16, buf[2..4], self.channels, .little);
            std.mem.writeInt(u32, buf[4..8], self.sample_rate, .little);
            std.mem.writeInt(u32, buf[8..12], bytes_per_sec, .little);
            std.mem.writeInt(u16, buf[12..14], block_align, .little);
            std.mem.writeInt(u16, buf[14..16], self.bits, .little);
            return buf;
        }

        /// Encodes the 4-byte payload of the fact chunk directly into a stack buffer without heap allocation.
        fn writeFactBytes(frame_count: u32) [4]u8 {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, buf[0..4], frame_count, .little);
            return buf;
        }

        /// Builds the payload of the PEAK chunk in a single allocation. The caller owns the returned slice.
        fn peakPayload(self: Self, allocator: std.mem.Allocator, timestamp: u32) ![]u8 {
            const peak_size = 8 + @as(usize, self.channels) * 8;
            const buf = try allocator.alloc(u8, peak_size);
            errdefer allocator.free(buf);

            // Version (usually 1)
            std.mem.writeInt(u32, buf[0..4], 1, .little);
            // Timestamp (Unix time or 0)
            std.mem.writeInt(u32, buf[4..8], timestamp, .little);

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

                const offset = 8 + ch * 8;
                @memcpy(buf[offset..][0..4], std.mem.asBytes(&max_val));
                std.mem.writeInt(u32, buf[offset + 4 ..][0..4], max_pos, .little);
            }

            return buf;
        }

        /// Builds the payload of the data chunk. The caller owns the returned slice.
        fn dataPayload(self: Self, allocator: std.mem.Allocator, data_bytes: usize) ![]u8 {
            // The exact size is already known, so allocate it once instead of letting the
            // writer grow (and copy) as samples are encoded
            var payload = try std.Io.Writer.Allocating.initCapacity(allocator, data_bytes);
            defer payload.deinit();
            const w = &payload.writer;

            for (self.samples) |s|
                try encodeSample(self.bits, self.format_code, s, w);

            return payload.toOwnedSlice();
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
        /// PCM formats (8, 16, 24 and 32-bit) normalize a sample `s` in `-1.0..1.0` to the
        /// full integer range symmetrically: `+1.0` and `-1.0` both round-trip exactly, at
        /// the cost of the very bottom of the signed range (e.g. `i16`'s `minInt`) never
        /// being produced by `write` (8-bit PCM is unsigned, with 128 as the zero level). The
        /// scaled value is rounded to the nearest integer, with ties away from zero, so the
        /// error of a sample is at most half a step of the integer format.
        /// `NaN` and infinite samples are rejected rather than silently clamped. IEEE float
        /// formats (32 and 64-bit) store the sample bits directly and are unaffected: `NaN`
        /// and infinities round-trip as-is.
        ///
        ///
        /// `write` only borrows `self.samples` and never mutates them. Callers holding
        /// `[]const T` can write without copying or casting.
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
        ///   - InvalidSampleCount: The number of samples is not a multiple of the number of channels
        ///   - SizeOverflow: A size (block align, byte rate, frame count or data size) does not fit its RIFF field
        ///   - UnsupportedFormatCode: Audio format not supported for writing
        ///   - UnsupportedBits: Bit depth not supported for writing
        ///   - NonFiniteSample: A sample is NaN or infinite and the target format is PCM
        ///   - WriteFailed: The writer failed
        pub fn write(
            self: Self,
            writer: *std.Io.Writer,
            options: WriteOptions,
        ) WriteError!void {
            if (self.channels == 0)
                return error.InvalidChannels;

            if (self.samples.len % self.channels != 0)
                return error.InvalidSampleCount;

            // Validate the format before writing anything, so that it is rejected even when there are no samples
            try checkSupported(self.bits, self.format_code);

            const bits_per_sample: u16 = self.bits;
            const bytes_per_sample: u16 = bits_per_sample / 8;

            // The sizes below are stored in 16- and 32-bit fields, so reject values that do not fit
            const block_align = std.math.mul(u16, self.channels, bytes_per_sample) catch return error.SizeOverflow;
            const bytes_per_sec = std.math.mul(u32, self.sample_rate, block_align) catch return error.SizeOverflow;
            const data_bytes = std.math.mul(usize, self.samples.len, bytes_per_sample) catch return error.SizeOverflow;
            if (data_bytes > max_data_bytes)
                return error.SizeOverflow;
            const frame_count = std.math.cast(u32, self.samples.len / self.channels) orelse return error.SizeOverflow;

            var chunks: [4]riff.Chunk = undefined;
            var chunk_count: usize = 0;

            const fmt_bytes = self.writeFmtBytes(block_align, bytes_per_sec);
            chunks[chunk_count] = .{ .chunk = .{
                .four_cc = try riff.FourCC.new("fmt "),
                .data = &fmt_bytes,
            } };
            chunk_count += 1;

            var fact_bytes: [4]u8 = undefined;
            if (options.use_fact) {
                fact_bytes = writeFactBytes(frame_count);
                chunks[chunk_count] = .{ .chunk = .{
                    .four_cc = try riff.FourCC.new("fact"),
                    .data = &fact_bytes,
                } };
                chunk_count += 1;
            }

            var peak_data: ?[]u8 = null;
            defer if (peak_data) |p| options.allocator.free(p);
            if (options.use_peak) {
                peak_data = try self.peakPayload(options.allocator, options.peak_timestamp);
                chunks[chunk_count] = .{ .chunk = .{
                    .four_cc = try riff.FourCC.new("PEAK"),
                    .data = peak_data.?,
                } };
                chunk_count += 1;
            }

            const data_payload = try self.dataPayload(options.allocator, data_bytes);
            defer options.allocator.free(data_payload);
            chunks[chunk_count] = .{ .chunk = .{
                .four_cc = try riff.FourCC.new("data"),
                .data = data_payload,
            } };
            chunk_count += 1;

            const wave_riff = riff.Chunk{ .riff = .{
                .four_cc = try riff.FourCC.new("WAVE"),
                .chunks = chunks[0..chunk_count],
            } };

            riff.write(wave_riff, writer) catch return error.WriteFailed;
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
                    -0.007874015748031496062992125984251968503937007,
                    0.047244094488188976377952755905511811023622047,
                    0.094488188976377952755905511811023622047244094,
                    0.149606299212598425196850393700787401574803149,
                    0.196850393700787401574803149606299212598425196,
                    0.244094488188976377952755905511811023622047244,
                    0.291338582677165354330708661417322834645669291,
                    0.338582677165354330708661417322834645669291338,
                    0.385826771653543307086614173228346456692913385,
                    0.425196850393700787401574803149606299212598425,
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
                const result: Wave(T) = Wave(T).init(.{
                    .format_code = c.format_code,
                    .sample_rate = 44100,
                    .channels = 1,
                    .bits = c.bits,
                    .samples = c.samples,
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

            const Case = struct { sample_rate: u32, channels: u16, bits: u16, format_code: FormatCode };
            const cases = [_]Case{
                // block_align (u16) overflows
                .{ .sample_rate = 44100, .channels = 40000, .bits = 64, .format_code = .ieee_float },
                // bytes_per_sec (u32) overflows
                .{ .sample_rate = 2_000_000_000, .channels = 1, .bits = 32, .format_code = .pcm },
            };

            for (cases) |c| {
                // The sample count must be a multiple of the channels so that InvalidSampleCount
                // does not shadow the SizeOverflow this test checks for
                const samples = try allocator.alloc(T, c.channels);
                defer allocator.free(samples);
                @memset(samples, 0.1);

                const wave = Wave(T).init(.{
                    .format_code = c.format_code,
                    .sample_rate = c.sample_rate,
                    .channels = c.channels,
                    .bits = c.bits,
                    .samples = samples,
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

        test "write fails when the sample count is not a multiple of the channels" {
            const allocator = std.testing.allocator;

            var samples = [_]T{ 0.1, 0.2, 0.3 };
            const wave = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 2,
                .bits = 16,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try std.testing.expectError(error.InvalidSampleCount, wave.write(&w.writer, .{
                .allocator = allocator,
                .use_fact = true,
            }));
            try std.testing.expectEqual(0, w.writer.buffered().len);
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

        test "write encodes 8bit pcm as unsigned with 128 as silence" {
            const allocator = std.testing.allocator;

            var samples = [_]T{ -1, -0.5, 0, 0.5, 1 };
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
            // -0.5 and 0.5 scale to -63.5 and 63.5, which round away from zero to -64 and 64
            try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 64, 128, 192, 255 }, w.writer.buffered()[data_offset .. data_offset + samples.len]);
        }

        test "write rounds PCM samples to the nearest integer" {
            const allocator = std.testing.allocator;

            const Case = struct { bits: u16, max: T };
            const cases = [_]Case{
                .{ .bits = 8, .max = 127 },
                .{ .bits = 16, .max = 32767 },
                .{ .bits = 24, .max = 8388607 },
                .{ .bits = 32, .max = 2147483647 },
            };

            // Scaled values that lie below and above the middle of two integers, on both sides of zero,
            // and the integers they must be rounded to (truncation would give 100, 100, -100, -100)
            const scaled = [_]T{ 100.4, 100.6, -100.4, -100.6 };
            const expected = [_]i32{ 100, 101, -100, -101 };

            for (cases) |c| {
                var samples: [scaled.len]T = undefined;
                for (&samples, scaled) |*s, v| s.* = v / c.max;

                const wave = Wave(T).init(.{
                    .format_code = .pcm,
                    .sample_rate = 44100,
                    .channels = 1,
                    .bits = c.bits,
                    .samples = &samples,
                });

                var w = std.Io.Writer.Allocating.init(allocator);
                defer w.deinit();
                try wave.write(&w.writer, .{ .allocator = allocator });

                // RIFF header (12) + fmt chunk (24) + data chunk header (8)
                const data = w.writer.buffered()[44..];
                for (expected, 0..) |code, i| {
                    const written: i32 = switch (c.bits) {
                        8 => @as(i32, data[i]) - 128,
                        16 => std.mem.readInt(i16, data[i * 2 ..][0..2], .little),
                        24 => std.mem.readInt(i24, data[i * 3 ..][0..3], .little),
                        32 => std.mem.readInt(i32, data[i * 4 ..][0..4], .little),
                        else => unreachable,
                    };
                    try std.testing.expectEqual(code, written);
                }
            }
        }

        test "write then read round-trips every supported format" {
            const allocator = std.testing.allocator;

            const cases = [_]struct { format_code: FormatCode, bits: u16, tolerance: T }{
                .{ .format_code = .pcm, .bits = 8, .tolerance = 1.0 / 127.0 },
                .{ .format_code = .pcm, .bits = 16, .tolerance = 1.0 / 32767.0 },
                .{ .format_code = .pcm, .bits = 24, .tolerance = 1.0 / 8388607.0 },
                .{ .format_code = .pcm, .bits = 32, .tolerance = 1.0 / 2147483647.0 },
                .{ .format_code = .ieee_float, .bits = 32, .tolerance = 0 },
                .{ .format_code = .ieee_float, .bits = 64, .tolerance = 0 },
            };

            var samples = [_]T{ -1, -0.5, 0, 0.25, 0.5, 0.75, 1 };

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

        test "write rejects NaN and infinite samples for PCM formats" {
            const allocator = std.testing.allocator;

            const bits_cases = [_]u16{ 8, 16, 24, 32 };
            const value_cases = [_]T{ std.math.nan(T), std.math.inf(T), -std.math.inf(T) };

            for (bits_cases) |bits| {
                for (value_cases) |v| {
                    var samples = [_]T{v};
                    const wave = Wave(T).init(.{
                        .format_code = .pcm,
                        .sample_rate = 44100,
                        .channels = 1,
                        .bits = bits,
                        .samples = &samples,
                    });

                    var w = std.Io.Writer.Allocating.init(allocator);
                    defer w.deinit();
                    try std.testing.expectError(error.NonFiniteSample, wave.write(&w.writer, .{ .allocator = allocator }));
                }
            }
        }

        test "write preserves NaN and infinite samples for IEEE float formats" {
            const allocator = std.testing.allocator;

            var samples = [_]T{ std.math.nan(T), std.math.inf(T), -std.math.inf(T) };
            const wave = Wave(T).init(.{
                .format_code = .ieee_float,
                .sample_rate = 44100,
                .channels = 1,
                .bits = 64,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try wave.write(&w.writer, .{ .allocator = allocator });

            var reader = std.Io.Reader.fixed(w.writer.buffered());
            const result = try Wave(T).read(allocator, &reader);
            defer result.deinit(allocator);

            try std.testing.expect(std.math.isNan(result.samples[0]));
            try std.testing.expectEqual(std.math.inf(T), result.samples[1]);
            try std.testing.expectEqual(-std.math.inf(T), result.samples[2]);
        }

        fn testChunk(id: []const u8, data: []const u8) !riff.Chunk {
            return .{ .chunk = .{ .four_cc = try riff.FourCC.new(id), .data = data } };
        }

        fn testBuildWave(allocator: std.mem.Allocator, chunks: []const riff.Chunk) ![]u8 {
            const root = riff.Chunk{ .riff = .{ .four_cc = try riff.FourCC.new("WAVE"), .chunks = chunks } };
            var w = std.Io.Writer.Allocating.init(allocator);
            errdefer w.deinit();
            try riff.write(root, &w.writer);
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

        test "read fails when the data chunk does not hold a whole number of frames" {
            const allocator = std.testing.allocator;

            // 2 channels, 16 bits => 4 bytes per frame; 6 bytes of data is 1.5 frames
            var fmt_payload = test_fmt_payload;
            std.mem.writeInt(u16, fmt_payload[2..4], 2, .little);
            const data_payload = [_]u8{ 0, 0, 0xFF, 0x7F, 0, 0 };

            const chunks = [_]riff.Chunk{
                try testChunk("fmt ", &fmt_payload),
                try testChunk("data", &data_payload),
            };
            const bytes = try testBuildWave(allocator, &chunks);
            defer allocator.free(bytes);

            var reader = std.Io.Reader.fixed(bytes);
            try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
        }

        test "read tolerates a fmt chunk whose block_align or byte_rate do not match channels and bits" {
            const allocator = std.testing.allocator;

            const Patch = struct { offset: usize, len: usize };
            const patches = [_]Patch{
                .{ .offset = 8, .len = 4 }, // byte_rate
                .{ .offset = 12, .len = 2 }, // block_align
            };

            for (patches) |p| {
                var fmt_payload = test_fmt_payload;
                @memset(fmt_payload[p.offset .. p.offset + p.len], 0xFF);

                const chunks = [_]riff.Chunk{
                    try testChunk("fmt ", &fmt_payload),
                    try testChunk("data", &test_data_payload),
                };
                const bytes = try testBuildWave(allocator, &chunks);
                defer allocator.free(bytes);

                var reader = std.Io.Reader.fixed(bytes);
                const result = try Wave(T).read(allocator, &reader);
                defer result.deinit(allocator);

                try std.testing.expectEqual(1, result.channels);
                try std.testing.expectEqual(16, result.bits);
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

        test "read rejects unsupported combinations of bits and format code in the fmt chunk" {
            const allocator = std.testing.allocator;

            const Case = struct { format_code: u16, bits: u16, expected: anyerror };
            const cases = [_]Case{
                .{ .format_code = 1, .bits = 64, .expected = error.UnsupportedFormatCode }, // 64bit PCM
                .{ .format_code = 3, .bits = 16, .expected = error.UnsupportedFormatCode }, // 16bit IEEE float
                .{ .format_code = 1, .bits = 12, .expected = error.UnsupportedBits },
            };

            for (cases) |c| {
                var fmt_payload = test_fmt_payload;
                std.mem.writeInt(u16, fmt_payload[0..2], c.format_code, .little);
                std.mem.writeInt(u16, fmt_payload[14..16], c.bits, .little);

                // Without a data chunk, so that the error can only come from the fmt chunk
                const chunks = [_]riff.Chunk{try testChunk("fmt ", &fmt_payload)};
                const bytes = try testBuildWave(allocator, &chunks);
                defer allocator.free(bytes);

                var reader = std.Io.Reader.fixed(bytes);
                try std.testing.expectError(c.expected, Wave(T).read(allocator, &reader));
            }
        }

        // The tests below pin down how `read` behaves with a `*std.Io.Reader`.

        test "read fails on an empty reader" {
            const allocator = std.testing.allocator;

            var reader = std.Io.Reader.fixed("");
            try std.testing.expectError(error.InvalidFormat, Wave(T).read(allocator, &reader));
        }

        test "read from a file reader works directly with a small buffer" {
            const allocator = std.testing.allocator;
            const io = std.testing.io;

            const wavedata = @embedFile("./assets/16bit_pcm.wav");

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "input.wav", .data = wavedata });

            const file = try tmp.dir.openFile(io, "input.wav", .{});
            defer file.close(io);

            var buffer: [256]u8 = undefined;
            var file_reader = file.reader(io, &buffer);

            const result = try Wave(T).read(allocator, &file_reader.interface);
            defer result.deinit(allocator);

            try std.testing.expectEqual(16, result.bits);
        }

        test "read and write perform minimal allocations" {
            const CountAlloc = struct {
                child: std.mem.Allocator,
                allocs: usize = 0,

                fn allocator(self: *@This()) std.mem.Allocator {
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

                fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    self.allocs += 1;
                    return self.child.vtable.alloc(self.child.ptr, len, ptr_align, ret_addr);
                }

                fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    return self.child.vtable.resize(self.child.ptr, buf, buf_align, new_len, ret_addr);
                }

                fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
                }

                fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    self.child.vtable.free(self.child.ptr, buf, buf_align, ret_addr);
                }
            };

            var counter = CountAlloc{ .child = std.testing.allocator };
            const ca = counter.allocator();

            // 1. read should perform exactly 1 allocation (the returned samples slice)
            const wavedata = @embedFile("./assets/16bit_pcm.wav");
            var reader = std.Io.Reader.fixed(wavedata);
            const read_result = try Wave(T).read(ca, &reader);
            defer read_result.deinit(ca);

            try std.testing.expectEqual(1, counter.allocs);

            // 2. write should perform exactly 1 allocation (the data chunk payload)
            counter.allocs = 0;
            var out_buf: [1024]u8 = undefined;
            var w = std.Io.Writer.fixed(&out_buf);
            try read_result.write(&w, .{ .allocator = ca });

            try std.testing.expectEqual(1, counter.allocs);
        }

        test "write pads a data chunk of odd size and read accepts it" {
            const allocator = std.testing.allocator;

            // 5 samples of 8 bits and 3 samples of 24 bits give data chunks of 5 and 9 bytes
            const Case = struct { bits: u16, count: usize, tolerance: T };
            const cases = [_]Case{
                .{ .bits = 8, .count = 5, .tolerance = 1.0 / 127.0 },
                .{ .bits = 24, .count = 3, .tolerance = 1.0 / 8388607.0 },
            };

            for (cases) |c| {
                var samples: [5]T = undefined;
                for (samples[0..c.count], 0..) |*s, i| s.* = @as(T, @floatFromInt(i)) / 10 - 0.2;

                const wave = Wave(T).init(.{
                    .format_code = .pcm,
                    .sample_rate = 44100,
                    .channels = 1,
                    .bits = c.bits,
                    .samples = samples[0..c.count],
                });

                var w = std.Io.Writer.Allocating.init(allocator);
                defer w.deinit();
                try wave.write(&w.writer, .{ .allocator = allocator });
                const written = w.writer.buffered();

                // RIFF header (12) + fmt chunk (24) + data chunk header (8), then the data and one pad byte
                const data_bytes = c.count * (c.bits / 8);
                try std.testing.expectEqual(1, data_bytes % 2);
                try std.testing.expectEqual(data_bytes, std.mem.readInt(u32, written[40..44], .little));
                try std.testing.expectEqual(44 + data_bytes + 1, written.len);
                try std.testing.expectEqual(@as(u8, 0), written[written.len - 1]);
                try std.testing.expectEqual(written.len - 8, std.mem.readInt(u32, written[4..8], .little));

                var reader = std.Io.Reader.fixed(written);
                const result = try Wave(T).read(allocator, &reader);
                defer result.deinit(allocator);

                try std.testing.expectEqual(c.count, result.samples.len);
                for (samples[0..c.count], result.samples) |expected, actual| {
                    try std.testing.expectApproxEqAbs(expected, actual, c.tolerance);
                }
            }
        }

        test "write puts the fmt, fact, PEAK and data chunks in order for several channels" {
            const allocator = std.testing.allocator;

            // 3 channels, 2 frames
            var samples = [_]T{ 0.1, -0.2, 0.3, -0.4, 0.5, -0.6 };
            const wave = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 3,
                .bits = 16,
                .samples = &samples,
            });

            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            try wave.write(&w.writer, .{ .allocator = allocator, .use_fact = true, .use_peak = true });
            const written = w.writer.buffered();

            const Expected = struct { id: []const u8, size: u32 };
            const expected = [_]Expected{
                .{ .id = "fmt ", .size = 16 },
                .{ .id = "fact", .size = 4 },
                // A version and a timestamp, then a value and a position for each of the 3 channels
                .{ .id = "PEAK", .size = 8 + 3 * 8 },
                .{ .id = "data", .size = 12 },
            };

            // Walk the chunks after the 12-byte RIFF header
            var offset: usize = 12;
            for (expected) |e| {
                try std.testing.expectEqualStrings(e.id, written[offset..][0..4]);
                const size = std.mem.readInt(u32, written[offset + 4 ..][0..4], .little);
                try std.testing.expectEqual(e.size, size);
                offset += 8 + size + (size & 1);
            }
            try std.testing.expectEqual(written.len, offset);
        }

        test "the PEAK chunk ignores NaN and reports an infinity" {
            const allocator = std.testing.allocator;

            const nan = std.math.nan(T);
            const inf = std.math.inf(T);
            const Case = struct { samples: [3]T, value: f32, position: u32 };
            const cases = [_]Case{
                // NaN never compares greater than the current peak, so it is skipped
                .{ .samples = .{ 0.5, nan, -2.0 }, .value = 2.0, .position = 2 },
                .{ .samples = .{ nan, nan, nan }, .value = 0.0, .position = 0 },
                .{ .samples = .{ 0.5, inf, -2.0 }, .value = std.math.inf(f32), .position = 1 },
            };

            for (cases) |c| {
                // IEEE float samples keep NaN and infinities, so `write` accepts them together with `use_peak`
                const wave = Wave(T).init(.{
                    .format_code = .ieee_float,
                    .sample_rate = 44100,
                    .channels = 1,
                    .bits = 64,
                    .samples = &c.samples,
                });

                const payload = try wave.peakPayload(allocator, 0);
                defer allocator.free(payload);

                const value: f32 = @bitCast(std.mem.readInt(u32, payload[8..12], .little));
                try std.testing.expectEqual(c.value, value);
                try std.testing.expectEqual(c.position, std.mem.readInt(u32, payload[12..16], .little));
            }
        }

        test "read accepts a fmt chunk larger than its fixed buffers" {
            const allocator = std.testing.allocator;

            // The fmt payload buffers of `read` hold 64 bytes; the rest of the chunk must be skipped.
            // 65 is odd, so the chunk is padded as well
            const sizes = [_]usize{ 65, 100 };
            for (sizes) |size| {
                var fmt_payload = [_]u8{0} ** 100;
                @memcpy(fmt_payload[0..test_fmt_payload.len], &test_fmt_payload);

                const chunks = [_]riff.Chunk{
                    try testChunk("fmt ", fmt_payload[0..size]),
                    try testChunk("data", &test_data_payload),
                };
                const bytes = try testBuildWave(allocator, &chunks);
                defer allocator.free(bytes);

                var reader = std.Io.Reader.fixed(bytes);
                const result = try Wave(T).read(allocator, &reader);
                defer result.deinit(allocator);

                try std.testing.expectEqual(16, result.bits);
                try std.testing.expectEqualSlices(T, &[_]T{ 0, 1 }, result.samples);
            }
        }

        test "write accepts read-only samples slice without copying" {
            const allocator = std.testing.allocator;
            const const_samples: []const T = &[_]T{ 0.0, 0.5, -0.5, 0.25 };
            const wave = Wave(T).init(.{
                .format_code = .pcm,
                .sample_rate = 44100,
                .channels = 2,
                .bits = 16,
                .samples = const_samples,
            });

            var out_buf: [1024]u8 = undefined;
            var w = std.Io.Writer.fixed(&out_buf);
            try wave.write(&w, .{ .allocator = allocator });
            try std.testing.expect(w.end > 0);
        }
    };
}

test "Each Wave's child type of samples' array" {
    _ = Wave(f128);
    _ = Wave(f80);
    _ = Wave(f64);
    //_ = Wave(f32); // f32 cannot cover i32's max value, 2147483647
}
