//! Per-VM TAP networking.
//!
//! VM `n` gets TAP device `tap<n>` with host address `172.16.<n>.1/30`; the
//! guest is `172.16.<n>.2` and its MAC is `AA:FC:00:00:<hi>:<lo>` from the
//! low 16 bits of `n`. Creating and deleting TAP devices shells out to `ip`
//! and only exists on Linux; elsewhere [`create_tap`] fails with
//! [`NetworkError::Unsupported`] and the VM boots without a network.

/// TAP setup failed.
#[derive(Debug, thiserror::Error)]
pub enum NetworkError {
    #[error("TAP networking is only supported on Linux")]
    Unsupported,
    #[error("failed to run `ip {args}`: {source}")]
    Spawn {
        args: String,
        #[source]
        source: std::io::Error,
    },
}

/// Name of the TAP device for `vm_index`.
pub fn tap_name(vm_index: u32) -> String {
    format!("tap{vm_index}")
}

/// Host-side TAP address with prefix length.
pub fn host_cidr(vm_index: u32) -> String {
    format!("172.16.{vm_index}.1/30")
}

/// Guest IP for `vm_index`.
pub fn guest_ip(vm_index: u32) -> String {
    format!("172.16.{vm_index}.2")
}

/// Gateway (host TAP) IP for `vm_index`.
pub fn gateway_ip(vm_index: u32) -> String {
    format!("172.16.{vm_index}.1")
}

/// Guest MAC address for `vm_index`.
pub fn mac_address(vm_index: u32) -> String {
    format!(
        "AA:FC:00:00:{:02X}:{:02X}",
        (vm_index >> 8) as u8,
        vm_index as u8
    )
}

/// The `ip` invocations that create and bring up the TAP device.
pub fn create_tap_commands(vm_index: u32) -> [Vec<String>; 3] {
    let tap = tap_name(vm_index);
    let cidr = host_cidr(vm_index);
    [
        vec![
            "tuntap".into(),
            "add".into(),
            tap.clone(),
            "mode".into(),
            "tap".into(),
        ],
        vec!["addr".into(), "add".into(), cidr, "dev".into(), tap.clone()],
        vec!["link".into(), "set".into(), tap, "up".into()],
    ]
}

/// Create and bring up the TAP device for `vm_index`; returns its name.
///
/// A non-zero exit from `ip` is logged and ignored (the device may already
/// exist), as in the Zig implementation. Failing to run `ip` is an error.
#[cfg(target_os = "linux")]
pub async fn create_tap(vm_index: u32) -> Result<String, NetworkError> {
    let tap = tap_name(vm_index);
    for args in create_tap_commands(vm_index) {
        let out = tokio::process::Command::new("ip")
            .args(&args)
            .output()
            .await
            .map_err(|source| NetworkError::Spawn {
                args: args.join(" "),
                source,
            })?;
        if !out.status.success() {
            tracing::warn!(
                operation = "create_tap",
                node_id = %crate::identity::label(),
                tap = %tap,
                command = %args.join(" "),
                stderr = %String::from_utf8_lossy(&out.stderr).trim(),
                "ip returned non-zero (device may already exist)"
            );
        }
    }
    tracing::info!(operation = "create_tap", node_id = %crate::identity::label(), tap = %tap, ip = %host_cidr(vm_index), "TAP device created");
    Ok(tap)
}

#[cfg(not(target_os = "linux"))]
pub async fn create_tap(_vm_index: u32) -> Result<String, NetworkError> {
    Err(NetworkError::Unsupported)
}

/// Delete a TAP device, ignoring failures.
#[cfg(target_os = "linux")]
pub fn destroy_tap(tap: &str) {
    match std::process::Command::new("ip")
        .args(["link", "del", tap])
        .output()
    {
        Ok(out) if out.status.success() => {
            tracing::debug!(operation = "destroy_tap", node_id = %crate::identity::label(), tap, "TAP device deleted");
        }
        Ok(out) => tracing::warn!(
            operation = "destroy_tap",
            node_id = %crate::identity::label(),
            tap,
            stderr = %String::from_utf8_lossy(&out.stderr).trim(),
            "ip link del returned non-zero"
        ),
        Err(e) => {
            tracing::warn!(operation = "destroy_tap", node_id = %crate::identity::label(), tap, error = %e, "failed to run ip link del")
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn destroy_tap(_tap: &str) {}

#[cfg(test)]
mod tests {
    use super::*;

    // Port of Zig `test "mac address generation"`.
    #[test]
    fn mac_address_generation() {
        assert_eq!(mac_address(0), "AA:FC:00:00:00:00");
        assert_eq!(mac_address(42), "AA:FC:00:00:00:2A");
        assert_eq!(mac_address(0x1234), "AA:FC:00:00:12:34");
        assert_eq!(mac_address(0x0001_0203), "AA:FC:00:00:02:03");
    }

    #[test]
    fn addresses_follow_vm_index() {
        assert_eq!(tap_name(3), "tap3");
        assert_eq!(host_cidr(3), "172.16.3.1/30");
        assert_eq!(guest_ip(3), "172.16.3.2");
        assert_eq!(gateway_ip(3), "172.16.3.1");
    }

    #[test]
    fn tap_commands_match_zig() {
        let [add, addr, up] = create_tap_commands(7);
        assert_eq!(add.join(" "), "tuntap add tap7 mode tap");
        assert_eq!(addr.join(" "), "addr add 172.16.7.1/30 dev tap7");
        assert_eq!(up.join(" "), "link set tap7 up");
    }

    #[cfg(not(target_os = "linux"))]
    #[tokio::test]
    async fn tap_unsupported_off_linux() {
        assert!(matches!(
            create_tap(1).await,
            Err(NetworkError::Unsupported)
        ));
        destroy_tap("tap1");
    }
}
