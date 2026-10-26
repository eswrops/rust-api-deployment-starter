//! Library surface of the Rust API starter. The `rust-api` binary in
//! `main.rs` wires these modules into the HTTP service; integration tests
//! and future services reuse them directly.

pub mod auth;
pub mod db;
