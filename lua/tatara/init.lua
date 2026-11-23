-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}
local sessions = {}
local current_session
local function active()
  local value = sessions[vim.api.nvim_get_current_tabpage()]
  assert(value and not value.closed, 'No Tatara review in this tab. Use :Tatara first.')
  return value
end
function M.setup(opts)
  require('tatara.config').setup(opts)
end
function M.start(opts)
  opts = vim.deepcopy(opts or {})
  local function ready()
    vim.schedule(function()
      M.open(opts)
    end)
  end
  if vim.v.vim_did_enter == 1 then
    ready()
  else
    vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = ready })
  end
end
function M.open(opts)
  opts = vim.deepcopy(opts or {})
  local config = require('tatara.config')
  if opts.reduce_motion ~= nil then
    config.setup(vim.tbl_deep_extend('force', config.get(), { reduce_motion = opts.reduce_motion }))
  end
  if opts.language or opts.sidebar_width or opts.files_view or opts.wrap ~= nil then
    local overrides = { layout = {} }
    overrides.language = opts.language
    overrides.layout.sidebar_width = opts.sidebar_width
    overrides.layout.files = opts.files_view
    config.setup(vim.tbl_deep_extend('force', config.get(), overrides))
  end
  if opts.colorscheme then
    local flavor = opts.colorscheme:match('^catppuccin%-(%w+)$')
    if flavor then
      config.setup(vim.tbl_deep_extend('force', config.get(), { theme = flavor }))
    else
      vim.cmd.colorscheme(opts.colorscheme)
    end
  end
  if
    not opts.cwd
    and current_session
    and not current_session.closed
    and vim.api.nvim_get_current_tabpage() == current_session.tab
  then
    opts.cwd = current_session.opts.cwd
  end
  assert(vim.fn.has('nvim-0.13') == 1, 'tatara.nvim currently requires Neovim nightly (0.13+)')
  if current_session and not current_session.closed then
    assert(not current_session.writing, 'Wait for the current write to finish before opening another review')
    local previous = current_session
    previous:close()
    assert(previous.closed, 'Close the modified review composer before opening another review')
  end
  opts.cwd = opts.cwd or vim.fn.getcwd()
  local session = require('tatara.session').new(opts)
  sessions[session.tab] = session
  current_session = session
  return session.tab
end
function M.close()
  active():close()
end
-- A native session can restore URI placeholders, but not their backend process.
-- Remove only empty, unmodified, unowned placeholders; retain all user content.
function M.prune_restored()
  local api, live, stale = vim.api, {}, {}
  for _, s in pairs(sessions) do
    if not s.closed then
      live[s.id] = true
    end
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local id = api.nvim_buf_get_name(buf):match('^tatara://([^/]+)/')
    if id and not live[id] and not vim.bo[buf].modified then
      local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      if #lines == 0 or (#lines == 1 and lines[1] == '') then
        stale[buf] = true
      end
    end
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and stale[api.nvim_win_get_buf(win)] then
      local count = 0
      for _, other in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_config(other).relative == '' then
          count = count + 1
        end
      end
      if count > 1 then
        api.nvim_win_close(win, false)
      else
        api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
      end
    end
  end
  for buf in pairs(stale) do
    if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
      api.nvim_buf_delete(buf, {})
    end
  end
end
function M.get_context()
  return vim.deepcopy(active():context())
end
function M.open_file(path, target)
  active():open_file(path, target)
end
function M.find_files()
  active():find_files()
end
function M.grep(mode, query)
  active():grep(mode, query)
end
function M.comments()
  active():comments()
end
function M.list(opts)
  local session = active()
  if session.opts.local_base then
    M.start(vim.tbl_extend('force', { list = true, cwd = session.opts.cwd }, opts or {}))
  else
    session:list(opts)
  end
end
for _, action in ipairs({
  'combined',
  'checks',
  'overview',
  'discussion',
  'drafts',
  'filters',
  'file_comment',
  'mark_reviewed',
  'mark_hunk_reviewed',
  'toggle_reviewed',
  'filter_files',
  'set_file_filter',
  'saved_reviews',
  'typed_comment',
  'browser',
  'help',
  'theme',
  'notifications',
  'diff_view',
  'post_comment',
}) do
  M[action] = function(...)
    return active()[action](active(), ...)
  end
end
function M.suggest(opts)
  active():suggest(opts)
end
function M.export_review(format, destination)
  active():export_review(format, destination)
end
function M.comment(opts)
  active():comment(opts)
end
function M.review()
  active():review()
end
function M.refresh()
  active():refresh()
end
function M.command(args)
  local words = args.fargs
  local action = words[1]
  if not action or tonumber(action) then
    local ok, session = pcall(active)
    if ok and not session.opts.local_base then
      session:open_item(tonumber(action))
    else
      M.start({ number = tonumber(action) })
    end
    return
  end
  if action == 'local' then
    local flag = words[3]
    if
      not words[2]
      or vim.startswith(words[2], '--')
      or #words > 3
      or (flag and flag ~= '--worktree' and flag ~= '--no-worktree')
    then
      local config = require('tatara.config')
      config.notify(config.text('Usage: :Tatara local <base> [--no-worktree]'), vim.log.levels.ERROR)
      return
    end
    local opts = { local_base = words[2] }
    if flag then
      opts.include_worktree = flag == '--worktree'
    end
    M.start(opts)
    return
  end
  if action == 'demo' then
    M.start({ demo = true })
    return
  end
  if action == 'list' or action == 'issues' then
    local ok, session = pcall(active)
    if ok then
      M.list({ kind = action == 'issues' and 'issue' or 'pullRequest' })
    else
      M.start({ list = true, kind = action == 'issues' and 'issue' or 'pullRequest' })
    end
    return
  end
  if action == 'export' then
    M.export_review(words[2] == 'clipboard' and 'markdown' or words[2], words[2] == 'clipboard' and 'clipboard' or nil)
    return
  end
  if action == 'suggest' then
    M.suggest({ start_line = args.range > 0 and args.line1 or nil, end_line = args.range > 0 and args.line2 or nil })
    return
  end
  if
    M[action]
    and action ~= 'comment'
    and action ~= 'command'
    and action ~= 'open'
    and action ~= 'start'
    and action ~= 'setup'
    and action ~= 'get_context'
  then
    M[action]()
  elseif action == 'files' then
    active():show_files()
  elseif action == 'comment' then
    M.comment({ start_line = args.range > 0 and args.line1 or nil, end_line = args.range > 0 and args.line2 or nil })
  else
    error('Unknown Tatara command: ' .. action)
  end
end
vim.api.nvim_create_autocmd('User', {
  pattern = 'TataraClosed',
  callback = function(event)
    for tab, session in pairs(sessions) do
      if session.id == event.data.id then
        sessions[tab] = nil
        if current_session == session then
          current_session = nil
        end
      end
    end
  end,
})
vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    for _, session in pairs(sessions) do
      if not session.closed then
        session.rpc:close()
      end
    end
  end,
})
return M
