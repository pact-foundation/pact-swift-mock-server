# Developing and releasing `pact-swift-mock-server`

A practical runbook: how to get a working checkout, how to change things, and how to cut a new
version. It describes the process **as it exists today**, not as it should ideally be — where a
step is known to be broken, it says so and points at
[`known-issues.md`](known-issues.md).

---

## 1. What this repository actually produces

This repo is not the thing consumers install. It is the *build system* for a binary that lives
somewhere else. Three repositories are involved:

| Repository | Role |
|---|---|
| `pact-foundation/pact-swift-mock-server` (this one) | Swift source, Xcode project, build & release scripts. Wraps `libpact_ffi.a`. |
| `pact-foundation/pact-reference` (submodule at `pact-reference/`) | Upstream Rust. Source of `libpact_ffi.a`. Pinned by tag in [`libpact_ffi.version`](../libpact_ffi.version). |
| `pact-foundation/pact-swift-xcframework` (submodule at `XCFramework/`) | **Release target.** Holds the published `Package.swift` and hosts the `.xcframework.zip` as a GitHub release asset. |

The consumer, [`pact-swift`](https://github.com/pact-foundation/pact-swift), depends on
`pact-swift-xcframework` as a SwiftPM `binaryTarget` — a URL plus a checksum. It never sees this
repository.

This indirection exists for size. The `libpact_ffi.a` slices total **>200 MB**; compiling them into
a zipped XCFramework and distributing it as a binary target keeps a package resolve to roughly
90 MB.

### Versioning

**A release is named after the `libpact_ffi` it wraps.** Pinning `libpact_ffi-v0.5.9` in
[`libpact_ffi.version`](../libpact_ffi.version) releases `v0.5.9`. There is no independent version
line to reason about: to release a new version, you bump the FFI pin.

The one exception is a Swift-side-only fix against an FFI version that has already shipped. SwiftPM
resolves these tags as semver, so the next release must sort higher, and there is no spare
component — so `-v patch` deliberately drifts the patch ahead of the FFI version:

| `libpact_ffi.version` | Latest release | Next release | Mode |
|---|---|---|---|
| `0.5.9` | none | `v0.5.9` | `ffi` (default) |
| `0.5.9` | `v0.5.8` | `v0.5.9` | `ffi` |
| `0.5.9` | `v0.5.9` | `v0.5.10` | `patch` — wrapper fix, still wraps FFI 0.5.9 |
| `0.5.10` | `v0.5.10` | `v0.5.11` | `patch` — next free patch |
| `0.5.9` | `v0.5.9` | *refused* | `ffi` — bump the pin or use `-v patch` |

The release notes always name the real FFI version, because they are generated from
`libpact_ffi.version` — so a drifted patch is never ambiguous about what it wraps.

Tags themselves live on **`pact-swift-xcframework`**, not here. This repo is tagged separately, by
the "Tag on PR merge" workflow, after the release PR merges.

### The root `Package.swift` is not the product

[`Package.swift`](../Package.swift) in this repo declares a Linux-only target and does not compile
(see known issue 1). Everything on Apple platforms is driven by
`PactSwiftMockServer.xcodeproj`. Don't reach for `swift build`.

---

## 2. Prerequisites

Installed for you by [`Support/Scripts/CI/configure_build_tools`](../Support/Scripts/CI/configure_build_tools):

- `cbindgen`, `xcbeautify`, `swiftlint`, `doxygen` (unused — see known issue 5)
- `rustup`, if missing

**Not** installed by that script, but required:

| Tool | Needed by | Why it is missed |
|---|---|---|
| Full Xcode (not Command Line Tools) | everything | `build_rust_dependencies` now verifies this via `verify_xcode` and fails early with the `xcode-select` fix |
| `cmake` | `build_rust_dependencies` (`pact_ffi.h` generation, and build-environment logging) | preinstalled on GitHub runners, so CI never noticed |
| `jq` | `latest_tag` in [`version_numbers.sh`](../Support/Scripts/CI/version_numbers.sh) | same |
| `gh` | every GitHub step of the release | — |
| A GPG signing key | the release script commits with `-S` and will abort mid-release without one | — |

Xcode floor is **16.1** (`config.sh`), though the version check only compares the major component
in practice.

```bash
brew install cmake jq gh && sh Support/Scripts/CI/configure_build_tools
```

---

## 3. First-time checkout

Submodules are **not** initialised by a plain clone, and nothing builds without them:

```bash
git clone git@github.com:pact-foundation/pact-swift-mock-server.git
cd pact-swift-mock-server
git submodule update --init --recursive
```

`pact-reference` is large. Expect this to take a while.

Then build the Rust binaries once (~1 hour cold):

```bash
./Support/Scripts/CI/build_rust_dependencies
```

This produces `Resources/{darwin,iOS-device,iOS-simulator}/libpact_ffi.a` and refreshes
`Sources/pact_ffi.h`. All of it is gitignored — the binaries are never committed.

> [!NOTE]
> [`Resources/libpact_ffi.md`](../Resources/libpact_ffi.md) contradicts this: it describes
> committing x86_64 slices under a 100 MB limit. That document is stale (known issue 7). The only
> part still true is the required folder layout.

---

## 4. Everyday development

### Build and test

```bash
./Support/Scripts/test
```

With no arguments this defaults to the `PactSwiftMockServer-macOS` scheme on the host
architecture. To pick a scheme and destination explicitly (note the script's unusual argument
pairing — `--scheme` first, then `--target`):

```bash
./Support/Scripts/test --scheme PactSwiftMockServer-iOS --target "platform=iOS Simulator,name=iPhone 16 Pro"
```

The three shared schemes are:

| Scheme | Builds for |
|---|---|
| `PactSwiftMockServer-macOS` | macOS, arm64 |
| `PactSwiftMockServer-iOS` | iOS Simulator, arm64 |
| `PactSwiftMockServer-iphoneos` | physical iOS device, arm64 |

A single test is easiest through Xcode, or:

```bash
xcodebuild test -project PactSwiftMockServer.xcodeproj \
  -scheme PactSwiftMockServer-macOS \
  -only-testing:PactSwiftMockServer_macOSTests/MockServerTests | xcbeautify
```

### Linting

SwiftLint runs as a build phase on all three framework targets
([`Support/Scripts/BuildPhase/lint_project`](../Support/Scripts/BuildPhase/lint_project)), config at
[`Support/Configuration/swiftlint.yml`](../Support/Configuration/swiftlint.yml). Running that script
by hand fails under `set -eu` because it reads `$PROJECT_NAME`, which only Xcode sets.

### Getting CI to run your branch

There is **no `pull_request` trigger** (known issue 2). CI runs only on `workflow_dispatch` or a
push to a branch matching `run-on-ci/**`:

```bash
git push origin HEAD:run-on-ci/my-change
```

Note that the release-candidate branches the release script creates are named `rc/<tag>`, which
does *not* match — so the release path itself is never exercised by CI.

---

## 5. Bumping `libpact_ffi`

Since the release version is the FFI version, **this is how you start a release** — and it is also
the change most likely to break in an interesting way. As of writing this repo pins `0.5.5` while
upstream is at `0.5.9`.

1. Edit [`libpact_ffi.version`](../libpact_ffi.version) to the new upstream tag, e.g.
   `libpact_ffi-v0.5.9`. Available tags:

   ```bash
   gh api repos/pact-foundation/pact-reference/tags --paginate -q '.[].name' | grep '^libpact_ffi'
   ```
2. Rebuild:

   ```bash
   ./Support/Scripts/CI/build_rust_dependencies --clean-build
   ```

   The script checks out that tag inside the `pact-reference` submodule, so any local state there
   is discarded. Use `--skip-submodule-update` when you deliberately want to build a local branch
   of `pact-reference` (e.g. preparing an upstream fix) — the resulting binaries will *not* match
   the pinned version and must not be released.

3. **Archive all three schemes before trusting the bump.** A new transitive Rust crate can
   reference a system framework nothing currently links, and the only signal is a link failure —
   which otherwise surfaces halfway through a release:

   ```bash
   ./Support/Scripts/CI/build_xcframework 0.0.0-test
   ```

   This is exactly how the `objc2-ui-kit` → `_UIApplicationMain` breakage in 0.5.4 was found
   (known issue 17). Delete the resulting `PactSwiftMockServer-0.0.0-test*` artefacts afterwards.

4. Run the full test suite on macOS *and* the iOS Simulator.

### Two patches the build applies on your behalf

Both live in `build_rust_dependencies` rather than in the submodule, because the tag checkout
resets the submodule on every run. Both are meant to disappear once fixed upstream:

- **Vendored Lua merge.** `mlua-sys` compiles Lua into its own `liblua5.4.a` and asks Cargo to link
  it — a directive Cargo only honours for final binaries, not `staticlib` archives. Each
  `libpact_ffi.a` is therefore merged with its matching `liblua5.4.a` via `libtool`, and the result
  is asserted to contain `_lua_yieldk`. Without this, consuming targets fail on undefined `_lua*`
  symbols.
- **rustls pinned to `ring`.** The workspace mixes reqwest majors, which enables both `ring` and
  `aws-lc-rs`; rustls then refuses to pick a provider and panics, poisoning a mutex that later
  aborts the whole test process. The fix rewrites `reqwest = … "rustls"` to `"rustls-no-provider"`
  in three manifests. `verify_single_rustls_provider` fails the build if both providers survive.

If either patch starts printing "upstream may have fixed this already", check before assuming.

---

## 6. Cutting a release

### 6.1 Before you start

- [ ] `main` is up to date and your working tree is clean (the check uses `git diff-index`, so
      untracked files slip past it — check `git status` yourself).
- [ ] Submodules initialised and on the intended commits. The script now refuses to start
      otherwise — see the warning under 6.4.
- [ ] `libpact_ffi.version` pins the version you intend to release.
- [ ] `Resources/**/libpact_ffi.a` built from that version.
- [ ] All three schemes archive; tests pass on macOS and iOS Simulator.
- [ ] `gh auth status` is good, and GPG signing works (`echo test | gpg --clearsign`).

### 6.2 Rehearse

```bash
./Support/Scripts/release --dry-run
```

`--dry-run` is genuinely read-only: no file edits, no branch, no tag, no push, no GitHub calls. It
prints what each step *would* do, uses a placeholder checksum (all zeros — it has no zip to hash),
and tolerates a dirty working tree so you can rehearse while still working. Read the output,
especially the generated release notes and the computed version tag.

### 6.3 Release

```bash
./Support/Scripts/release            # releases the pinned libpact_ffi version
./Support/Scripts/release -v patch   # Swift-side-only re-release
```

Useful flags:

| Flag | Effect |
|---|---|
| `-v ffi` | Default. Release the version pinned in `libpact_ffi.version`. Refuses if that version is already released. |
| `-v patch` | Swift-side-only re-release against the same FFI version; drifts the patch ahead (see §1). |
| `-i`, `--interactive` | Pause for confirmation after every step. **Recommended** — the script has no rollback. |
| `--skip-rust-build` | Ship the binaries already in `Resources/` instead of rebuilding (~1 hour saved). Only safe if they were built from the version this release claims; the script prints each file's build time so you can check. |
| `--draft` / `--pre-release` | Passed through to `gh release create`. |
| `-d "description"` | Appends to the tag, producing `v0.5.9 - description` — **spaces and all**, in the tag, the release title and the zip filename. Avoid. |

`-v major` and `-v minor` are rejected with an explanation; they are meaningless now that the
version tracks `libpact_ffi`.

### 6.4 What it does, in order

1. Verifies the working tree is clean and the `XCFramework` submodule is initialised.
2. Takes the version from `libpact_ffi.version` (see §1) and bumps `MARKETING_VERSION` on line 2 of
   [`Project-Shared.xcconfig`](../Configurations/Project-Shared.xcconfig) — that line is
   position-sensitive and rewritten by `sed`.
3. Generates release notes into `TAG_MESSAGE_FILE.tmp` and prepends them to `CHANGELOG.md`. The
   range is `<latest-tag>..HEAD` when that tag exists *in this repository*, and the full history
   otherwise — this repo is tagged by the merge workflow, so a fresh clone may have no tags.
4. Stashes and immediately re-applies the changelog. This looks like a no-op; its only purpose is
   to survive the `git checkout --force` in `cleanup()` at the end. See known issue 16.
5. Creates branch `rc/<tag>`.
6. Builds the Rust binaries (unless `--skip-rust-build`), then the XCFramework, zips it and
   computes the SwiftPM checksum.
7. Commits the changelog, xcconfig and `Package.swift`, signed.
8. In the `XCFramework` submodule: copies the changelog, rewrites `Package.swift` with the new
   download URL and checksum, commits, tags, and **pushes to `main` on the release repo**. This is
   the point of no return.
9. Creates the GitHub release on `pact-swift-xcframework` and uploads the zip plus its checksum.
10. Commits the updated submodule pointer here, pushes `rc/<tag>`, and opens a PR against `main`.
11. `cleanup()`: force-checks-out the original branch, deletes `rc/<tag>` locally, re-applies the
    stash, commits **everything** with `git add .`, and runs `git clean -fdx`.

> [!WARNING]
> Step 11 is the sharpest edge in the whole flow. `git add .` sweeps up any unrelated untracked or
> modified file into a commit on your working branch, that commit is **not** signed, and
> `git clean -fdx` deletes `Resources/**/*.a` and `.build/` — forcing a full ~1 hour Rust rebuild
> next time. Have a clean tree before you start, and check `git log -1` afterwards.

> [!NOTE]
> Step 8 assumes the `XCFramework` submodule is checked out. If it is not, the directory is empty,
> `cd` into it still succeeds, and **git walks up to this repository** — so the commit, the tag and
> `git push origin main` would all land on `pact-swift-mock-server`, pushing an unreviewed release
> commit straight to `main`. `git_check_submodules_initialised` now refuses to start in that state,
> on real runs and dry runs alike.

### 6.5 Finishing up

Merging the PR fires [`pr.yml`](../.github/workflows/pr.yml), which reads `MARKETING_VERSION` back
out of the xcconfig and creates the matching `v<version>` release **on this repo**. So the release
on `pact-swift-xcframework` is created by the script; the one here is created by the merge.

Then verify:

- [ ] Release exists on `pact-swift-xcframework` with both the `.zip` and `.zip.checksum` assets.
- [ ] Its `Package.swift` URL and checksum match what was uploaded:

```bash
swift package compute-checksum PactSwiftMockServer-v0.5.9.zip
```

- [ ] Resolving the new version from a scratch package succeeds.
- [ ] Tag exists on this repo, and `CHANGELOG.md` on `main` has the new section.

---

## 7. Rolling back

```bash
./Support/Scripts/release_delete --tag v0.5.9 --dry-run
```

Drop `--dry-run` to actually: delete the GitHub release and tag on `pact-swift-xcframework`, close
the PR and delete its branch, remove local and remote `rc/` branches and tags, soft-reset the last
commit and stash the result.

It does **not** revert the commit pushed to `main` on the `XCFramework` submodule repo — handle that
by hand.

---

## 8. Release-blocking bugs fixed on 2026-09-25

Recorded here because the symptoms are distinctive and may resurface.

### Repository name conflated with the Xcode product name — fixed

`XCPRODUCT_NAME="PactSwiftMockServer"` was reused as a *GitHub repository* name in three places.
`pact-foundation/PactSwiftMockServer` does not exist — the repo was renamed to
`pact-swift-mock-server` in the org move — so opening the release PR failed outright.

`config.sh` now carries a separate `SOURCE_REPO_NAME`, used by
`github_create_pull_request_for_new_version`, `close_pr_for_version` and the changelog commit-URL
template. `XCPRODUCT_NAME` is back to meaning only the Xcode product: the project, the schemes, the
framework and the published XCFramework name.

### Version computation yielded `vnull.1.0` — fixed

`latest_tag` piped the tags API through `jq -r '.[0].name'`. On an empty release repo that prints
the *string* `null`, which is not empty, so the `v0.0.0` fallback never fired and a `minor` bump
produced `vnull.1.0`. `git log 'null'..HEAD` failed too, taking the release notes with it.

Superseded by the FFI-derived versioning in §1. Alongside it:

- `release_repo_tags` uses `// empty` and fails loudly on an API error instead of silently
  returning a bad tag.
- The duplicate-tag guard checks the **release** repo. It used to run `git tag --list` here, where
  none of the release tags live, so it could never fire.
- `release_notes_range` falls back to the full history when the previous tag is not a tag in this
  repository, instead of emitting `..HEAD` — which git reads as `HEAD..HEAD`, i.e. empty notes.

### Release could push to the wrong repository — fixed

An uninitialised `XCFramework` submodule is an empty directory. `cd` into it succeeds and git then
walks up to this repository, so the submodule's commit, tag and `git push origin main` would all
have landed on `pact-swift-mock-server`. `git_check_submodules_initialised` now refuses to start.

Everything else is catalogued in [`known-issues.md`](known-issues.md).

---

## 9. Script reference

| Script | Purpose |
|---|---|
| [`Support/Scripts/test`](../Support/Scripts/test) | Build and test a scheme/destination pair with coverage. |
| [`Support/Scripts/release`](../Support/Scripts/release) | The whole release flow. `--dry-run` first, always. |
| [`Support/Scripts/release_delete`](../Support/Scripts/release_delete) | Undo a release. |
| [`…/CI/configure_build_tools`](../Support/Scripts/CI/configure_build_tools) | Install Homebrew tooling and rustup. |
| [`…/CI/build_rust_dependencies`](../Support/Scripts/CI/build_rust_dependencies) | Build `libpact_ffi.a` for three triples, merge Lua, regenerate `pact_ffi.h`. |
| [`…/CI/build_xcframework`](../Support/Scripts/CI/build_xcframework) | Archive three schemes, assemble the XCFramework, zip, checksum. Takes a version argument. |
| [`…/CI/version_numbers.sh`](../Support/Scripts/CI/version_numbers.sh) | `latest_tag`, `generate_version_number`. |
| [`…/Config/config.sh`](../Support/Scripts/Config/config.sh) | Repo names, file paths, deployment targets, Xcode floor. |
| [`…/Config/rust_config.sh`](../Support/Scripts/Config/rust_config.sh) | Target triples and the nightly toolchain (required — `cbindgen` fails on stable). |
