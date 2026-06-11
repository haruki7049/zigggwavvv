{
  linkFarm,
  fetchurl,
}:

linkFarm "zig-packages" [
  {
    name = "riff_zig-1.1.2-J7H0A0lxTADPiTM0n8qFOJER78SXIXJTG63AjeC768FG.tar.gz";
    path = fetchurl {
      url = "https://github.com/haruki7049/RIFF.zig/archive/refs/tags/1.1.2.tar.gz";
      hash = "sha256-dtosAEQFVNuv24XuxVF1tUR91vcL5mRAARN/Ep3pJsQ";
    };
  }
]
