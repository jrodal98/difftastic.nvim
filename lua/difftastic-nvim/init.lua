--- Difftastic side-by-side diff viewer for Neovim.
local M = {}

local binary = require("difftastic-nvim.binary")
local diff = require("difftastic-nvim.diff")
local tree = require("difftastic-nvim.tree")
local highlight = require("difftastic-nvim.highlight")
local keymaps = require("difftastic-nvim.keymaps")

--- Checks if a file contains @generated or @partially-generated marker in first 50 lines.
--- @param path string
--- @return boolean
local function is_generated_file(path)
    -- Get VCS root to resolve relative paths
    local vcs_root
    if M.config.vcs == "git" then
        local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
        if handle then
            vcs_root = handle:read("*l")
            handle:close()
        end
    elseif M.config.vcs == "sl" then
        local handle = io.popen("sl root 2>/dev/null")
        if handle then
            vcs_root = handle:read("*l")
            handle:close()
        end
    else -- jj
        local handle = io.popen("jj root 2>/dev/null")
        if handle then
            vcs_root = handle:read("*l")
            handle:close()
        end
    end

    if not vcs_root then
        return false
    end

    local full_path = vcs_root .. "/" .. path
    local file = io.open(full_path, "r")
    if not file then
        return false
    end

    -- Check first 50 lines for @generated or @partially-generated markers
    for i = 1, 50 do
        local line = file:read("*l")
        if not line then
            break
        end
        if line:match("@generated") or line:match("@partially%-generated") then
            file:close()
            return true
        end
    end

    file:close()
    return false
end

--- Default configuration
M.config = {
    download = false,
    vcs = "jj", -- "jj", "git", or "sl"
    --- Highlight mode: "treesitter" (full syntax) or "difftastic" (no syntax, colored changes only)
    highlight_mode = "treesitter",
    --- When true, next_hunk at last hunk wraps to next file (and prev_hunk to prev file)
    hunk_wrap_file = true,
    --- When true, scroll to first hunk after opening a file
    scroll_to_first_hunk = true,
    --- When true, exclude files containing @generated markers (default: true)
    exclude_generated = true,
    keymaps = {
        next_file = "]f",
        prev_file = "[f",
        next_hunk = "]c",
        prev_hunk = "[c",
        close = "q",
        focus_tree = "<Tab>",
        focus_diff = "<Tab>",
        select = "<CR>",
        goto_file = "gf",
        toggle_tree = "-", -- Toggle tree visibility
    },
    tree = {
        width = 40,
        icons = {
            enable = true,
            dir_open = "",
            dir_closed = "",
        },
    },
    snacks_picker = {
        enabled = false,
        limit = 200,
        jj_log_revset = nil,
        sl_log_revset = nil,
    },
}

--- Current diff state
M.state = {
    current_file_idx = 1,
    files = {},
    tree_win = nil,
    tree_buf = nil,
    left_win = nil,
    left_buf = nil,
    right_win = nil,
    right_buf = nil,
    original_tabpage = nil,
    diff_tabpage = nil,
}

--- Initialize the plugin with user options.
--- @param opts table|nil User configuration
function M.setup(opts)
    opts = opts or {}

    -- Merge config
    if opts.download ~= nil then
        M.config.download = opts.download
    end
    if opts.vcs then
        M.config.vcs = opts.vcs
    end
    if opts.highlight_mode then
        M.config.highlight_mode = opts.highlight_mode
    end
    if opts.hunk_wrap_file ~= nil then
        M.config.hunk_wrap_file = opts.hunk_wrap_file
    end
    if opts.scroll_to_first_hunk ~= nil then
        M.config.scroll_to_first_hunk = opts.scroll_to_first_hunk
    end
    if opts.keymaps then
        -- Manual merge to preserve explicit false values (tbl_extend ignores them)
        -- Note: nil values are skipped by pairs(), so they keep the default
        for k, v in pairs(opts.keymaps) do
            M.config.keymaps[k] = v
        end
    end
    if opts.tree then
        if opts.tree.icons then
            M.config.tree.icons = vim.tbl_extend("force", M.config.tree.icons, opts.tree.icons)
        end
        if opts.tree.width then
            M.config.tree.width = opts.tree.width
        end
    end
    if opts.snacks_picker then
        M.config.snacks_picker = vim.tbl_extend("force", M.config.snacks_picker, opts.snacks_picker)
    end

    highlight.setup(opts.highlights)
    binary.ensure_exists(M.config.download)
end

--- Open diff view for a revision/commit range.
--- @param revset string|nil jj revset or git commit range (nil = unstaged, "--staged" = staged, "--include-generated" = include generated files, "--amend" = compare to pre-amend version)
function M.open(revset)
    if M.state.tree_win or M.state.left_win or M.state.right_win then
        M.close()
    end

    -- Check for --include-generated flag
    local include_generated = false
    if revset == "--include-generated" then
        include_generated = true
        revset = nil -- Treat as unstaged
    end

    -- Check for --amend flag (sapling only)
    if revset == "--amend" then
        if M.config.vcs ~= "sl" then
            vim.notify("--amend only works with sapling VCS", vim.log.levels.WARN)
            return
        end

        -- Get pre-amend commit from debugmutation
        local vcs_sl = require("difftastic-nvim.vcs_sl")
        local pre_amend = vcs_sl.get_pre_amend_commit()
        if not pre_amend then
            vim.notify("Could not find pre-amend version (no amend in mutation history for this commit)", vim.log.levels.WARN)
            return
        end

        -- Get current commit hash
        local current = vcs_sl.get_current_commit()
        if not current then
            vim.notify("Could not get current commit hash", vim.log.levels.ERROR)
            return
        end

        -- Compare pre-amend to current commit
        revset = string.format("%s..%s", pre_amend, current)
        vim.notify(string.format("Comparing pre-amend (%s) to current (%s)", pre_amend:sub(1, 8), current:sub(1, 8)), vim.log.levels.INFO)
    end

    local result
    if revset == nil then
        result = binary.get().run_diff_unstaged(M.config.vcs)
    elseif revset == "--staged" then
        result = binary.get().run_diff_staged(M.config.vcs)
    else
        result = binary.get().run_diff(revset, M.config.vcs)
    end
    if not result.files or #result.files == 0 then
        vim.notify("No changes found", vim.log.levels.INFO)
        return
    end

    -- Filter out @generated files unless explicitly included
    if M.config.exclude_generated and not include_generated then
        local original_count = #result.files
        result.files = vim.tbl_filter(function(file)
            return not is_generated_file(file.path)
        end, result.files)

        local filtered_count = original_count - #result.files
        if filtered_count > 0 then
            vim.notify(
                string.format("Filtered %d @generated/@partially-generated file%s (use :Difft --include-generated to show all)",
                    filtered_count, filtered_count == 1 and "" or "s"),
                vim.log.levels.INFO
            )
        end

        if #result.files == 0 then
            vim.notify("No changes found (all files are @generated/@partially-generated)", vim.log.levels.INFO)
            return
        end
    end

    M.state.files = result.files
    M.state.current_file_idx = 1

    -- Store original tabpage and create new one for diff view
    M.state.original_tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    M.state.diff_tabpage = vim.api.nvim_get_current_tabpage()

    tree.open(M.state)
    diff.open(M.state)
    keymaps.setup(M.state)

    local first_idx = tree.first_file_in_display_order()
    if first_idx then
        M.show_file(first_idx)
    end
end

--- Close the diff view.
function M.close()
    local diff_tabpage = M.state.diff_tabpage
    local original_tabpage = M.state.original_tabpage

    -- Reset state first
    M.state = {
        current_file_idx = 1,
        files = {},
        tree_win = nil,
        tree_buf = nil,
        left_win = nil,
        left_buf = nil,
        right_win = nil,
        right_buf = nil,
        original_tabpage = nil,
        diff_tabpage = nil,
    }

    -- Switch to original tabpage if valid
    if original_tabpage and vim.api.nvim_tabpage_is_valid(original_tabpage) then
        vim.api.nvim_set_current_tabpage(original_tabpage)
    end

    -- Close the diff tabpage
    if diff_tabpage and vim.api.nvim_tabpage_is_valid(diff_tabpage) then
        local tabnr = vim.api.nvim_tabpage_get_number(diff_tabpage)
        vim.cmd("tabclose " .. tabnr)
    end
end

--- Show a specific file by index.
--- @param idx number File index (1-based)
function M.show_file(idx)
    if idx < 1 or idx > #M.state.files then
        return
    end
    M.state.current_file_idx = idx
    diff.render(M.state, M.state.files[idx])
    if M.config.scroll_to_first_hunk then
        diff.first_hunk(M.state)
    end
    tree.highlight_current(M.state)
end

--- Show a file and jump to a specific hunk after rendering completes.
--- @param idx number File index to show
--- @param hunk_fn function Hunk function to call (e.g., diff.first_hunk or diff.last_hunk)
local function show_file_and_jump_to_hunk(idx, hunk_fn)
    M.show_file(idx)
    vim.schedule(function()
        hunk_fn(M.state)
    end)
end

--- Navigate to the next file.
function M.next_file()
    local next_idx = tree.next_file_in_display_order(M.state.current_file_idx)
    if next_idx then
        M.show_file(next_idx)
        return
    end

    local first_idx = tree.first_file_in_display_order()
    if first_idx and first_idx ~= M.state.current_file_idx then
        M.show_file(first_idx)
    end
end

--- Navigate to the previous file.
function M.prev_file()
    local prev_idx = tree.prev_file_in_display_order(M.state.current_file_idx)
    if prev_idx then
        M.show_file(prev_idx)
        return
    end

    local last_idx = tree.last_file_in_display_order()
    if last_idx and last_idx ~= M.state.current_file_idx then
        M.show_file(last_idx)
    end
end

--- Navigate to the next hunk.
--- If hunk_wrap_file is enabled and at the last hunk, wraps to the first hunk of the next file.
--- Otherwise, wraps to the first hunk of the current file.
function M.next_hunk()
    local jumped = diff.next_hunk(M.state)
    if not jumped then
        if M.config.hunk_wrap_file then
            local next_idx = tree.next_file_in_display_order(M.state.current_file_idx)
            if next_idx then
                show_file_and_jump_to_hunk(next_idx, diff.first_hunk)
            else
                -- At last file, wrap to first file
                local first_idx = tree.first_file_in_display_order()
                if first_idx and first_idx ~= M.state.current_file_idx then
                    show_file_and_jump_to_hunk(first_idx, diff.first_hunk)
                end
            end
        else
            -- Wrap within current file
            diff.first_hunk(M.state)
        end
    end
    vim.cmd("normal! zz")
end

--- Navigate to the previous hunk.
--- If hunk_wrap_file is enabled and at the first hunk, wraps to the last hunk of the previous file.
--- Otherwise, wraps to the last hunk of the current file.
function M.prev_hunk()
    local jumped = diff.prev_hunk(M.state)
    if not jumped then
        if M.config.hunk_wrap_file then
            local prev_idx = tree.prev_file_in_display_order(M.state.current_file_idx)
            if prev_idx then
                show_file_and_jump_to_hunk(prev_idx, diff.last_hunk)
            else
                -- At first file, wrap to last file
                local last_idx = tree.last_file_in_display_order()
                if last_idx and last_idx ~= M.state.current_file_idx then
                    show_file_and_jump_to_hunk(last_idx, diff.last_hunk)
                end
            end
        else
            -- Wrap within current file
            diff.last_hunk(M.state)
        end
    end
    vim.cmd("normal! zz")
end

--- Go to the file at the current cursor position in an editable buffer.
--- Opens in a previous tabpage if one exists, otherwise creates a new tab.
--- Only works from the right pane (new/working version of the file).
function M.goto_file()
    local state = M.state
    local current_win = vim.api.nvim_get_current_win()

    -- Only works from right pane (new version), not tree or left pane
    if current_win ~= state.right_win or current_win == state.tree_win then
        return
    end

    local file = state.files[state.current_file_idx]
    if not file then
        return
    end

    -- Deleted files have no right-side content to navigate to
    if file.status == "deleted" then
        return
    end

    -- Get current cursor position (row is 1-indexed, col is 0-indexed)
    local cursor = vim.api.nvim_win_get_cursor(current_win)
    local row, col = cursor[1], cursor[2]
    local aligned = file.aligned_lines and file.aligned_lines[row]

    -- Find the target line number (right side = new version)
    local target_line
    if aligned and aligned[2] then
        -- Direct mapping exists
        target_line = aligned[2] + 1 -- 0-indexed to 1-indexed
    else
        -- Filler line - find nearest non-filler line
        -- Search upward first, then downward
        for offset = 1, #file.aligned_lines do
            -- Check above
            if row - offset >= 1 then
                local above = file.aligned_lines[row - offset]
                if above and above[2] then
                    target_line = above[2] + 1
                    break
                end
            end
            -- Check below
            if row + offset <= #file.aligned_lines then
                local below = file.aligned_lines[row + offset]
                if below and below[2] then
                    target_line = below[2] + 1
                    break
                end
            end
        end
    end

    -- Fallback to line 1 if no mapping found
    target_line = target_line or 1

    local filepath = file.path

    -- Close diff view (switches to original tab, closes diff tab)
    M.close()

    -- Open file and jump to line and column
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    -- Clamp column to line length to avoid errors on shorter lines
    local line_content = vim.api.nvim_buf_get_lines(0, target_line - 1, target_line, false)[1] or ""
    local target_col = math.min(col, math.max(0, #line_content - 1))
    vim.api.nvim_win_set_cursor(0, { target_line, target_col })
end

--- Toggle tree visibility.
function M.toggle_tree()
    local tree_module = require("difftastic-nvim.tree")

    if M.state.tree_win and vim.api.nvim_win_is_valid(M.state.tree_win) then
        -- Tree is open, close it
        vim.api.nvim_win_close(M.state.tree_win, true)
        M.state.tree_win = nil
        M.state.tree_buf = nil
    else
        -- Tree is closed, reopen it
        tree_module.open(M.state)
    end
end

--- Update binary to latest release.
function M.update()
    binary.update()
end

--- Pick a revision/commit with snacks.nvim and open diff view.
function M.pick_revision()
    if not M.config.snacks_picker.enabled then
        vim.notify("snacks picker integration is disabled; set snacks_picker.enabled = true", vim.log.levels.WARN)
        return
    end

    require("difftastic-nvim.picker").pick(M.config.vcs, M.config.snacks_picker, function(rev)
        M.open(rev)
    end)
end

--- Pick a start/end revision range with snacks.nvim and open diff view.
function M.pick_range()
    if not M.config.snacks_picker.enabled then
        vim.notify("snacks picker integration is disabled; set snacks_picker.enabled = true", vim.log.levels.WARN)
        return
    end

    require("difftastic-nvim.picker").pick_range(M.config.vcs, M.config.snacks_picker, function(start_rev, end_rev)
        M.open(string.format("%s..%s", start_rev, end_rev))
    end)
end

return M
