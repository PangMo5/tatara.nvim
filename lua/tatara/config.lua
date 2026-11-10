-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}
local defaults = {
  backend = nil,
  language = 'en',
  theme = 'auto',
  reduce_motion = false,
  progress = { native = false },
  layout = { sidebar_width = 52, stacked_below = 134, files = 'tree', preview_on_focus = true },
  files = { include = '', exclude = '', hide_reviewed = false },
  comment_types = {},
  diff = { engine = 'difftastic', context_folds = false },
  picker = nil,
  initial_view = 'diff',
  keymaps = {
    open = '<CR>',
    pick = '<C-p>',
    overview = '<LocalLeader>1',
    diff_view = '<LocalLeader>2',
    discussion = '<LocalLeader>3',
    checks = '<LocalLeader>4',
    combined = 'gC',
    drafts = 'gP',
    more = 'L',
    kind = 'I',
    reviewed = '<Space>',
    reviewed_hunk = 'gH',
    hide_reviewed = '<LocalLeader>h',
    filter_files = '<LocalLeader>f',
    next_hunk = ']h',
    previous_hunk = '[h',
    next_file = ']f',
    previous_file = '[f',
    suggest = 'gs',
    typed_comment = '<LocalLeader>c',
    export_review = '<LocalLeader>e',
    saved_reviews = '<LocalLeader>s',
    browser = 'o',
    filters = 'f',
    help = '?',
    theme = 'T',
    notifications = '!',
    previous_view = 'g[',
    page_down = '<C-f>',
    page_up = '<C-b>',
    half_page_down = '<C-d>',
    half_page_up = '<C-u>',
    next_view = 'g]',
    wrap = 'gw',
    next_comment = ']c',
    previous_comment = '[c',
    next_pane = false,
    previous_pane = false,
    fold_close = 'h',
    fold_open = 'l',
    comment = 'c',
    file_comment = '<LocalLeader>C',
    post_comment = '<LocalLeader>p',
    definition = 'gd',
    references = 'gr',
    hover = 'K',
    review = 'R',
    files = 'gF',
    close = 'q',
    find_files = '/',
    grep = 'g/',
    comments = 'gc',
    refresh = 'r',
  },
  prepare = nil,
  notify = nil,
  select = nil,
}

function M.setup(opts)
  opts = opts or {}
  for key in pairs(opts) do
    assert(
      defaults[key] ~= nil
        or key == 'backend'
        or key == 'prepare'
        or key == 'notify'
        or key == 'select'
        or key == 'picker',
      'Unknown Tatara option: ' .. key
    )
  end
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)
  for _, field in ipairs({ 'include', 'exclude' }) do
    assert(type(M.options.files[field]) == 'string' and #M.options.files[field] <= 4096, 'Invalid file filter')
    assert(pcall(vim.regex, M.options.files[field]), 'Invalid file filter expression')
  end
  assert(type(M.options.files.hide_reviewed) == 'boolean', 'Invalid reviewed visibility')
  assert(M.options.diff.engine == 'difftastic' or M.options.diff.engine == 'native', 'Unknown diff engine')
end

function M.get()
  if not M.options then
    M.setup()
  end
  return M.options
end

function M.backend()
  local selected = M.get().backend or vim.env.TATARA_BACKEND
  if selected then
    return selected
  end
  local source = debug.getinfo(1, 'S').source:sub(2)
  source = vim.uv.fs_realpath(source) or source
  local prefix = source:match('^(.*)/share/tatara/runtime/lua/tatara/config%.lua$')
  if prefix then
    return prefix .. '/bin/tatara'
  end
  local checkout = source:match('^(.*)/lua/tatara/config%.lua$')
  if checkout and vim.uv.fs_stat(vim.fs.joinpath(checkout, 'Package.swift')) then
    return vim.fs.joinpath(checkout, '.artifacts', 'products', 'release-' .. vim.uv.os_uname().machine, 'tatara')
  end
  return 'tatara'
end

function M.notify(message, level)
  if M.get().notify then
    M.get().notify(message, level or vim.log.levels.INFO, { title = 'Tatara' })
    return
  end
  local chrome = require('tatara.chrome')
  local session = chrome.sessions[vim.api.nvim_get_current_tabpage()]
  if session and not session.closed then
    chrome.notify(session, message, level or vim.log.levels.INFO)
  else
    vim.notify(message, level or vim.log.levels.INFO, { title = 'Tatara' })
  end
end

function M.select(items, opts, done)
  (M.get().select or vim.ui.select)(items, opts, done)
end

function M.text(key)
  local lang = M.get().language
  return (require('tatara.strings')[lang] or {})[key] or key
end

return M
