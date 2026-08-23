// Agent Switchboard viewer — thin Tauri 2 shell around the static dashboard.
// Data comes from the switchboard daemon (127.0.0.1:17920). Observe-only for
// worker processes; start_daemon only kickstarts the launchd job for the
// daemon itself (never kills lanes). Off-LAN fleet view reads a gitignored
// edge config and fetches the published dashboard shape (read-only).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Deserialize)]
struct EdgeConfig {
    url: String,
    bearer: String,
}

/// Resolve ~/.config/agent-switchboard/edge.json (never committed).
fn edge_config_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join(".config")
            .join("agent-switchboard")
            .join("edge.json")
    })
}

/// Optional viewer-local override (gitignored): viewer/edge.local.json next to dist.
fn viewer_local_edge_config_path() -> Option<PathBuf> {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let local = manifest
        .parent()
        .map(|p| p.join("edge.local.json"));
    local.filter(|p| p.is_file())
}

fn load_edge_config() -> Option<EdgeConfig> {
    let candidates: Vec<PathBuf> = viewer_local_edge_config_path()
        .into_iter()
        .chain(edge_config_path())
        .collect();
    for path in candidates {
        if !path.is_file() {
            continue;
        }
        let raw = std::fs::read_to_string(&path).ok()?;
        if let Ok(cfg) = serde_json::from_str::<EdgeConfig>(&raw) {
            if !cfg.url.trim().is_empty() && !cfg.bearer.trim().is_empty() {
                return Some(cfg);
            }
        }
    }
    None
}

/// True when a local edge config file exists with url + bearer (no network).
#[tauri::command]
fn edge_config_available() -> bool {
    load_edge_config().is_some()
}

/// GET {url}/v1/dashboard with the configured device bearer (read-only).
#[tauri::command]
fn fetch_edge_dashboard() -> Result<Value, String> {
    let cfg = load_edge_config().ok_or_else(|| "edge config not found".to_string())?;
    let base = cfg.url.trim().trim_end_matches('/');
    if base.is_empty() {
        return Err("edge url is empty".to_string());
    }
    let url = format!("{base}/v1/dashboard");
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("http client: {e}"))?;
    let resp = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", cfg.bearer.trim()))
        .header("Cache-Control", "no-store")
        .send()
        .map_err(|e| format!("fetch {url}: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("fetch {url}: HTTP {}", resp.status()));
    }
    resp.json::<Value>()
        .map_err(|e| format!("parse dashboard JSON: {e}"))
}

/// Resolve current user id via `id -u` (never hard-code 501; live domain is gui/<uid>).
fn current_uid() -> Result<u32, String> {
    let out = Command::new("id")
        .arg("-u")
        .output()
        .map_err(|e| format!("id -u failed: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "id -u exit {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    let s = String::from_utf8_lossy(&out.stdout);
    s.trim()
        .parse::<u32>()
        .map_err(|e| format!("parse uid {:?}: {e}", s.trim()))
}

/// Kickstart the launchd switchboard job: gui/<uid>/com.agent-switchboard.
/// No -k (do not kill a healthy daemon). B1 owns ensure semantics; this is the
/// viewer START affordance only.
#[tauri::command]
fn start_daemon() -> Result<String, String> {
    let uid = current_uid()?;
    let target = format!("gui/{uid}/com.agent-switchboard");
    let out = Command::new("launchctl")
        .args(["kickstart", &target])
        .output()
        .map_err(|e| format!("launchctl spawn failed: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if !out.status.success() {
        let detail = if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            format!("exit {status}", status = out.status)
        };
        return Err(format!("kickstart {target}: {detail}"));
    }
    if !stdout.is_empty() {
        Ok(format!("kickstarted {target}: {stdout}"))
    } else {
        Ok(format!("kickstarted {target}"))
    }
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            start_daemon,
            edge_config_available,
            fetch_edge_dashboard
        ])
        .run(tauri::generate_context!())
        .expect("error while running Agent Switchboard");
}
