// Agent Switchboard viewer — thin Tauri 2 shell around the fleet dashboard frontend.
// Rust fetches the published dashboard shape (LAN-direct on-fleet, else halus).
// Spawn uses Rust-side envelope crypto; device secret never enters the webview.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod crypto;
mod network;
mod spawn;

use std::process::Command;

use serde_json::Value;

const VIEWER_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

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
#[tauri::command]
fn fetch_fleet_dashboard() -> Result<Value, String> {
    let cfg = spawn::load_edge_config().ok_or_else(|| "edge config not found".to_string())?;
    let bearer = cfg.bearer.trim();
    let halus = cfg.url.trim().trim_end_matches('/');

    let lan_base = cfg
        .lan_url
        .as_ref()
        .map(|s| s.trim().trim_end_matches('/'))
        .filter(|s| !s.is_empty());

    if network::on_fleet_network() {
        if let Some(lan) = lan_base {
            if let Ok(doc) = get_dashboard(lan, bearer) {
                return Ok(doc);
            }
        }
    }

    get_dashboard(halus, bearer)
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

/// Kickstart the launchd switchboard job: gui/<uid>/com.agent-switchboard.
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
            fetch_fleet_dashboard,
            spawn_pairing_available,
            submit_spawn,
            fetch_spawn_result,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Agent Switchboard");
}
