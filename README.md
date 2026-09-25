# pact-swift-mock-server

[![MIT License](https://img.shields.io/badge/license-MIT-green.svg?style=flat)](LICENSE.md)

> [!WARNING]
> This repository is under heavy development! There are no guarantees or warranty of any kind!

A wrapper around [`libpact_ffi.a`](https://github.com/pact-foundation/pact-reference/tree/master/rust/pact_ffi) binary and exposed as XCFramework to be primarily used by [`pact-swift`](https://github.com/pact-foundation/pact-swift).

This repository contains the source code, scripts and tools required to generate a [PactSwiftMockServer.xcframework](https://github.com/pact-foundation/pact-swift-xcframework) binary package.
It is referenced and set as a dependency in [`pact-swift`](https://github.com/pact-foundation/pact-swift) swift package.

See [LICENSE.md](LICENSE.md) for licensing information.

> [!IMPORTANT]
> The `libpact_ffi.a` binaries for the supported architectures can add up to **`>200MB`** with each new built version if not optimised.
>
> Currently, the only way to keep each package resolve down to about ~90MB is to compile this repo's source code and the artifacts built from its submodules into an XCFramework, zip it, and distribute it as a binary target with a checksum through [pact-foundation/pact-swift-xcframework](https://github.com/pact-foundation/pact-swift-xcframework).
