//! Fleet-network scope — local IPv4 vs configured fleet_subnet (no private IP committed).

use std::net::Ipv4Addr;
use std::str::FromStr;

use crate::spawn;

fn parse_ipv4_u32(s: &str) -> Option<u32> {
    let addr = Ipv4Addr::from_str(s.trim()).ok()?;
    Some(u32::from_be_bytes(addr.octets()))
}

fn parse_subnet(subnet: &str) -> Option<(u32, u32)> {
    let (net_str, prefix_str) = subnet.trim().split_once('/')?;
    let prefix_len: u32 = prefix_str.trim().parse().ok()?;
    if prefix_len > 32 {
        return None;
    }
    let net = parse_ipv4_u32(net_str)?;
    let mask = if prefix_len == 0 {
        0
    } else {
        u32::MAX << (32 - prefix_len)
    };
    Some((net & mask, mask))
}

fn ip_in_subnet(ip: Ipv4Addr, net: u32, mask: u32) -> bool {
    let ip_u32 = u32::from_be_bytes(ip.octets());
    (ip_u32 & mask) == (net & mask)
}

/// Enumerate non-loopback local IPv4 addresses (macOS interfaces via get_if_addrs).
fn local_ipv4_addrs() -> Vec<Ipv4Addr> {
    get_if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|iface| !iface.is_loopback())
        .filter_map(|iface| match iface.addr {
            get_if_addrs::IfAddr::V4(v4) => Some(v4.ip),
            _ => None,
        })
        .collect()
}

fn any_local_ip_in_subnet(subnet: &str) -> bool {
    let (net, mask) = match parse_subnet(subnet) {
        Some(v) => v,
        None => return false,
    };
    local_ipv4_addrs()
        .iter()
        .any(|ip| ip_in_subnet(*ip, net, mask))
}

/// True when edge config has fleet_subnet and any local IPv4 is in that subnet.
pub fn on_fleet_network() -> bool {
    let cfg = match spawn::load_edge_config() {
        Some(c) => c,
        None => return false,
    };
    let subnet = match cfg
        .fleet_subnet
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        Some(s) => s,
        None => return false,
    };
    any_local_ip_in_subnet(subnet)
}
