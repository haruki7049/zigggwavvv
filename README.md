# zigggwavvv

`zigggwavvv` (pronounced "zig wave") is a Zig library designed to handle the Waveform Audio File Format (WAV).

## Features

- **WAV Parsing and Generation**: Read and write WAV files using the RIFF container format.
- **Wide Format Support**:
  - **PCM**: Support for 8, 16, 24, and 32-bit depths.
  - **IEEE Float**: Support for 32 and 64-bit depths.
- **Flexible Type Support**: Supports processing audio samples as `f32`, `f64`, `f80`, or `f128` types based on your precision needs. `Wave(T)` requires a float type with at least 32 bits, so `f16` and smaller types are rejected at compile time. With `f32`, 8-, 16- and 24-bit PCM round-trip exactly, while 32-bit PCM keeps only 24 significant bits. Reading a 64-bit float file with `f32` rounds each sample to `f32`: a finite value beyond the `f32` range becomes an infinity, and a value of at most half the smallest `f32` subnormal (2^-150) becomes zero, while a larger tiny value is rounded to that subnormal.
- **Extended Chunk Support**: Optional generation of `fact` and `PEAK` chunks when writing files. By default, `fact` is written for IEEE float files and left out for PCM files; set `use_fact` to `true` or `false` to force it.

## Installation

Add `zigggwavvv` to the dependencies of your project. `zig fetch --save` writes the `url` and the `hash` into your `build.zig.zon` for you:

```bash
zig fetch --save https://github.com/haruki7049/zigggwavvv/archive/refs/tags/2.0.0.tar.gz
```

The entry in `build.zig.zon` then looks like this (the `hash` is filled in by Zig; use the tag of the release you want):

```zig
.dependencies = .{
    .zigggwavvv = .{
        .url = "https://github.com/haruki7049/zigggwavvv/archive/refs/tags/2.0.0.tar.gz",
        .hash = "<hash>",
    },
},
```

Then in your `build.zig`:

```zig
// Add zigggwavvv dependency
const zigggwavvv = b.dependency("zigggwavvv", .{});
// Import the module
exe.root_module.addImport("zigggwavvv", zigggwavvv.module("zigggwavvv"));
```

## Usage Example

### Reading a WAV File

`read` takes a `*std.Io.Reader` and streams the data from it, so it can read straight from a file reader without loading the whole file first. To read bytes that are already in memory, wrap them with `std.Io.Reader.fixed`.

```zig
const std = @import("std");
const zigggwavvv = @import("zigggwavvv");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Open the WAV file and read from it directly
    const file = try std.Io.Dir.cwd().openFile(io, "input.wav", .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);

    // Parse the file into a Wave structure with f128 precision
    const wave = try zigggwavvv.Wave(f128).read(allocator, &file_reader.interface);
    defer wave.deinit(allocator);

    // Access samples (f128)
    for (wave.samples) |sample| {
        // Process audio data...
        _ = sample;
    }
    std.debug.print("read {d} samples\n", .{wave.samples.len});
}
```

### Writing a WAV File

`write` takes a `*std.Io.Writer`. When writing to a file, remember to `flush` the writer.

With `use_peak`, pass the current time as `peak_timestamp`: a reader may compare it with the modification date of the file and rescan the file if they differ, and the default `0` (the date 1970-01-01) never matches. The peak values are correct either way. This library defines a fixed value as acceptable when the output has to be reproducible; that is the maintainer's own decision, made for the build-time cache of [haruki7049/lightmix](https://github.com/haruki7049/lightmix), and it does not come from the specification, so do not take it as authoritative.

```zig
const std = @import("std");
const zigggwavvv = @import("zigggwavvv");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Define audio properties and samples
    var samples = [_]f128{ 0.0, 0.5, -0.5 };
    const wave = zigggwavvv.Wave(f128){
        .format_code = .pcm,
        .sample_rate = 44100,
        .channels = 1,
        .bits = 16,
        .samples = &samples,
    };

    // Create output file
    const file = try std.Io.Dir.cwd().createFile(io, "output.wav", .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);

    // The time at which the peak data is made, in seconds since 1970-01-01 (Unix time)
    const now: u32 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());

    // Write the WAV file with optional chunks
    try wave.write(&file_writer.interface, .{
        .allocator = allocator,
        .use_fact = false,
        .use_peak = true,
        .peak_timestamp = now,
    });
    try file_writer.interface.flush();
}
```

## API Overview

- `zigggwavvv.Wave(T).read(allocator, reader)`: Parses a WAV file and returns a `Wave(T)` struct with samples of type `T`.
- `wave.write(writer, options)`: Serializes a `Wave(T)` struct to a WAV file.
- `Wave(T).deinit(allocator)`: Frees the memory allocated for samples.
- `Wave(T).init(options)`: Creates a `Wave(T)` from an `InitOptions` (`format_code`, `sample_rate`, `channels`, `bits` and `samples`). It only copies the fields: it does not validate them and does not copy `samples`.
- `WriteOptions`: The options of `write`: `allocator`, `use_fact`, `use_peak` and `peak_timestamp`.
- `FormatCode`: The format of the samples, `.pcm` or `.ieee_float`.
- `Wave(T).ReadError` and `Wave(T).WriteError`: The errors of `read` and `write`. `riff_zig` may add members to them in a minor release, so keep an `else` prong in a `switch` over either set.

## License

This project is dual-licensed under the **MIT License** and **Apache License 2.0**.

## Zig version

0.16.0 is the minimum version (`minimum_zig_version` in `build.zig.zon`), and it is the version that the CI uses.
