//! Resolve cache locations without trusting a predictable shared temporary directory.
use qrk_core::{Error, Result};
use std::path::PathBuf;

/// Returns the platform's per-user data directory, or a validated private fallback.
/// An unsafe fallback is an error; callers must not silently substitute another path.
pub fn cache_directory() -> Result<PathBuf> {
    if let Some(project) =
        directories::ProjectDirs::from("org", "QuranRecitationKit", "QuranRecitationKit")
    {
        return Ok(project.data_local_dir().to_owned());
    }
    fallback_directory()
}

#[cfg(unix)]
fn fallback_directory() -> Result<PathBuf> {
    // geteuid has no pointer arguments or failure mode. File access uses this identity.
    let uid = unsafe { libc::geteuid() };
    private_fallback(&std::env::temp_dir(), uid)
}

#[cfg(not(unix))]
fn fallback_directory() -> Result<PathBuf> {
    Err(Error::Model(
        "cannot resolve a private per-user cache directory".into(),
    ))
}

#[cfg(unix)]
fn private_fallback(parent: &std::path::Path, uid: u32) -> Result<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;
    let directory = parent.join(format!("QuranRecitationKit-{uid}"));
    match std::fs::DirBuilder::new().mode(0o700).create(&directory) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(Error::Model(format!("cannot create private cache: {e}"))),
    }
    validate_fallback(&directory, uid)?;
    Ok(directory)
}

#[cfg(unix)]
fn validate_fallback(directory: &std::path::Path, uid: u32) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    // lstat rather than stat: a pre-created symlink must never redirect cache access.
    let metadata = std::fs::symlink_metadata(directory)
        .map_err(|e| Error::Model(format!("cannot inspect private cache: {e}")))?;
    if !metadata.is_dir() || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
        return Err(Error::Model(
            "refusing unsafe cache: expected a private directory owned by the current user".into(),
        ));
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};

    #[test]
    fn fallback_is_per_user_and_created_private() {
        let temp = tempfile::tempdir().unwrap();
        let uid = unsafe { libc::geteuid() };
        let path = private_fallback(temp.path(), uid).unwrap();
        assert_eq!(
            path.file_name().unwrap(),
            format!("QuranRecitationKit-{uid}").as_str()
        );
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o777, 0o700);
        assert_eq!(private_fallback(temp.path(), uid).unwrap(), path);
    }

    #[test]
    fn fallback_refuses_wrong_owner_or_shared_permissions() {
        let temp = tempfile::tempdir().unwrap();
        let uid = unsafe { libc::geteuid() };
        let path = private_fallback(temp.path(), uid).unwrap();
        // Exercise the ownership check without requiring root/chown in CI.
        assert!(validate_fallback(&path, uid.wrapping_add(1)).is_err());
        for mode in [0o777, 0o770, 0o702, 0o755] {
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
            assert!(private_fallback(temp.path(), uid).is_err());
        }
    }

    #[test]
    fn fallback_refuses_preexisting_file_and_symlink() {
        let temp = tempfile::tempdir().unwrap();
        let uid = unsafe { libc::geteuid() };
        let path = temp.path().join(format!("QuranRecitationKit-{uid}"));
        std::fs::write(&path, b"not a directory").unwrap();
        assert!(private_fallback(temp.path(), uid).is_err());
        std::fs::remove_file(&path).unwrap();
        let other = tempfile::tempdir().unwrap();
        symlink(other.path(), &path).unwrap();
        assert!(private_fallback(temp.path(), uid).is_err());
    }
}
