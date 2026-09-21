# Agent Guidelines for `zigggwavvv`

This document defines core principles, architectural invariants, and non-negotiable safety rules for AI agents working on the `zigggwavvv` repository.

______________________________________________________________________

## 1. Project Overview & Architecture

`zigggwavvv` is a WAV file reader/writer library written in Zig, built on top of [`riff_zig`](https://github.com/haruki7049/RIFF.zig).

- **Development Environment**: Managed with Nix (`flake.nix`), `direnv`, and `treefmt` (via `treefmt-nix`) for formatting Zig, Nix, GitHub Actions, and Markdown files.
- **Target Language Version**: Zig `0.16.0` (`minimum_zig_version` in `build.zig.zon`). Keep external dependencies minimal.
- **Directory Structure**:
  - `src/root.zig`: Library entry point (public API, `FormatCode`, encoding/decoding logic and tests).
  - `src/assets/`: Sample WAV files used by tests.
  - `build.zig` & `build.zig.zon`: Build definition and package metadata. Steps: `zig build` (static library), `zig build test`, `zig build docs`.
  - `.deps.nix`: Nix dependency lockfile generated from `build.zig.zon` by `zon2nix`.
  - `.github/workflows/`: CI, Nix checks, API docs deployment, and stale issue handling.

______________________________________________________________________

## 2. Strict Safety & Operational Rules (Always Enforced)

- **NEVER AUTO-MERGE TO MAIN**: AI agents **MUST NEVER** merge PRs, execute `git merge`, or directly push commits to the `main` branch autonomously.
- **NEVER PROPOSE COMMITS OR PUSHES UNPROMPTED**: AI agents **MUST NEVER** prompt the user to commit or push, nor propose commit messages unprompted. When instructed by the user or when creating/updating pull requests on topic branches, agents may execute `git commit` and `git push` directly without seeking confirmation.
- **Mandatory Human Approval**: AI agents may create branches, create commits, push topic branches, propose PRs, format code, and run test suites, but the final action of merging changes into `main` rests strictly with the human maintainer.
- **Verification Before Submitting**: All changes must pass `treefmt --fail-on-change`, `zig build`, and `zig build test`.
- **Conventional Commits**: Use conventional commit prefixes (`feat:`, `fix:`, `refactor:`, `docs:`, `build:`, `test:`), optionally with a scope (e.g. `build(flake.lock):`).
- **Evidence First**: Base all answers and actions on actual file contents and command output. Never speculate or assume.
- **Non-Destructive**: Never perform irreversible actions (file deletions, hard resets, remote push) without explicit user approval.
- **Targeted Edits**: Make minimal, logical changes strictly necessary for the request. Do not modify unrelated files.
- **English-Only Documentation**: All repository documentation, agent skills, code comments, commit messages, and PR descriptions must be written strictly in English.
- **Explicit Milestone Assignment Only**: AI agents **MUST NEVER** automatically attach or set GitHub Milestones on Pull Requests or Issues unless explicitly requested or instructed by the user.

______________________________________________________________________

## 3. Status Assessment Workflow

When asked to check status, assess the situation, or understand workspace context:

1. **Local Git State**: Inspect working tree (`git status -s -b`) and recent commits (`git log -n 5 --oneline`).
1. **GitHub PRs**: Check PR status (`gh pr status`) and current PR details (`gh pr view`).
1. **GitHub Issues**: Check relevant open issues (`gh issue list --limit 5`).
1. **Environment Health**: Verify build and test status (`treefmt --fail-on-change`, `zig build`, `zig build test`).
1. **Synthesis**: Report a concise, structured status covering local state, remote GitHub state, and environment health.

______________________________________________________________________

## 4. Workspace Skills

Detailed runbooks and procedural workflows are maintained as workspace skills under `.agents/skills/`:

| Trigger / Context | Skill to Read | Purpose |
| :--- | :--- | :--- |
| Deep investigation, complex code search | [`investigate`](.agents/skills/investigate/SKILL.md) | Non-destructive investigation guidelines |
| Commit conventions & policies | [`git-commit`](.agents/skills/git-commit/SKILL.md) | Commit conventions and prohibition of unprompted commit/push proposals |
| Deleting files, overwriting, git push/reset | [`irreversible`](.agents/skills/irreversible/SKILL.md) | Pre-checks and confirmation prompts |
| Testing, verifying builds or behavior | [`verify`](.agents/skills/verify/SKILL.md) | Minimal, high-signal verification steps |
| Bumping `riff_zig` or regenerating `.deps.nix` | [`update-dependencies`](.agents/skills/update-dependencies/SKILL.md) | Procedures for dependency updates and `.deps.nix` |
| Preparing PRs, formatting, pre-submission checks | [`pr-workflow`](.agents/skills/pr-workflow/SKILL.md) | Verification command table, commit rules, and PR requirements |
