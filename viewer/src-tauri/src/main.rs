// Agent Switchboard viewer — thin Tauri 2 shell around the static dashboard.
// All data comes from the switchboard daemon (127.0.0.1:17920); the viewer is
// read-only by design (observe-only policy) so the shell needs no commands.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("error while running Agent Switchboard");
}
