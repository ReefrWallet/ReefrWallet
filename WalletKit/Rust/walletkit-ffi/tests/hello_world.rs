//! Rust-side integration test, per the testing strategy in
//! `Walletkit/Docs/Overview.md`: tests here run against the crate directly
//! (`cargo test`), independent of any Swift/UniFFI bindings generation.

use walletkit_ffi::hello_world;

#[test]
fn hello_world_returns_greeting() {
    assert_eq!(hello_world(), "Hello, World!");
}
