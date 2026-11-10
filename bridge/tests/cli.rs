use serde_json::Value;
use std::process::Command;

#[test]
fn version_probe_needs_no_socket_or_home() {
    let output = Command::new(env!("CARGO_BIN_EXE_herdcats-bridge"))
        .arg("--version-json")
        .env_remove("HOME")
        .env_remove("HERDR_SOCKET_PATH")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stderr.is_empty());
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["name"], "herdcats-bridge");
    assert_eq!(value["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(value["protocol"], 1);
    assert_eq!(value["herdr_protocol"], 22);
    assert_eq!(value["agents"], serde_json::json!(["claude", "codex", "antigravity_cli", "pi", "cursor"]));

    let output_v = Command::new(env!("CARGO_BIN_EXE_herdcats-bridge"))
        .arg("--version")
        .env_remove("HOME")
        .env_remove("HERDR_SOCKET_PATH")
        .output()
        .unwrap();
    assert!(output_v.status.success());
    let value_v: Value = serde_json::from_slice(&output_v.stdout).unwrap();
    assert_eq!(value_v["agents"], serde_json::json!(["claude", "codex", "antigravity_cli", "pi", "cursor"]));
}

#[test]
fn version_flag_rejects_extra_arguments() {
    let output = Command::new(env!("CARGO_BIN_EXE_herdcats-bridge"))
        .args(["--version-json", "serve"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
}

#[test]
fn version_json_bytes_match_released_installer_contract() {
    let expected = format!(
        "{{\"agents\":[\"claude\",\"codex\",\"antigravity_cli\",\"pi\",\"cursor\"],\"herdr_protocol\":22,\"name\":\"herdcats-bridge\",\"protocol\":1,\"version\":\"{}\"}}\n",
        env!("CARGO_PKG_VERSION")
    );
    for flag in ["--version-json", "--version"] {
        let output = Command::new(env!("CARGO_BIN_EXE_herdcats-bridge"))
            .arg(flag)
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(output.stderr.is_empty());
        assert_eq!(String::from_utf8(output.stdout).unwrap(), expected);
    }
}

fn pi_extension(args: &[&str], agent_dir_env: Option<&std::path::Path>, home: &std::path::Path) -> Value {
    let mut command = Command::new(env!("CARGO_BIN_EXE_herdcats-bridge"));
    command.arg("pi-extension").args(args).env("HOME", home).env_remove("PI_CODING_AGENT_DIR");
    if let Some(dir) = agent_dir_env {
        command.env("PI_CODING_AGENT_DIR", dir);
    }
    let output = command.output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    serde_json::from_slice(&output.stdout).unwrap()
}

fn temp_home(name: &str) -> std::path::PathBuf {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let path = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("herdcats-cli-pi-{name}-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn pi_extension_status_and_install_use_the_default_agent_dir() {
    let home = temp_home("default");
    let agent = home.join(".pi/agent");
    std::fs::create_dir_all(&agent).unwrap();
    let dir = agent.join("extensions/herdcats");
    let dir = dir.to_str().unwrap();
    assert_eq!(pi_extension(&["status"], None, &home), serde_json::json!({"status":"missing","dir":dir}));
    assert_eq!(pi_extension(&["install"], None, &home), serde_json::json!({"status":"current","dir":dir}));
    assert_eq!(pi_extension(&["status"], None, &home), serde_json::json!({"status":"current","dir":dir}));
    std::fs::write(agent.join("extensions/herdcats/index.ts"), "// edited\n").unwrap();
    assert_eq!(pi_extension(&["install"], None, &home), serde_json::json!({"error":"pi_extension_modified","dir":dir}));
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn pi_extension_honors_pi_agent_dir_overrides() {
    let home = temp_home("override");
    let env_dir = home.join("env-agent");
    let flag_dir = home.join("flag-agent");
    std::fs::create_dir_all(&env_dir).unwrap();
    std::fs::create_dir_all(&flag_dir).unwrap();
    assert_eq!(pi_extension(&["install"], Some(&env_dir), &home)["status"], "current");
    assert!(env_dir.join("extensions/herdcats/index.ts").is_file());
    let flag = flag_dir.to_str().unwrap();
    assert_eq!(pi_extension(&["status", "--pi-agent-dir", flag], Some(&env_dir), &home)["status"], "missing");
    // No ~/.pi/agent: Pi has not been set up for this account.
    assert_eq!(pi_extension(&["status"], None, &home)["error"], "pi_agent_dir_unavailable");
    assert_eq!(pi_extension(&["remove"], None, &home)["error"], "unknown_argument");
    assert_eq!(pi_extension(&["status", "--pi-agent-dir"], None, &home)["error"], "unknown_argument");
    let _ = std::fs::remove_dir_all(home);
}
