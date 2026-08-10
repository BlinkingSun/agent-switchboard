// Agent Switchboard viewer — thin Tauri 2 shell around the static dashboard.
// Data comes from the switchboard daemon (127.0.0.1:17920). Observe-only for
// worker processes; start_daemon only kickstarts the launchd job for the
// daemon itself (never kills lanes).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::Command;

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
        .invoke_handler(tauri::generate_handler![start_daemon])
        .run(tauri::generate_context!())
        .expect("error while running Agent Switchboard");
}
