//! Sapling VCS support for difftastic.nvim
//!
//! This module provides Sapling-specific implementations for VCS operations.
//! Sapling uses the extdiff extension with `sl difft` command.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::difftastic;
use crate::DiffMode;

type FileStats = HashMap<PathBuf, (u32, u32)>;

/// Fetches file content from sapling at a specific revision via `sl cat`.
/// Returns `None` if the command fails or the file doesn't exist.
pub fn sl_file_content(revset: &str, path: &Path) -> Option<String> {
    Command::new("sl")
        .args(["cat", "-r", revset])
        .arg(path)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Gets the sapling repository root directory.
pub fn sl_root() -> Option<PathBuf> {
    Command::new("sl")
        .args(["root"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()))
}

/// Gets diff stats for sapling uncommitted changes.
pub fn sl_diff_stats_uncommitted() -> FileStats {
    let output = Command::new("sl")
        .args(["diff", "--stat"])
        .output()
        .ok();

    let Some(output) = output.filter(|o| o.status.code().unwrap_or(127) <= 1) else {
        return HashMap::new();
    };

    parse_sl_stat_output(&String::from_utf8_lossy(&output.stdout))
}

/// Gets diff stats from sapling using `sl diff --stat`.
/// If `file_filter` is non-empty, only stats those specific files.
pub fn sl_diff_stats_with_filter(revset: &str, file_filter: &[String]) -> FileStats {
    let mut cmd = Command::new("sl");
    if let Some((old, new)) = crate::parse_jj_range(revset) {
        cmd.args(["diff", "--stat", "-r", &old, "-r", &new]);
    } else {
        cmd.args(["diff", "--stat", "-c", revset]);
    }
    if !file_filter.is_empty() {
        cmd.arg("--");
        cmd.args(file_filter);
    }

    let output = cmd.output().ok();
    let Some(output) = output.filter(|o| o.status.code().unwrap_or(127) <= 1) else {
        return HashMap::new();
    };

    parse_sl_stat_output(&String::from_utf8_lossy(&output.stdout))
}

/// Gets diff stats from sapling using `sl diff --stat`.
pub fn sl_diff_stats(revset: &str) -> FileStats {
    sl_diff_stats_with_filter(revset, &[])
}

/// Parses `sl diff --stat` output into file stats.
/// Format: " path/to/file.txt |  141 ++++++++++++++++"
/// Note: The number represents total changes; we approximate add/delete split from visual bar.
fn parse_sl_stat_output(output: &str) -> FileStats {
    output
        .lines()
        .filter_map(|line| {
            // Skip summary line at the end
            if line.contains("files changed") || line.trim().is_empty() {
                return None;
            }

            // Split on "|" to separate path from stats
            let (path_part, stats_part) = line.split_once('|')?;
            let path = path_part.trim();

            // Parse the number (total changes)
            let num_str = stats_part.trim().split_whitespace().next()?;
            let count = num_str.parse::<u32>().ok()?;

            // For simplicity: if only + symbols, it's additions; if only -, it's deletions
            // Mixed files show the total as additions (approximation)
            let has_plus = stats_part.contains('+');
            let has_minus = stats_part.contains('-');

            let (additions, deletions) = match (has_plus, has_minus) {
                (true, false) => (count, 0),
                (false, true) => (0, count),
                (true, true) => (count, 0), // Approximate: show as additions
                (false, false) => (count, 0),
            };

            Some((PathBuf::from(path), (additions, deletions)))
        })
        .collect()
}

/// Runs difftastic via sapling and parses the JSON output.
/// Executes `sl difft -c <revset>` to show changes made by the revision.
pub fn run_sl_diff(revset: &str) -> Result<Vec<difftastic::DifftFile>, String> {
    let output = Command::new("sl")
        .args(["difft", "-c", revset])
        .env("DFT_DISPLAY", "json")
        .env("DFT_UNSTABLE", "yes")
        .output()
        .map_err(|e| format!("Failed to run sl: {e}"))?;

    // sl difft returns exit code 1 when there are differences (standard diff behavior)
    // Only codes > 1 indicate errors
    let exit_code = output.status.code().unwrap_or(127);
    if exit_code > 1 {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("sl command failed: {stderr}"));
    }

    difftastic::parse(&String::from_utf8_lossy(&output.stdout))
        .map_err(|e| format!("Failed to parse difftastic JSON: {e}"))
}

/// Runs difftastic via sapling for a range (two revisions).
/// Executes `sl difft -r <old> -r <new>` to compare two revisions.
/// If `file_filter` is non-empty, only diffs those specific files.
pub fn run_sl_diff_range(
    old_rev: &str,
    new_rev: &str,
    file_filter: &[String],
) -> Result<Vec<difftastic::DifftFile>, String> {
    let mut cmd = Command::new("sl");
    cmd.args(["difft", "-r", old_rev, "-r", new_rev]);
    if !file_filter.is_empty() {
        cmd.arg("--");
        cmd.args(file_filter);
    }
    cmd.env("DFT_DISPLAY", "json")
        .env("DFT_UNSTABLE", "yes");

    let output = cmd.output().map_err(|e| format!("Failed to run sl: {e}"))?;

    // sl difft returns exit code 1 when there are differences (standard diff behavior)
    // Only codes > 1 indicate errors
    let exit_code = output.status.code().unwrap_or(127);
    if exit_code > 1 {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("sl command failed: {stderr}"));
    }

    difftastic::parse(&String::from_utf8_lossy(&output.stdout))
        .map_err(|e| format!("Failed to parse difftastic JSON: {e}"))
}

/// Runs difftastic via sapling for uncommitted changes (working copy).
/// Executes `sl difft` with no revision argument.
pub fn run_sl_diff_uncommitted() -> Result<Vec<difftastic::DifftFile>, String> {
    let output = Command::new("sl")
        .args(["difft"])
        .env("DFT_DISPLAY", "json")
        .env("DFT_UNSTABLE", "yes")
        .output()
        .map_err(|e| format!("Failed to run sl: {e}"))?;

    // sl difft returns exit code 1 when there are differences (standard diff behavior)
    // Only codes > 1 indicate errors
    let exit_code = output.status.code().unwrap_or(127);
    if exit_code > 1 {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("sl command failed: {stderr}"));
    }

    difftastic::parse(&String::from_utf8_lossy(&output.stdout))
        .map_err(|e| format!("Failed to parse difftastic JSON: {e}"))
}

pub fn sl_rename_map(mode: &DiffMode) -> HashMap<PathBuf, PathBuf> {
    let mut cmd = Command::new("sl");
    cmd.arg("status");
    cmd.arg("-C"); // Show source of copied files

    match mode {
        DiffMode::Range(revset) => {
            cmd.arg("--change").arg(revset);
        }
        DiffMode::Unstaged => {}
        DiffMode::Staged => {
            cmd.arg("--change").arg("."); // sl uses "." for current commit
        }
    }

    let output = cmd.output().ok();
    let Some(output) = output.filter(|o| o.status.success()) else {
        return HashMap::new();
    };

    parse_sl_status_renames(&String::from_utf8_lossy(&output.stdout))
}

/// Parses `sl status -C` output to extract rename mappings.
/// Format: Lines with status "A" followed by a line with two spaces and the source path.
fn parse_sl_status_renames(output: &str) -> HashMap<PathBuf, PathBuf> {
    let mut renames = HashMap::new();
    let mut lines = output.lines().peekable();

    while let Some(line) = lines.next() {
        // Check for "A" (added) status which might be a rename
        if let Some(new_path) = line.trim().strip_prefix("A ") {
            // Check if next line shows the copy source (starts with two spaces)
            if let Some(next_line) = lines.peek() {
                if let Some(old_path) = next_line.trim_start().strip_prefix("  ") {
                    renames.insert(PathBuf::from(new_path), PathBuf::from(old_path.trim()));
                    lines.next(); // Consume the source line
                }
            }
        }
    }

    renames
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_sl_stat_new_file() {
        let output = " vcs_sl.lua |  141 +++++++++++++++++++++\n 1 file changed, 141 insertions(+)";
        let stats = parse_sl_stat_output(output);
        assert_eq!(stats.get(Path::new("vcs_sl.lua")), Some(&(141, 0)));
    }

    #[test]
    fn test_parse_sl_stat_modified_file() {
        let output = " README.md |   26 +++-\n 1 file changed, 23 insertions(+), 3 deletions(-)";
        let stats = parse_sl_stat_output(output);
        // Mixed files are approximated as additions
        assert_eq!(stats.get(Path::new("README.md")), Some(&(26, 0)));
    }

    #[test]
    fn test_parse_sl_stat_deletions_only() {
        let output = " file.txt |   10 ----------\n 1 file changed, 10 deletions(-)";
        let stats = parse_sl_stat_output(output);
        assert_eq!(stats.get(Path::new("file.txt")), Some(&(0, 10)));
    }
}
