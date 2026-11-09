use super::*;
use std::{
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
};
fn root() -> Result<PathBuf, String> {
    let uid = unsafe { libc::getuid() };
    let path = std::env::temp_dir().join(format!("favenio-quick-handoff-{uid}"));
    match std::fs::DirBuilder::new().mode(0o700).create(&path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.to_string()),
    };
    let info = std::fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
    if !info.is_dir() || info.uid() != uid || info.mode() & 0o077 != 0 {
        return Err("Unsicherer Übergabeordner.".into());
    }
    Ok(path)
}
pub(super) fn write(configuration: Value) -> Result<PathBuf, String> {
    let path = root()?.join(format!("{}.json", glib::uuid_string_random()));
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs_f64();
    let data = serde_json::to_vec(
        &json!({"schemaVersion":1,"expiresAt":now+60.0,"configuration":configuration}),
    )
    .map_err(|e| e.to_string())?;
    if data.len() > 1_048_576 {
        return Err("Übergabe überschreitet 1 MiB.".into());
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .map_err(|e| e.to_string())?;
    file.write_all(&data).map_err(|e| e.to_string())?;
    Ok(path)
}
pub(super) fn read(path: &std::path::Path) -> Result<Value, String> {
    if path.parent() != Some(root()?.as_path())
        || path.extension().and_then(|s| s.to_str()) != Some("json")
    {
        return Err("Unbekannte Übergabedatei.".into());
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|e| e.to_string())?;
    let info = file.metadata().map_err(|e| e.to_string())?;
    if !info.is_file()
        || info.uid() != unsafe { libc::getuid() }
        || info.mode() & 0o077 != 0
        || info.len() > 1_048_576
    {
        return Err("Unsichere oder zu große Übergabe.".into());
    }
    let mut bytes = Vec::new();
    file.take(1_048_577)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(path);
    let value: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    if value["schemaVersion"] != 1
        || value["expiresAt"]
            .as_f64()
            .is_none_or(|time| time < now || time > now + 61.0)
    {
        return Err("Übergabe ist abgelaufen.".into());
    }
    Ok(value["configuration"].clone())
}
