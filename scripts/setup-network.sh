#!/bin/bash
# Setup host networking for Firecracker VMs
# Run once on the host to enable NAT for VMs

set -euo pipefail

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Get default outbound interface
DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -1)

# Setup NAT masquerade
iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i tap+ -o "$DEFAULT_IF" -j ACCEPT

echo "Network setup complete (forwarding via $DEFAULT_IF)"
