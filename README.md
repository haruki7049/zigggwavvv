# zigggwavvv

`zigggwavvv` (pronounced "zig wave") is a Zig library designed to handle the Waveform Audio File Format (WAV).

## Features

- **WAV Parsing and Generation**: Read and write WAV files using the RIFF container format.
- **Wide Format Support**:
  - **PCM**: Support for 8, 16, 24, and 32-bit depths.
  - **IEEE Float**: Support for 32 and 64-bit depths.
- **Flexible Type Support**: Supports processing audio samples as `f32`, `f64`, or `f128` types based on your precision needs.
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

```zig
const std = @import("std");
const zigggwavvv = @import("zigggwavvv");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open and read a WAV file
    const file = try std.fs.cwd().openFile("input.wav", .{});
    defer file.close();

    // Parse the file into a Wave structure with f128 precision
    const wave = try zigggwavvv.Wave(f128).read(allocator, file.reader());
    defer wave.deinit(allocator);

    // Access samples (f128)
    for (wave.samples) |sample| {
        // Process audio data...
        _ = sample;
    }
}
```

### Writing a WAV File

```zig
const std = @import("std");
const zigggwavvv = @import("zigggwavvv");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
    const file = try std.fs.cwd().createFile("output.wav", .{});
    defer file.close();

    // Write the WAV file with optional chunks
    try wave.write(file.writer(), .{
        .allocator = allocator,
        .use_fact = false,
        .use_peak = true,
        .peak_timestamp = 0, // Unix time
    });
}
```

## API Overview

- `zigggwavvv.Wave(T).read(allocator, reader)`: Parses a WAV file and returns a `Wave(T)` struct with samples of type `T`.
- `Wave(T).write(writer, options)`: Serializes a `Wave(T)` struct to a WAV file.
- `Wave(T).deinit(allocator)`: Frees the memory allocated for samples.

## Development

This project uses [Nix](https://nixos.org/) for the development environment.

```sh
# Enter the Nix development shell
nix develop
# Run unit tests
zig build test
```

## License

This project is dual-licensed under the **MIT License** and **Apache License 2.0**.

## Zig version

0.15.2
