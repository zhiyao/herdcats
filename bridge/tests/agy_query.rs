use herdcats_bridge::agy;
use std::{
    ffi::OsStr,
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    time::{Duration, Instant},
};
// Keep fixture writes and process launches mutually exclusive. On Linux, a
// concurrent spawn can inherit another test's writable script descriptor until
// exec closes it, making that script temporarily fail to execute with ETXTBSY.
static CLI_FIXTURE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "hc-agy-query-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).unwrap();
        Self(root)
    }
    fn cli(&self, body: &str) -> PathBuf {
        let path = self.0.join(".local/bin/agy");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
#[test]
fn executable_resolution_supports_restricted_path_without_global_environment_changes() {
    let _guard = CLI_FIXTURE_LOCK.lock().unwrap();
    let temp = Temp::new();
    let executable = temp.cli("exit 0");
    assert_eq!(
        agy::resolve_executable(Some(OsStr::new("/usr/bin:/bin")), Some(&temp.0)).unwrap(),
        executable
    );
    let other = Temp::new();
    let preferred = other.cli("exit 0");
    let path = preferred.parent().unwrap().as_os_str();
    assert_eq!(
        agy::resolve_executable(Some(path), Some(&temp.0)).unwrap(),
        preferred
    );
    assert_eq!(
        agy::resolve_executable(Some(OsStr::new("relative")), None).unwrap_err(),
        "agy_unavailable"
    );
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(
        agy::resolve_executable(None, Some(&temp.0)).unwrap_err(),
        "agy_unavailable"
    );
}
#[test]
fn catalog_discovery_reports_version_empty_malformed_and_missing_errors() {
    let _guard = CLI_FIXTURE_LOCK.lock().unwrap();
    let temp = Temp::new();
    for (body, error) in [
        ("printf '1.4.8\\n'", "agy_unsupported_version"),
        (
            "if [ \"$1\" = --version ]; then printf '1.4.7\\n'; fi",
            "agy_catalog_empty",
        ),
        (
            "if [ \"$1\" = --version ]; then printf '1.4.7\\n'; else printf 'broken catalog\\n'; fi",
            "agy_catalog_invalid",
        ),
    ] {
        let executable = temp.cli(body);
        assert_eq!(
            agy::discover_catalog(&executable, Instant::now() + Duration::from_secs(1))
                .unwrap_err(),
            error
        );
    }
    assert_eq!(
        agy::discover_catalog(
            &temp.0.join("missing"),
            Instant::now() + Duration::from_secs(1)
        )
        .unwrap_err(),
        "agy_unavailable"
    );
    let executable=temp.cli("if [ \"$1\" = --version ]; then printf '1.4.7\\n'; else printf 'gemini-3.8-flash-low\\tGemini 3.8 Flash (Low)\\n'; fi");
    assert_eq!(
        agy::discover_catalog(&executable, Instant::now() + Duration::from_secs(1)).unwrap()[0].id,
        "gemini-3.8-flash-low"
    );
}
#[test]
fn version_and_models_share_one_deadline_and_output_is_bounded() {
    let _guard = CLI_FIXTURE_LOCK.lock().unwrap();
    let temp = Temp::new();
    let executable=temp.cli("/bin/sleep 0.09\nif [ \"$1\" = --version ]; then printf '1.4.7\\n'; else printf 'gemini-3.8-flash-low\\tGemini 3.8 Flash (Low)\\n'; fi");
    let start = Instant::now();
    assert_eq!(
        agy::discover_catalog(&executable, start + Duration::from_millis(140)).unwrap_err(),
        "agy_timeout"
    );
    assert!(start.elapsed() < Duration::from_millis(500));
    let executable = temp.cli(&format!("printf '{}'", "x".repeat(70_000)));
    assert_eq!(
        agy::query_executable(
            &executable,
            &["models"],
            Instant::now() + Duration::from_secs(1)
        )
        .unwrap_err(),
        "agy_catalog_invalid"
    );
    assert_eq!(
        agy::query_executable(&executable, &["models"], Instant::now()).unwrap_err(),
        "agy_timeout"
    );
}
