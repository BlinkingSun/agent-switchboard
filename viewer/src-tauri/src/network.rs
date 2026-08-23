//! Fleet-network scope — local IPv4 vs configured fleet_subnet (no private IP committed).

use std::net::Ipv4Addr;
use std::str::FromStr;
use std::time::Duration;

use serde::Serialize;

use crate::spawn;

#[derive(Debug, Serialize)]
pub struct NetworkScope {
    pub edge_config_available: bool,
    pub fleet_subnet_configured: bool,
    pub on_fleet_network: bool,
}

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

fn local_daemon_reachable() -> bool {
    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
    {
        Ok(c) => c,
        Err(_) => return false,
    };
    client
        .get("http://127.0.0.1:17920/v1/health")
        .header("Cache-Control", "no-store")
        .send()
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

pub fn compute_network_scope() -> NetworkScope {
    let cfg = spawn::load_edge_config();
    if cfg.is_none() {
        return NetworkScope {
            edge_config_available: false,
            fleet_subnet_configured: false,
            on_fleet_network: true,
        };
    }
    let cfg = cfg.unwrap();
    let subnet = cfg
        .fleet_subnet
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    if let Some(subnet) = subnet {
        let on_net = any_local_ip_in_subnet(subnet);
        NetworkScope {
            edge_config_available: true,
            fleet_subnet_configured: true,
            on_fleet_network: on_net,
        }
    } else {
        NetworkScope {
            edge_config_available: true,
            fleet_subnet_configured: false,
            on_fleet_network: local_daemon_reachable(),
        }
    }
}
