//! Install the Herdcats Pi extension bundled in this bridge binary.
//! Only files matching a known Herdcats release are ever replaced.
use std::{
    fs,
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

pub const INDEX: &[u8] = include_bytes!("../pi-extension/index.ts");
pub const RUNTIME: &[u8] = include_bytes!("../pi-extension/runtime.mjs");
/// SHA-256 of every committed version of each file, oldest first. Add the new
/// hash whenever a file changes; never remove one (hosts may still run it).
const INDEX_HASHES: &[&str] = &[
    // 4f1bd95 pre-release and 0.5.0 (returned early unless Pi was 1.4.0).
    "648606a2797d22984d1f962f90dead01df4919aeed5d1268d529a0a63c18586d",
    // 0.5.1: public API contract check instead of a Pi version gate.
    "58db9fb35a0847c68e13e38bd6d5d2e94880a3192d21a1bb3871346b2950cf85",
];
const RUNTIME_HASHES: &[&str] = &[
    "fccdd4a506bf53922a0d9c56568283e68ab1435c8bd2ef2c15f68a89265e16c2", // 4f1bd95 pre-release
    "86d55d475b23ae9e196c4e0b45b3767ca3bd562b5da5e65b0187b40838d5f064", // 0.5.0
    "4f3c226482533de9559bb9e25de1c07ce729a9e932ef162f5110fcc46fd8fd9e", // 0.5.1
];
const BUNDLE: [(&str, &[u8], &[&str]); 2] =
    [("index.ts", INDEX, INDEX_HASHES), ("runtime.mjs", RUNTIME, RUNTIME_HASHES)];
/// Larger files are never one of ours.
const MAX_FILE: u64 = 1024 * 1024;

pub fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for block in message.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, word) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (state, value) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *state = state.wrapping_add(value);
        }
    }
    let mut out = [0u8; 32];
    for (chunk, word) in out.chunks_exact_mut(4).zip(h) {
        chunk.copy_from_slice(&word.to_be_bytes());
    }
    out
}

fn hex(bytes: [u8; 32]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// No Herdcats files are installed.
    Missing,
    /// Every installed file is an earlier Herdcats release (or one is absent).
    Outdated,
    /// Both files match this bridge's bundle.
    Current,
    /// A file matches no Herdcats release; it is never replaced.
    Modified,
}
impl Status {
    pub fn name(self) -> &'static str {
        match self {
            Self::Missing => "missing",
            Self::Outdated => "outdated",
            Self::Current => "current",
            Self::Modified => "modified",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FileState {
    Absent,
    Current,
    Known,
    Unknown,
}

/// `<agent dir>/extensions/herdcats`, the directory Pi auto-discovers.
pub fn extension_dir(agent_dir: &Path) -> PathBuf {
    agent_dir.join("extensions").join("herdcats")
}

/// Whether a directory exists, refusing symlinks and non-directories.
fn existing_dir(path: &Path) -> crate::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_dir() => Ok(true),
        Ok(_) => Err("pi_extension_unsafe_path"),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err("pi_extension_unavailable"),
    }
}

fn file_state(dir: &Path, name: &str, known: &[&str], bundled: &[u8]) -> crate::Result<FileState> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(dir.join(name));
    let mut file = match file {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(FileState::Absent),
        Err(e) if e.raw_os_error() == Some(libc::ELOOP) => return Err("pi_extension_unsafe_path"),
        Err(_) => return Err("pi_extension_unavailable"),
    };
    if !file.metadata().map_err(|_| "pi_extension_unavailable")?.is_file() {
        return Err("pi_extension_unsafe_path");
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_FILE + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "pi_extension_unavailable")?;
    if bytes == bundled {
        return Ok(FileState::Current);
    }
    if bytes.len() as u64 <= MAX_FILE && known.contains(&hex(sha256(&bytes)).as_str()) {
        return Ok(FileState::Known);
    }
    Ok(FileState::Unknown)
}

fn file_states(agent_dir: &Path) -> crate::Result<[FileState; 2]> {
    if !agent_dir.is_absolute() || !fs::metadata(agent_dir).is_ok_and(|m| m.is_dir()) {
        return Err("pi_agent_dir_unavailable");
    }
    let dir = extension_dir(agent_dir);
    if !existing_dir(&agent_dir.join("extensions"))? || !existing_dir(&dir)? {
        return Ok([FileState::Absent; 2]);
    }
    let mut states = [FileState::Absent; 2];
    for (state, (name, bytes, known)) in states.iter_mut().zip(BUNDLE) {
        *state = file_state(&dir, name, known, bytes)?;
    }
    Ok(states)
}

fn summarize(states: [FileState; 2]) -> Status {
    if states.contains(&FileState::Unknown) {
        Status::Modified
    } else if states == [FileState::Current; 2] {
        Status::Current
    } else if states == [FileState::Absent; 2] {
        Status::Missing
    } else {
        Status::Outdated
    }
}

pub fn status_in(agent_dir: &Path) -> crate::Result<Status> {
    file_states(agent_dir).map(summarize)
}

/// Install or update the bundled extension. Only the two Herdcats files are
/// written, each through a temporary file and a rename; edited files are refused.
pub fn install_in(agent_dir: &Path) -> crate::Result<Status> {
    let states = file_states(agent_dir)?;
    match summarize(states) {
        Status::Modified => return Err("pi_extension_modified"),
        Status::Current => return Ok(Status::Current),
        Status::Missing | Status::Outdated => {}
    }
    let dir = extension_dir(agent_dir);
    for path in [agent_dir.join("extensions"), dir.clone()] {
        if !existing_dir(&path)? {
            match fs::DirBuilder::new().mode(0o755).create(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                Err(_) => return Err("pi_extension_write_failed"),
            }
            if !existing_dir(&path)? {
                return Err("pi_extension_write_failed");
            }
        }
    }
    for (state, (name, bytes, known)) in states.into_iter().zip(BUNDLE) {
        if state != FileState::Current {
            write_file(&dir, name, bytes, known)?;
        }
    }
    match status_in(agent_dir)? {
        Status::Current => Ok(Status::Current),
        _ => Err("pi_extension_verification_failed"),
    }
}

fn write_file(dir: &Path, name: &str, bytes: &[u8], known: &[&str]) -> crate::Result<()> {
    let mut count = 0;
    let (temp, mut file) = loop {
        let temp = dir.join(format!(".{name}.tmp.herdcats-{}-{count}", std::process::id()));
        let opened = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o644)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temp);
        match opened {
            Ok(file) => break (temp, file),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists && count < 100 => count += 1,
            Err(_) => return Err("pi_extension_write_failed"),
        }
    };
    let written = file
        .set_permissions(fs::Permissions::from_mode(0o644))
        .and_then(|()| file.write_all(bytes))
        .and_then(|()| file.sync_all());
    drop(file);
    // Recheck right before replacing: a file edited or swapped for a symlink
    // since the first check is left as it is.
    let result = written
        .map_err(|_| "pi_extension_write_failed")
        .and_then(|()| match file_state(dir, name, known, bytes)? {
            FileState::Unknown => Err("pi_extension_modified"),
            _ => fs::rename(&temp, dir.join(name)).map_err(|_| "pi_extension_write_failed"),
        });
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};

    struct TempDir(PathBuf);
    impl TempDir {
        fn new(name: &str) -> Self {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("herdcats-pi-ext-{name}-{}-{nanos}", std::process::id()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn ext(&self) -> PathBuf {
            self.0.join("extensions/herdcats")
        }
        fn put(&self, name: &str, bytes: &[u8]) {
            fs::create_dir_all(self.ext()).unwrap();
            fs::write(self.ext().join(name), bytes).unwrap();
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    // The 0.5.0 release copy (still gated on Pi 1.4.0); first index.ts line.
    const OLD_INDEX_HASH: &str = "648606a2797d22984d1f962f90dead01df4919aeed5d1268d529a0a63c18586d";

    #[test]
    fn sha256_matches_nist_vectors() {
        assert_eq!(hex(sha256(b"")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(hex(sha256(b"abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(
            hex(sha256(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        assert_eq!(
            hex(sha256(&vec![b'a'; 1_000_000])),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }

    #[test]
    fn bundled_files_are_recorded_as_known_releases() {
        // Editing the extension requires adding its new hash, which also keeps
        // every earlier hash replaceable on hosts that still run it.
        for (name, bytes, known) in BUNDLE {
            assert!(known.contains(&hex(sha256(bytes)).as_str()), "{name}: add its sha256 to the known list");
        }
        assert!(INDEX_HASHES.contains(&OLD_INDEX_HASH));
    }

    #[test]
    fn empty_agent_dir_is_missing() {
        let dir = TempDir::new("missing");
        assert_eq!(status_in(&dir.0), Ok(Status::Missing));
        fs::create_dir_all(dir.ext()).unwrap();
        assert_eq!(status_in(&dir.0), Ok(Status::Missing));
    }

    #[test]
    fn absent_agent_dir_is_an_error() {
        let dir = TempDir::new("absent");
        assert_eq!(status_in(&dir.0.join("nope")), Err("pi_agent_dir_unavailable"));
        assert_eq!(install_in(&dir.0.join("nope")), Err("pi_agent_dir_unavailable"));
        assert_eq!(status_in(Path::new("relative/agent")), Err("pi_agent_dir_unavailable"));
    }

    #[test]
    fn install_writes_bundle_and_reports_current() {
        let dir = TempDir::new("install");
        assert_eq!(install_in(&dir.0), Ok(Status::Current));
        for (name, bytes, _) in BUNDLE {
            let path = dir.ext().join(name);
            assert_eq!(fs::read(&path).unwrap(), bytes);
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o644);
        }
        assert_eq!(status_in(&dir.0), Ok(Status::Current));
        // Installing again is a no-op.
        assert_eq!(install_in(&dir.0), Ok(Status::Current));
    }

    #[test]
    fn partial_install_is_outdated_and_completed() {
        let dir = TempDir::new("partial");
        dir.put("runtime.mjs", RUNTIME);
        assert_eq!(status_in(&dir.0), Ok(Status::Outdated));
        assert_eq!(install_in(&dir.0), Ok(Status::Current));
    }

    #[test]
    fn real_old_release_is_outdated() {
        let dir = TempDir::new("real-old");
        let Ok(old) = std::process::Command::new("git")
            .args(["show", "herdcats-bridge-v0.5.0:bridge/pi-extension/index.ts"])
            .output()
        else {
            return;
        };
        if !old.status.success() {
            return; // Not a git checkout with release tags.
        }
        assert_eq!(hex(sha256(&old.stdout)), OLD_INDEX_HASH);
        dir.put("index.ts", &old.stdout);
        dir.put("runtime.mjs", RUNTIME);
        assert_eq!(status_in(&dir.0), Ok(Status::Outdated));
        assert_eq!(install_in(&dir.0), Ok(Status::Current));
        assert_eq!(fs::read(dir.ext().join("index.ts")).unwrap(), INDEX);
    }

    #[test]
    fn edited_files_are_refused_and_left_alone() {
        let dir = TempDir::new("edited");
        dir.put("index.ts", INDEX);
        dir.put("runtime.mjs", b"// my local tweak\n");
        assert_eq!(status_in(&dir.0), Ok(Status::Modified));
        assert_eq!(install_in(&dir.0), Err("pi_extension_modified"));
        assert_eq!(fs::read(dir.ext().join("runtime.mjs")).unwrap(), b"// my local tweak\n");
    }

    #[test]
    fn other_files_are_untouched() {
        let dir = TempDir::new("others");
        dir.put("notes.md", b"mine");
        fs::write(dir.0.join("extensions/other.ts"), b"other").unwrap();
        assert_eq!(install_in(&dir.0), Ok(Status::Current));
        assert_eq!(fs::read(dir.ext().join("notes.md")).unwrap(), b"mine");
        assert_eq!(fs::read(dir.0.join("extensions/other.ts")).unwrap(), b"other");
        let leftovers: Vec<_> = fs::read_dir(dir.ext())
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .filter(|n| n.starts_with('.'))
            .collect();
        assert!(leftovers.is_empty(), "temp files left: {leftovers:?}");
    }

    #[test]
    fn symlinks_are_refused() {
        let dir = TempDir::new("symlink");
        let target = TempDir::new("symlink-target");
        fs::create_dir_all(dir.0.join("extensions")).unwrap();
        std::os::unix::fs::symlink(&target.0, dir.ext()).unwrap();
        assert_eq!(status_in(&dir.0), Err("pi_extension_unsafe_path"));
        assert_eq!(install_in(&dir.0), Err("pi_extension_unsafe_path"));
        assert!(fs::read_dir(&target.0).unwrap().next().is_none());

        let dir = TempDir::new("symlink-file");
        fs::create_dir_all(dir.ext()).unwrap();
        fs::write(target.0.join("x"), INDEX).unwrap();
        std::os::unix::fs::symlink(target.0.join("x"), dir.ext().join("index.ts")).unwrap();
        assert_eq!(status_in(&dir.0), Err("pi_extension_unsafe_path"));
        assert_eq!(install_in(&dir.0), Err("pi_extension_unsafe_path"));
    }
}
