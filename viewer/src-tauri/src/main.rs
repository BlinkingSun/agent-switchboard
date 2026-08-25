// Agent Switchboard viewer — thin Tauri 2 shell around the fleet dashboard frontend.
// This machine's sessions come from the local daemon (127.0.0.1:17920).
// Other hosts come from the published dashboard (LAN-direct on-fleet, else halus).
// Spawn uses Rust-side envelope crypto; device secret never enters the webview.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod crypto;
mod network;
mod spawn;

use std::path::PathBuf;
use std::process::Command;

use serde_json::Value;

const VIEWER_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
const LOCAL_DAEMON: &str = "http://127.0.0.1:17920";

fn dashboard_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .user_agent(VIEWER_UA)
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("http client: {e}"))
}

fn get_dashboard(base: &str, bearer: &str) -> Result<Value, String> {
    let base = base.trim().trim_end_matches('/');
    if base.is_empty() {
        return Err("dashboard base url is empty".to_string());
    }
    let url = format!("{base}/v1/dashboard");
    let client = dashboard_client()?;
    let resp = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", bearer.trim()))
        .header("Cache-Control", "no-store")
        .send()
        .map_err(|e| format!("fetch {url}: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("fetch {url}: HTTP {}", resp.status()));
    }
    resp.json::<Value>()
        .map_err(|e| format!("parse dashboard JSON: {e}"))
}

/// Fleet dashboard: LAN (lan_url) when on fleet subnet, else halus; LAN failure falls back to halus.
fn fetch_fleet_dashboard_inner() -> Result<Value, String> {
    let cfg = spawn::load_edge_config().ok_or_else(|| "edge config not found".to_string())?;
    let bearer = cfg.bearer.trim();
    let halus = cfg.url.trim().trim_end_matches('/');

    let lan_candidates: Vec<String> = [cfg.lan_url.as_deref(), cfg.lan_url_ip.as_deref()]
        .into_iter()
        .flatten()
        .map(|s| s.trim().trim_end_matches('/').to_string())
        .filter(|s| !s.is_empty())
        .collect();

    if network::on_fleet_network() {
        for lan in &lan_candidates {
            if let Ok(doc) = get_dashboard(lan, bearer) {
                return Ok(doc);
            }
        }
    }

    get_dashboard(halus, bearer)
}

#[tauri::command]
async fn fetch_fleet_dashboard() -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(fetch_fleet_dashboard_inner)
        .await
        .map_err(|e| format!("fleet join: {e}"))?
}

fn local_client(timeout_s: u64) -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .user_agent(VIEWER_UA)
        .timeout(std::time::Duration::from_secs(timeout_s))
        .build()
        .map_err(|e| format!("http client: {e}"))
}

fn get_local_json(path: &str, timeout_s: u64) -> Result<Value, String> {
    let url = format!("{LOCAL_DAEMON}{path}");
    let client = local_client(timeout_s)?;
    let resp = client
        .get(&url)
        .header("Cache-Control", "no-store")
        .send()
        .map_err(|e| format!("fetch {url}: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("fetch {url}: HTTP {}", resp.status()));
    }
    resp.json::<Value>()
        .map_err(|e| format!("parse {url}: {e}"))
}

/// This-machine daemon: CLI spawn tree (includes virtual grok-sub children).
#[tauri::command]
fn fetch_local_cli() -> Result<Value, String> {
    get_local_json("/v1/cli", 8)
}

/// This-machine daemon: health (cursor for /v1/wait).
#[tauri::command]
fn fetch_local_health() -> Result<Value, String> {
    get_local_json("/v1/health", 3)
}

/// This-machine daemon: lane status.
#[tauri::command]
fn fetch_local_status() -> Result<Value, String> {
    get_local_json("/v1/status", 8)
}

/// This-machine daemon: long-poll until a lane/cli event or timeout.
/// Async so the 25s wait does not stall other Tauri commands (local cli, fleet).
#[tauri::command]
async fn wait_local(cursor: u64, timeout: Option<u64>) -> Result<Value, String> {
    let t = timeout.unwrap_or(25).clamp(1, 55);
    tauri::async_runtime::spawn_blocking(move || {
        let path = format!("/v1/wait?cursor={cursor}&timeout={t}");
        get_local_json(&path, t + 5)
    })
    .await
    .map_err(|e| format!("wait_local join: {e}"))?
}

/// True when device secret + edge device_id are provisioned (spawn dormant until then).
#[tauri::command]
fn spawn_pairing_available() -> bool {
    spawn::spawn_pairing_available()
}

/// Build signed envelope, POST /v1/command. Returns not paired if secret absent.
#[tauri::command]
fn submit_spawn(
    host: String,
    agent: String,
    workdir_id: String,
    prompt: String,
) -> Result<spawn::SubmitSpawnResponse, String> {
    spawn::submit_spawn(host, agent, workdir_id, prompt)
}

/// GET /v1/command/result?id= and verify hub signature.
#[tauri::command]
fn fetch_spawn_result(command_id: String) -> Result<Option<spawn::SpawnResultPayload>, String> {
    spawn::fetch_spawn_result(command_id)
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

/// Kickstart the OSS launchd switchboard job.
#[tauri::command]
fn start_daemon() -> Result<String, String> {
    let uid = current_uid()?;
    let labels = [format!("gui/{uid}/com.agent-switchboard")];
    let mut last_err = String::new();
    for target in &labels {
        let out = Command::new("launchctl")
            .args(["kickstart", target])
            .output()
            .map_err(|e| format!("launchctl spawn failed: {e}"))?;
        let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        if out.status.success() {
            return if !stdout.is_empty() {
                Ok(format!("kickstarted {target}: {stdout}"))
            } else {
                Ok(format!("kickstarted {target}"))
            };
        }
        last_err = if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            format!("exit {status}", status = out.status)
        };
    }
    Err(format!("kickstart {}: {last_err}", labels.join(" then ")))
}

fn overwatch_contrib_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join("overwatch-contrib"))
}

/// Fast path: push this machine's switchboard block to halus after a local daemon event.
#[tauri::command]
fn push_host_contrib() -> Result<(), String> {
    let contrib_dir = overwatch_contrib_dir().ok_or_else(|| "HOME not set".to_string())?;
    let script = contrib_dir.join("run-contrib.sh");
    if !script.is_file() {
        return Err(format!("contrib script missing: {}", script.display()));
    }
    Command::new(script)
        .arg("--host-only")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("spawn contrib: {e}"))?;
    Ok(())
}

fn main() { // viewer revive: instant tauri boot
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            start_daemon,
            fetch_fleet_dashboard,
            fetch_local_cli,
            fetch_local_status,
            fetch_local_health,
            wait_local,
            push_host_contrib,
            spawn_pairing_available,
            submit_spawn,
            fetch_spawn_result,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Agent Switchboard");
}
