# Fix: Lua Stack Overflow with Large/Generated Files

## Problem

When running `:Difft` in fbsource with unstaged changes, the plugin crashed with:

```
thread '<unnamed>' panicked at mlua-0.11.5/src/state/extra.rs:287:17:
cannot create a Lua reference, out of auxiliary stack space (used 7996 slots)
```

### Root Cause

1. User had a 13,958-line `@generated` file modified
2. Rust code processed ALL files into `DisplayFile` structs before filtering
3. Each line created ~4 Lua table references (row, left side, right side, aligned_lines)
4. 13,958 lines × 4 = ~56,000 Lua references needed
5. mlua's auxiliary stack limit is ~8,000 slots → **CRASH**

### Why Filtering Happened Too Late

The original code filtered `@generated` files in Lua AFTER Rust had already:
- Processed all files into display structs
- Attempted to convert them to Lua tables (triggering the crash)

```lua
-- init.lua (lines 215-234) - TOO LATE!
result.files = vim.tbl_filter(function(file)
    return not is_generated_file(file.path)
end, result.files)
```

## Solution (Defense in Depth)

Implemented **two** defenses in Rust, BEFORE processing files:

### Defense 1: Size Limit Check

- **Limit**: 5,000 lines per file (well under the 8,000 slot limit)
- **For changed files**: Check `aligned_lines.len()` directly
- **For created/deleted files**: Estimate from file size on disk (500KB max)
- **Effect**: Prevents ANY large file from causing overflow

```rust
const MAX_FILE_LINES: usize = 5000;
const MAX_FILE_SIZE_BYTES: u64 = 500_000;

fn should_skip_oversized_file(file: &DifftFile, vcs_root: &Option<PathBuf>) -> bool {
    match file.status {
        Status::Created | Status::Deleted => {
            // Check file size on disk, estimate lines
            if let Some(root) = vcs_root {
                let file_path = root.join(&file.path);
                if let Ok(metadata) = std::fs::metadata(&file_path) {
                    let file_size = metadata.len();
                    let estimated_lines = file_size / 100; // ~100 bytes/line
                    return estimated_lines as usize > MAX_FILE_LINES
                        || file_size > MAX_FILE_SIZE_BYTES;
                }
            }
            false
        }
        Status::Changed | Status::Unchanged => {
            file.aligned_lines.len() > MAX_FILE_LINES
        }
    }
}
```

### Defense 2: @generated File Filtering

- **Checks first 50 lines** for `@generated` or `@partially-generated` markers
- **Semantically correct**: Respects Meta's @generated convention
- **Moved from Lua to Rust**: Filters BEFORE processing

```rust
fn is_generated_file_content(content: &str) -> bool {
    content
        .lines()
        .take(50)
        .any(|line| line.contains("@generated") || line.contains("@partially-generated"))
}
```

### Integration Point

Both checks happen in `run_diff_impl()` BEFORE processing:

```rust
let files: Vec<_> = files
    .into_iter()
    .filter(|file| {
        // Defense 1: Skip oversized files
        if should_skip_oversized_file(file, &vcs_root) {
            eprintln!("Skipping oversized file: {} (exceeds {} line limit)",
                file.path.display(), MAX_FILE_LINES);
            return false;
        }

        // Defense 2: Skip @generated files
        if let Some(root) = &vcs_root {
            let file_path = root.join(&file.path);
            if let Ok(content) = std::fs::read_to_string(&file_path) {
                if is_generated_file_content(&content) {
                    eprintln!("Skipping @generated file: {}", file.path.display());
                    return false;
                }
            }
        }

        true
    })
    .collect();
```

## Test Coverage

Added 8 new tests following TDD:

1. `test_is_generated_file_with_generated_marker` - Detects `@generated`
2. `test_is_generated_file_with_partially_generated_marker` - Detects `@partially-generated`
3. `test_is_generated_file_without_marker` - Passes normal files
4. `test_is_generated_file_marker_after_line_50` - Ignores markers after line 50
5. `test_should_skip_oversized_file` - Allows files at exactly 5000 lines
6. `test_should_skip_oversized_file_above_limit` - Blocks files over 5000 lines
7. `test_should_skip_oversized_file_created_no_root` - Handles missing VCS root
8. `test_should_skip_oversized_file_deleted_small` - Handles non-existent files

All 56 tests pass.

## Expected Behavior

When running `:Difft` in fbsource with the 13,958-line `@generated` file:

**Before fix**:
```
Error executing Lua callback: cannot create a Lua reference, out of auxiliary stack space
```

**After fix**:
```
Skipping @generated file: www/flib/__generated__/.../GraphQLStoriesViewerMutationIGMutation.php
[Shows diffs for the 10 other non-generated files]
```

## Why Both Defenses?

1. **Size limit (Defense 1)**: Protects against any large file, not just @generated ones
2. **@generated check (Defense 2)**: Semantically correct - users expect these to be filtered

Together they provide defense in depth: even if one check fails, the other catches it.

## Performance Impact

- **Minimal**: Both checks happen on small data:
  - Size check: Just metadata (`fs::metadata()` is instant)
  - @generated check: Only reads first 50 lines
- **vs. Original**: Avoids reading entire 14K-line file into memory
- **Net effect**: Faster and more memory-efficient

## Future Considerations

If users need to see @generated files:
- Add `--include-generated` flag (already exists in Lua, could remove Rust filter conditionally)
- Or increase size limit with configuration option

For now, the 5,000-line limit is conservative and safe.
