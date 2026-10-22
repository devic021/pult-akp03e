//! Which application is in front.
//!
//! This goes through `lsappinfo` rather than `NSWorkspace.frontmostApplication`
//! on purpose: that property goes stale in a background process, which is the
//! known cause of app-based profile switching failing on macOS (OpenDeck #455,
//! active-win-pos-rs #49). `lsappinfo` asks the launch services daemon, so it
//! stays correct from the background and needs no permissions at all.

use std::process::Command;

/// Bundle ID of the frontmost app, or `None` when macOS reports none
/// (which happens briefly during app switches and at the login window).
pub fn bundle_id() -> Option<String> {
    let front = run(&["front"])?;
    let asn = front.split_whitespace().find(|t| t.starts_with("ASN:"))?;
    let info = run(&["info", "-only", "bundleid", asn])?;
    parse_bundle_id(&info)
}

fn run(args: &[&str]) -> Option<String> {
    let output = Command::new("/usr/bin/lsappinfo").args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Pulls the ID out of `    bundleID="com.apple.Safari"`.
fn parse_bundle_id(output: &str) -> Option<String> {
    let line = output.lines().find(|l| l.trim_start().starts_with("bundleID"))?;
    let value = line.split('=').nth(1)?.trim().trim_matches('"');
    if value.is_empty() || value == "[ NULL ]" {
        return None;
    }
    Some(value.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_bundle_id_from_lsappinfo_output() {
        let output = "[ NULL ]  ASN:0x0-0x5b64b5f: (in front) \n    \
                      bundleID=\"com.google.Chrome\"\n    bundle path=[ NULL ] \n";
        assert_eq!(parse_bundle_id(output).as_deref(), Some("com.google.Chrome"));
    }

    #[test]
    fn missing_bundle_id_is_none() {
        assert_eq!(parse_bundle_id("    bundleID=[ NULL ]"), None);
        assert_eq!(parse_bundle_id("nothing here"), None);
    }
}
