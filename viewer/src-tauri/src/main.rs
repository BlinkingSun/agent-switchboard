// Agent Switchboard viewer — thin Tauri 2 shell around the static dashboard.
// Data comes from the switchboard daemon (127.0.0.1:17920). Observe-only for
// worker processes; start_daemon only kickstarts the launchd job for the
// daemon itself (never kills lanes). Off-LAN fleet view reads a gitignored
// edge config and fetches the published dashboard shape (read-only).
// Spawn uses Rust-side envelope crypto; device secret never enters the webview.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod crypto;
mod spawn;

use std::process::Command;

use serde_json::Value;

/// True when a local edge config file exists with url + bearer (no network).
#[tauri::command]
fn edge_config_available() -> bool {
    spawn::load_edge_config().is_some()
}

/// True when device secret + edge device_id are provisioned (spawn dormant until then).
#[tauri::command]
fn spawn_pairing_available() -> bool {
    spawn::spawn_pairing_available()
}

/// GET {url}/v1/dashboard with the configured device bearer (read-only).
#[tauri::command]
fn fetch_edge_dashboard() -> Result<Value, String> {
    let cfg = spawn::load_edge_config().ok_or_else(|| "edge config not found".to_string())?;
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
            fetch_edge_dashboard,
            spawn_pairing_available,
            submit_spawn,
            fetch_spawn_result,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Agent Switchboard");
}
