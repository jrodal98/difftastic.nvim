# Sapling VCS Support - Fork Architecture

This fork adds Sapling VCS support to difftastic.nvim. The implementation is
designed to **minimize merge conflicts** with upstream changes.

## Architecture

All Sapling-specific code is isolated in separate module files:

### Rust Module: `src/vcs_sl.rs`
Contains ALL Sapling VCS operations:
- `sl_file_content()` - Fetch file content at revision
- `sl_root()` - Get repository root
- `sl_diff_stats()` - Parse diff stats
- `run_sl_diff()` - Execute difft for single commits (-c flag)
- `run_sl_diff_range()` - Execute difft for ranges (dual -r flags)
- `run_sl_diff_uncommitted()` - Execute difft for working copy
- `sl_rename_map()` - Detect file renames via sl status -C

### Lua Module: `lua/difftastic-nvim/vcs_sl.lua`
Contains ALL Sapling picker operations:
- `items()` - Format commit list for picker
- `preview()` - Generate commit detail preview
- `effective_revset()` - Combine filter revsets
- `title()` - Generate picker titles
- `range_ancestor_filter()` - Filter commits for range picking

## Minimal Upstream Touch Points

The fork modifies upstream files in only **8 isolated locations**:

### `src/lib.rs` (4 changes)
1. Line ~47: `mod vcs_sl;` - Single line import
2. Line ~669: `"sl" => vcs_sl::sl_root()` - One match arm
3. Lines ~687-843: Three `"sl"` match arms in dispatch (clearly marked)
4. Line ~843: One `else if vcs == "sl"` in rename dispatch

### `lua/difftastic-nvim/picker.lua` (4 changes)  
1. Line ~391: Require vcs_sl module and call `.items()`
2. Line ~421: Require vcs_sl module for preview
3. Line ~493: Call vcs_sl.title()
4. Lines ~524-530: Call vcs_sl functions for range picking

## Merging Upstream Changes

### Low-Conflict Areas (No Action Needed)
- Changes to git/jj functions → Zero conflicts
- New features in tree, diff, highlight, binary modules → Zero conflicts
- Documentation updates to README (non-Sapling sections) → Minimal conflicts

### Potential Conflict Areas
1. **If upstream refactors VCS dispatch in `run_diff_impl`**:
   - Find the new dispatch pattern
   - Add `"sl" =>` arms that call `vcs_sl::` functions
   - Keep the pattern: check for "sl" explicitly before jj catchall

2. **If upstream changes picker dispatch**:
   - Add sapling branches that require vcs_sl module
   - Pattern: `if vcs == "sl" then require("difftastic-nvim.vcs_sl").method()`

### Merge Strategy
```bash
# When merging upstream
git fetch upstream
git merge upstream/main

# If conflicts in lib.rs dispatch:
# 1. Accept upstream changes
# 2. Re-add the "sl" match arms calling vcs_sl:: functions
# 3. Ensure "sl" cases come before jj catchall

# If conflicts in picker.lua:
# 1. Accept upstream changes  
# 2. Re-add vcs == "sl" branches calling vcs_sl module
```

## Testing After Merge
```vim
:Difft          " Uncommitted changes
:Difft .        " Current commit
:DifftPick      " Picker with preview
```

## Configuration

```lua
require("difftastic-nvim").setup({
    vcs = "sl",
    snacks_picker = {
        enabled = true,
        sl_log_revset = nil, -- Optional: filter picker commits
    },
})
```

## Requires

Sapling must be configured with extdiff extension:

```ini
# ~/.config/sapling/sapling.conf
[extensions]
extdiff =

[extdiff]
cmd.difft = difft
```
