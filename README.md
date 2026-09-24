# zigggwavvv

`zigggwavvv` (pronounced "zig wave") is a Zig library designed to handle the Waveform Audio File Format (WAV).

## Features

- **WAV Parsing and Generation**: Read and write WAV files using the RIFF container format.
- **Wide Format Support**:
  - **PCM**: Support for 8, 16, 24, and 32-bit depths.
  - **IEEE Float**: Support for 32 and 64-bit depths.
- **Flexible Type Support**: Supports processing audio samples as `f64`, `f80`, or `f128` types based on your precision needs. `Wave(T)` requires a float type with at least 64 bits, so `f32` and smaller types are rejected at compile time.
- **Extended Chunk Support**: Optional generation of `fact` and `PEAK` chunks when writing files.

## Installation

Add `zigggwavvv` to your `build.zig.zon` dependencies:

```zig
.{
    .name = "your_project",
    .version = "0.1.0",
    .dependencies = .{
        .zigggwavvv = .{
            .url = "https://github.com/haruki7049/zigggwavvv/archive/<commit_hash>.tar.gz",
            .hash = "<hash>",
        },
    },
}
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

    // Write the WAV file with optional chunks
    try wave.write(&file_writer.interface, .{
        .allocator = allocator,
        .use_fact = false,
        .use_peak = true,
        .peak_timestamp = 0, // Unix time
    });
    try file_writer.interface.flush();
}
```

## API Overview

- `zigggwavvv.Wave(T).read(allocator, reader)`: Parses a WAV file and returns a `Wave(T)` struct with samples of type `T`.
- `wave.write(writer, options)`: Serializes a `Wave(T)` struct to a WAV file.
- `Wave(T).deinit(allocator)`: Frees the memory allocated for samples.

## License

This project is dual-licensed under the **MIT License** and **Apache License 2.0**.

## Zig version

0.16.0
