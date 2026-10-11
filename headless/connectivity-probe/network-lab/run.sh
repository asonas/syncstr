#!/bin/sh
set -eu
test "${SYNCSTR_ISOLATED_NETWORK_LAB:-}" = 1

cleanup() {
    ip netns del syncstr-lab-a 2>/dev/null || true
    ip netns del syncstr-lab-b 2>/dev/null || true
}
trap cleanup EXIT
ip netns add syncstr-lab-a
ip netns add syncstr-lab-b
ip link add lab-a type veth peer name lab-b
ip link set lab-a netns syncstr-lab-a
ip link set lab-b netns syncstr-lab-b
ip -n syncstr-lab-a address add 10.203.0.1/24 dev lab-a
ip -n syncstr-lab-b address add 10.203.0.2/24 dev lab-b
ip -n syncstr-lab-a link set lab-a up
ip -n syncstr-lab-b link set lab-b up
ip -n syncstr-lab-a link set lo up
ip -n syncstr-lab-b link set lo up
for node in syncstr-lab-a syncstr-lab-b; do
    if ip -n "$node" route get 203.0.113.1; then
        echo "Unexpected WAN route in $node" >&2
        exit 1
    fi
    if ip -n "$node" -6 route get 2001:db8::1; then
        echo "Unexpected IPv6 WAN route in $node" >&2
        exit 1
    fi
done
cargo test --locked --test network_faults -- --ignored --nocapture --test-threads=1
