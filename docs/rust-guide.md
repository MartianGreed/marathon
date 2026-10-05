# Rust code standards

Use the stable channel selected by `rust-toolchain.toml`. The workspace uses edition 2024 and requires Rust 1.88 or newer. Run `make lint` and `make test` before handing off changes.

## Ownership and allocation

Prefer borrowed `&str` and slices when callers retain ownership. Use stack arrays for small bounded buffers. Allocate `Vec` and `String` only when ownership or growth requires them; reserve known capacities and reuse buffers where measurements justify it. Avoid needless clones, large value copies, and allocations in hot loops. Use `Arc` for shared ownership across async tasks, keeping lock scopes short and never holding synchronous guards across `.await`.

RAII releases owned memory and resources on scope exit. Use guards for reservations and partial initialization, and explicit shutdown for processes, sockets, and async work that needs cleanup. Cancellation and error paths must release VM slots. Avoid `unwrap` and `expect` on external input or fallible production operations.

## Errors and data types

Define typed library errors with `thiserror`; use `anyhow` with context at application boundaries. Propagate errors with `?`, and match only when the caller can recover or translate an error. Keep underlying causes. Validate lengths, integer conversions, IDs, and frame sizes before using input. Use `Option` for absence and `Result` for failure; do not silently turn failures into success.

Use slices for bounded access, `Vec` for growing sequences, and `HashMap` for keyed lookup. Prefer iterator operations and checked conversions over raw pointers. Workspace lint policy is `unsafe_code = "deny"`; preserve it.

## Traits, generics, and performance

Use generics and trait bounds for reusable behavior with static dispatch. Use trait objects when runtime substitution is needed, such as stores and VM launchers in tests. Prefer concrete abstractions driven by current callers. Use constants and `const fn` for compile-time values where useful.

Measure before optimizing or adding inline annotations. Debug builds support development; `cargo build --workspace --release --locked` uses the workspace release profile with thin LTO. Retain bounds checks and validation. Do not trade correctness for speculative speed.

## Dependencies and tests

Declare shared dependency versions in `[workspace.dependencies]`; crates inherit them with `workspace = true`. Keep the lockfile reproducible with `--locked` in CI and image builds. `common/build.rs` generates protobuf bindings using `protoc`.

Put unit tests next to code in `#[cfg(test)]` modules and integration tests in each crate's `tests/` directory. Cover failure, cleanup, cancellation, and boundary cases as well as success. PostgreSQL integration tests require `MARATHON_TEST_POSTGRES_URL`; set `MARATHON_TEST_REQUIRE_POSTGRES=1` to make a missing database fail instead of skip. Run `cargo fmt --all --check` and `cargo clippy --workspace --all-targets -- -D warnings`.

## Observability

Use `tracing` events and spans with structured `task_id`, `node_id`, `operation`, and `duration_ms` fields. Include contextual errors, but never log credentials or tokens. Use `error` for failures, `warn` for degraded states, `info` for transitions, and `debug` for internals. Propagate trace context across gRPC and vsock messages. Record counters, latency histograms, and capacity gauges where operations need them.

## Migration from Zig

The project was ported from Zig in October 2026. Crate comments cite the Zig implementation where behavior was kept for compatibility with existing databases, credential files, and Firecracker request bodies. The Zig sources are available in git history before the removal commit.
