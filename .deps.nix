{
  linkFarm,
  fetchzip,
}:

linkFarm "zig-packages" [
  {
    name = "riff_zig-1.1.2-J7H0A0lxTADPiTM0n8qFOJER78SXIXJTG63AjeC768FG";
    path = fetchzip {
      url = "https://github.com/haruki7049/RIFF.zig/archive/refs/tags/1.1.2.tar.gz";
      hash = "sha256-JNjOR4TvlPvJBGXE7zZ59XbgjUnnB9RPsEGMqMCJGAU=";
    };
  }
]
