# External Dependency Update Workflow

## Zig package dependencies (`riff_zig`)

Both `build.zig.zon` and `.deps.nix` must be kept in sync:

1. **Update `build.zig.zon`**: Update the `url` and `hash` under `.dependencies.riff_zig` (e.g. `zig fetch --save <tarball-url>`).
1. **Synchronize Nix Lockfile**: Run `zon2nix > .deps.nix` to regenerate the Nix dependency lockfile `.deps.nix`.
1. **Fix the generated URLs**: `zon2nix` emits `https://codeload.github.com/<owner>/<repo>/tar.gz/refs/tags/<tag>`, whose last path segment has no archive extension, so `fetchzip` fails with `do not know how to unpack source archive`. Set each `url` in `.deps.nix` to the same `url` as in `build.zig.zon` (`https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz`). Keep the generated `hash`: both URLs serve the same tarball. The unused `fetchgit` argument in the generated header can be dropped, as in the committed file.
1. **Format Code**: Run `treefmt` to format all changed files (including `.deps.nix` and `build.zig.zon`).
1. **Verification**: Run `zig build` and `zig build test` to guarantee error-free compilation and tests.
1. **Nix build on a clean store**: Run `nix build --print-build-logs`. A store that already holds a fetched result with the same hash skips the fetch and hides a broken `url`, so the store must be clean first: the user runs `sudo nix-collect-garbage -d` (agents cannot use `sudo`, so ask the user). Check that the build log shows `trying <url>` for the new package, which proves it was fetched again, and that the build and check phases pass.

## Nix inputs (`flake.lock`)

1. Run `nix flake update`.
1. Run `treefmt --fail-on-change`, `zig build`, and `zig build test` (inside `nix develop` or via direnv).
1. Commit with `build(flake.lock): nix flake update`.

## Zig version bumps

When changing the Zig version, update all of the following together: `minimum_zig_version` in `build.zig.zon`, `pkgs.zig_0_XX` / `pkgs.zls_0_XX` in `flake.nix`, the version noted in `CONTRIBUTING.md`, the version in the "Zig version" section of `README.md`, the Zig version in the project overview of `AGENTS.md`, and the Zig version used in `.github/workflows/`.
