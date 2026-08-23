fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(
            tauri_build::AppManifest::new().commands(&[
                "start_daemon",
                "fetch_fleet_dashboard",
                "fetch_local_cli",
                "fetch_local_status",
                "fetch_local_health",
                "wait_local",
                "spawn_pairing_available",
                "submit_spawn",
                "fetch_spawn_result",
            ]),
        ),
    )
    .expect("tauri build failed");
}
