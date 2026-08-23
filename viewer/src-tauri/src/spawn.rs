//! Spawn command relay — device secret stays in Rust; webview calls Tauri commands only.
//!
//! Local pairing files (never committed):
//!   ~/.config/agent-switchboard/device-secret  — 32-byte pair secret (raw or base64url), mode 0600
//!   ~/.config/agent-switchboard/edge.json    — url, bearer, device_id (gitignored)
//!   ~/.config/agent-switchboard/seq.json       — per-device monotonic command seq

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use ulid::Ulid;

use crate::crypto::{self, verify_result_sig};

#[derive(Debug, Deserialize)]
pub struct EdgeConfig {
    pub url: String,
    pub bearer: String,
    #[serde(default)]
    pub device_id: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SubmitSpawnResponse {
    pub command_id: String,
    pub accepted: bool,
}

#[derive(Debug, Serialize)]
pub struct SpawnResultPayload {
    pub id: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job_ref: Option<String>,
    pub at: String,
    pub signature_valid: bool,
    pub display_state: String,
}

fn config_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join(".config")
            .join("agent-switchboard")
    })
}

fn device_secret_path() -> Option<PathBuf> {
    config_dir().map(|d| d.join("device-secret"))
}

fn seq_store_path() -> Option<PathBuf> {
    config_dir().map(|d| d.join("seq.json"))
}

fn edge_config_path() -> Option<PathBuf> {
    config_dir().map(|d| d.join("edge.json"))
}

fn viewer_local_edge_config_path() -> Option<PathBuf> {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .map(|p| p.join("edge.local.json"))
        .filter(|p| p.is_file())
}

pub fn load_edge_config() -> Option<EdgeConfig> {
    let candidates: Vec<PathBuf> = viewer_local_edge_config_path()
        .into_iter()
        .chain(edge_config_path())
        .collect();
    for path in candidates {
        if !path.is_file() {
            continue;
        }
        let raw = fs::read_to_string(&path).ok()?;
        if let Ok(cfg) = serde_json::from_str::<EdgeConfig>(&raw) {
            if !cfg.url.trim().is_empty() && !cfg.bearer.trim().is_empty() {
                return Some(cfg);
            }
        }
    }
    None
}

fn load_device_secret() -> Option<Vec<u8>> {
    let path = device_secret_path()?;
    if !path.is_file() {
        return None;
    }
    let raw = fs::read(&path).ok()?;
    parse_device_secret(&raw)
}

fn parse_device_secret(raw: &[u8]) -> Option<Vec<u8>> {
    if raw.len() == 32 {
        return Some(raw.to_vec());
    }
    let text = std::str::from_utf8(raw).ok()?.trim();
    if text.is_empty() {
        return None;
    }
    if text.len() == 64 && text.chars().all(|c| c.is_ascii_hexdigit()) {
        return hex::decode(text).ok().filter(|b| b.len() == 32);
    }
    crypto::b64url_decode(text)
        .ok()
        .filter(|b| b.len() == 32)
        .or_else(|| {
            use base64::Engine;
            base64::engine::general_purpose::STANDARD
                .decode(text)
                .ok()
                .filter(|b| b.len() == 32)
        })
}

pub fn spawn_pairing_available() -> bool {
    load_device_secret().is_some()
        && load_edge_config()
            .and_then(|c| c.device_id.filter(|d| !d.trim().is_empty()))
            .is_some()
}

fn pairing_bundle() -> Result<(EdgeConfig, Vec<u8>, String), String> {
    let secret = load_device_secret().ok_or_else(|| "not paired".to_string())?;
    let cfg = load_edge_config().ok_or_else(|| "edge config not found".to_string())?;
    let device_id = cfg
        .device_id
        .clone()
        .filter(|d| !d.trim().is_empty())
        .ok_or_else(|| "not paired".to_string())?;
    Ok((cfg, secret, device_id))
}

fn next_seq(device_id: &str) -> Result<u64, String> {
    let path = seq_store_path().ok_or_else(|| "config dir unavailable".to_string())?;
    let mut map: BTreeMap<String, u64> = if path.is_file() {
        let raw = fs::read_to_string(&path).unwrap_or_default();
        serde_json::from_str(&raw).unwrap_or_default()
    } else {
        BTreeMap::new()
    };
    let next = map.get(device_id).copied().unwrap_or(0) + 1;
    map.insert(device_id.to_string(), next);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("mkdir config: {e}"))?;
    }
    let body = serde_json::to_string_pretty(&map).map_err(|e| format!("seq json: {e}"))?;
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)
        .map_err(|e| format!("open seq store: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    }
    file.write_all(body.as_bytes())
        .map_err(|e| format!("write seq store: {e}"))?;
    Ok(next)
}

pub fn is_valid_prompt(text: &str) -> bool {
    if text.len() > 4000 {
        return false;
    }
    for ch in text.chars() {
        let v = ch as u32;
        if v < 32 && ch != '\n' && ch != '\t' {
            return false;
        }
    }
    true
}

fn build_spawn_cmd(host: &str, agent: &str, workdir_id: &str, prompt: &str) -> Result<Value, String> {
    if !is_valid_prompt(prompt) {
        return Err("invalid prompt".into());
    }
    let workdir = if workdir_id.trim().is_empty() {
        "desktop"
    } else {
        workdir_id.trim()
    };
    Ok(json!({
        "type": "spawn",
        "host": host,
        "agent": agent,
        "workdir_id": workdir,
        "prompt": prompt,
    }))
}

fn http_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| format!("http client: {e}"))
}

pub fn submit_spawn(
    host: String,
    agent: String,
    workdir_id: String,
    prompt: String,
) -> Result<SubmitSpawnResponse, String> {
    let (cfg, secret, device_id) = pairing_bundle()?;
    let cmd = build_spawn_cmd(&host, &agent, &workdir_id, &prompt)?;
    let command_id = Ulid::new().to_string();
    let seq = next_seq(&device_id)?;
    let issued_at = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let iv: [u8; 12] = rand::random();
    let envelope = crypto::build_envelope(
        &cmd,
        &secret,
        &device_id,
        &command_id,
        seq,
        &issued_at,
        &iv,
    )?;

    let base = cfg.url.trim().trim_end_matches('/');
    let url = format!("{base}/v1/command");
    let client = http_client()?;
    let resp = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", cfg.bearer.trim()))
        .header("Content-Type", "application/json")
        .header("Cache-Control", "no-store")
        .json(&envelope)
        .send()
        .map_err(|e| format!("post {url}: {e}"))?;

    let status = resp.status();
    if status == reqwest::StatusCode::CREATED {
        return Ok(SubmitSpawnResponse {
            command_id,
            accepted: true,
        });
    }

    let body: Value = resp.json().unwrap_or(json!({}));
    let code = body
        .get("error")
        .and_then(|v| v.as_str())
        .unwrap_or("submit_failed");
    Err(format!("{code} (HTTP {status})"))
}

pub fn fetch_spawn_result(command_id: String) -> Result<Option<SpawnResultPayload>, String> {
    let (cfg, secret, _device_id) = pairing_bundle()?;
    let base = cfg.url.trim().trim_end_matches('/');
    let url = format!("{base}/v1/command/result?id={command_id}");
    let client = http_client()?;
    let resp = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", cfg.bearer.trim()))
        .header("Cache-Control", "no-store")
        .send()
        .map_err(|e| format!("get {url}: {e}"))?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if !resp.status().is_success() {
        let status = resp.status();
        let body: Value = resp.json().unwrap_or(json!({}));
        let code = body
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("result_failed");
        return Err(format!("{code} (HTTP {status})"));
    }

    let raw: Value = resp
        .json()
        .map_err(|e| format!("parse result JSON: {e}"))?;
    Ok(Some(parse_result(&raw, &secret)))
}

fn parse_result(raw: &Value, secret: &[u8]) -> SpawnResultPayload {
    let id = raw.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let status = raw
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let at = raw.get("at").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let reason = raw
        .get("reason")
        .and_then(|v| if v.is_null() { None } else { v.as_str() })
        .map(str::to_string);
    let job_ref = raw
        .get("job_ref")
        .and_then(|v| if v.is_null() { None } else { v.as_str() })
        .map(str::to_string);
    let sig_present = raw
        .get("sig")
        .and_then(|v| v.as_str())
        .is_some_and(|s| !s.is_empty());
    let signature_valid = verify_result_sig(raw, secret);
    let display_state = if signature_valid {
        "verified"
    } else if sig_present {
        "bad_signature"
    } else {
        "unconfirmed"
    };
    SpawnResultPayload {
        id,
        status,
        reason,
        job_ref,
        at,
        signature_valid,
        display_state: display_state.to_string(),
    }
}
