//! Generates the `marathon.v1` protobuf types and tonic clients/servers from
//! `proto/marathon/v1`. Requires `protoc` on PATH or in `PROTOC`.

const PROTO_ROOT: &str = "../proto";
const PROTOS: &[&str] = &[
    "../proto/marathon/v1/types.proto",
    "../proto/marathon/v1/marathon.proto",
    "../proto/marathon/v1/node.proto",
    "../proto/marathon/v1/vsock.proto",
];

/// Messages generated without `#[derive(Debug)]`.
const SECRET_MESSAGES: &[&str] = &[
    ".marathon.v1.EnvVar",
    ".marathon.v1.SubmitTaskRequest",
    ".marathon.v1.RegisterRequest",
    ".marathon.v1.LoginRequest",
    ".marathon.v1.AuthResponse",
    ".marathon.v1.NodeAuth",
    ".marathon.v1.ExecuteTask",
    ".marathon.v1.VsockStart",
];

fn main() -> Result<(), Box<dyn std::error::Error>> {
    for proto in PROTOS {
        println!("cargo:rerun-if-changed={proto}");
    }
    tonic_prost_build::configure()
        .build_client(true)
        .build_server(true)
        // These carry passwords, tokens, API keys or env var values. Their
        // redacting `Debug` impls live in `src/redact.rs`.
        .skip_debug(SECRET_MESSAGES.iter().copied())
        .compile_protos(PROTOS, &[PROTO_ROOT])?;
    Ok(())
}
