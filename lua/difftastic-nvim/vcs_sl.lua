--- Sapling VCS support for difftastic.nvim picker
local M = {}

local function is_set(value)
    return value ~= nil and value ~= vim.NIL and value ~= ""
end

local function run_command(cmd)
    local lines = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then
        return nil
    end
    return lines
end

local function display_width(s)
    return vim.fn.strdisplaywidth(s)
end

local function pad_right(s, width)
    local pad = width - display_width(s)
    if pad <= 0 then
        return s
    end
    return s .. string.rep(" ", pad)
end

local function fit_description(desc)
    desc = desc ~= "" and desc or "(no description set)"
    if vim.fn.strchars(desc) > 60 then
        return vim.fn.strcharpart(desc, 0, 60) .. "..."
    end
    return desc
end

function M.items(limit, revset, exclude_rev)
    local cmd = { "sl", "log", "--no-graph", "-l", tostring(limit) }

    if is_set(revset) then
        table.insert(cmd, "-r")
        table.insert(cmd, revset)
    end

    table.insert(cmd, "-T")
    table.insert(
        cmd,
        '{ifcontains(rev, revset("."), "@", if(public, "◆", "○"))}\t{firstline(desc)}\t{shortest(node, 8)}\t{age(date)}\t{node}\n'
    )

    local lines = run_command(cmd)
    if not lines then
        return nil
    end

    local raw_items = {}
    local revset_w = 0
    for _, line in ipairs(lines) do
        local icon, desc, revset_id, age, rev = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]+)$")
        if rev and rev ~= exclude_rev then
            revset_w = math.max(revset_w, display_width(revset_id))
            table.insert(raw_items, {
                icon = icon,
                desc = desc,
                revset_id = revset_id,
                age = age,
                rev = rev,
            })
        end
    end

    local items = {}
    for _, item in ipairs(raw_items) do
        local icon_hl = "DifftPickerJjIconNormal"
        if item.icon == "@" then
            icon_hl = "DifftPickerJjIconCurrent"
        elseif item.icon == "◆" then
            icon_hl = "DifftPickerJjIconImmutable"
        end

        local desc = fit_description(item.desc)
        local revset = pad_right(item.revset_id, revset_w)
        local text = string.format("%s  %s  %s  %s", item.icon, desc, revset, item.age)
        table.insert(items, {
            rev = item.rev,
            text = text,
            chunks = {
                { item.icon .. "  ", icon_hl },
                { desc .. "  ", "DifftPickerJjDesc" },
                { revset .. "  ", "DifftPickerJjRevset" },
                { item.age, "DifftPickerJjAge" },
            },
        })
    end

    return items
end

function M.preview(opts)
    return function(ctx)
        if not (ctx.item and ctx.item.rev) then
            return
        end

        local preview = require("snacks.picker.preview")
        -- Show verbose details of the selected commit
        local cmd = { "sl", "log", "-r", ctx.item.rev, "-v", "--color=always" }

        preview.cmd(cmd, ctx, {
            term = true,
            ansi = false,
            pty = true,
        })
    end
end

function M.effective_revset(opts, rev_filter)
    if is_set(rev_filter) and is_set(opts.sl_log_revset) then
        return string.format("(%s) & (%s)", rev_filter, opts.sl_log_revset)
    end
    if is_set(rev_filter) then
        return rev_filter
    end
    return opts.sl_log_revset
end

function M.title(action)
    if action == "pick" then
        return "Select sl revision"
    elseif action == "range_end" then
        return "Select range end (sl)"
    else
        return "Select range start"
    end
end

function M.range_ancestor_filter(end_rev)
    -- Only show draft commits that are ancestors of end_rev
    return string.format("(ancestors(%s)) & draft()", end_rev)
end

--- Get the commit hash from before a specific mutation operation.
--- Parses `sl debugmutation -r .` output to find the commit before the most
--- recent occurrence of the given operation (skipping metaedits).
--- @param operation string The mutation operation to look for (e.g. "amend", "rebase")
--- @return string|nil Commit hash or nil if not found
function M.get_pre_mutation_commit(operation)
    local handle = io.popen("sl debugmutation -r . 2>/dev/null")
    if not handle then
        return nil
    end

    local output = handle:read("*a")
    handle:close()

    local lines = {}
    for line in output:gmatch("[^\n]+") do
        table.insert(lines, line)
    end

    if #lines == 0 then
        return nil
    end

    -- First line should be current commit with the expected operation
    local current_hash, current_op = lines[1]:match("^%s*%*?%s*([a-f0-9]+)%s+(%w+)%s+by")
    if not current_hash or current_op ~= operation then
        return nil
    end

    -- Walk through subsequent lines, skipping metaedits, to find the pre-operation version
    for i = 2, #lines do
        local hash, op = lines[i]:match("^%s*([a-f0-9]+)%s+(%w+)%s+by")
        if hash and op ~= "metaedit" then
            return hash
        end
        -- Also match bare hash (root of mutation chain, no operation)
        if not hash then
            hash = lines[i]:match("^%s*([a-f0-9]+)%s*$")
            if hash then
                return hash
            end
        end
    end

    return nil
end

--- Get the current commit hash.
--- @return string|nil Commit hash or nil if not found
function M.get_current_commit()
    local handle = io.popen("sl log -r . -T '{node}' 2>/dev/null")
    if not handle then
        return nil
    end

    local hash = handle:read("*l")
    handle:close()

    if hash and hash:match("^[a-f0-9]+$") then
        return hash
    end

    return nil
end

return M
