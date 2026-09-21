# External Dependency Update Workflow

## Zig package dependencies (`riff_zig`)

Both `build.zig.zon` and `.deps.nix` must be kept in sync:

1. **Update `build.zig.zon`**: Update the `url` and `hash` under `.dependencies.riff_zig` (e.g. `zig fetch --save <tarball-url>`).
1. **Synchronize Nix Lockfile**: Run `zon2nix > .deps.nix` to regenerate the Nix dependency lockfile `.deps.nix`.
1. **Format Code**: Run `treefmt` to format all changed files (including `.deps.nix` and `build.zig.zon`).
1. **Verification**: Run `zig build` and `zig build test` to guarantee error-free compilation and tests.

## Nix inputs (`flake.lock`)

1. Run `nix flake update`.
1. Run `treefmt --fail-on-change`, `zig build`, and `zig build test` (inside `nix develop` or via direnv).
1. Commit with `build(flake.lock): nix flake update`.

## Zig version bumps

When changing the Zig version, update all of the following together: `minimum_zig_version` in `build.zig.zon`, `pkgs.zig_0_XX` / `pkgs.zls_0_XX` in `flake.nix`, the version noted in `CONTRIBUTING.md`, and the Zig version used in `.github/workflows/`.
