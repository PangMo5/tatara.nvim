-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local root = vim.uv.cwd()
local api = vim.api
local backend = vim.env.TATARA_TEST_BACKEND or (root .. '/.artifacts/products/release-arm64/tatara')
assert(vim.fn.executable(backend) == 1, 'Build the Release backend first')
local errors, events = {}, {}
local original = api.nvim_get_current_buf()
api.nvim_buf_set_lines(original, 0, -1, false, { 'User work must remain intact' })
local original_tab = api.nvim_get_current_tabpage()
local original_windows = api.nvim_tabpage_list_wins(original_tab)
vim.keymap.set('n', 'gd', function() end, { desc = 'User definition mapping' })
local gd = vim.fn.maparg('gd', 'n', false, true)
vim.diagnostic.config({ virtual_text = false, signs = true, underline = true })
local diagnostic_config = vim.deepcopy(vim.diagnostic.config())
api.nvim_create_autocmd('User', {
  pattern = 'Tatara*',
  callback = function(event)
    events[event.match] = event.data
  end,
})
api.nvim_create_autocmd('FileType', {
  pattern = 'swift',
  callback = function(event)
    vim.keymap.set('n', 'c', function() end, { buffer = event.buf, desc = 'User source mapping' })
  end,
})
vim.lsp.config('tatara_user_fixture', {
  cmd = { vim.v.progpath, '--headless', '--clean', '-l', root .. '/tests/nvim/lsp_fixture.lua' },
  filetypes = { 'swift' },
  root_markers = { '.git' },
})
vim.lsp.enable('tatara_user_fixture')
local function wait(label, condition)
  assert(
    vim.wait(15000, function()
      assert(#errors == 0, table.concat(errors, '\n'))
      return condition()
    end, 10),
    'Timed out: ' .. label
  )
end
local function source_win(side, tab)
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    local value = vim.b[api.nvim_win_get_buf(win)].tatara
    if value and value.side == side then
      return win
    end
  end
end
local function lines(buf)
  return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end
local function run()
  local preparations = 0
  require('tatara').setup({
    backend = backend,
    layout = { stacked_below = 1 },
    prepare = function(context, done)
      assert(vim.fn.isdirectory(context.workspace) == 1)
      preparations = preparations + 1
      vim.schedule(function()
        done(nil)
      end)
    end,
    notify = function(message, level)
      if level == vim.log.levels.ERROR then
        errors[#errors + 1] = message
      end
    end,
    select = function(items, _, done)
      done(items[1], 1)
    end,
  })
  local tab = require('tatara').open({ demo = true })
  wait('PR ready', function()
    return events.TataraReady ~= nil
  end)
  require('tatara').open_file('Sources/ReviewQueue.swift')
  wait('native source', function()
    return events.TataraFileOpened
      and events.TataraFileOpened.path == 'Sources/ReviewQueue.swift'
      and require('tatara').get_context().windows.left ~= nil
  end)
  local right = assert(source_win('RIGHT', tab))
  local left = assert(source_win('LEFT', tab))
  local buf = api.nvim_win_get_buf(right)
  assert(vim.bo[buf].buftype == '' and vim.bo[buf].filetype == 'swift', 'Head source must be an ordinary file buffer')
  assert(vim.bo[api.nvim_win_get_buf(left)].buftype == '', 'Base source must also use its immutable file path')
  assert(api.nvim_win_get_cursor(right)[1] == 5, 'Initial cursor must select the first change')
  assert(vim.bo[buf].readonly and not vim.bo[buf].modifiable)
  wait('user LSP auto-attachment', function()
    return #vim.lsp.get_clients({ bufnr = buf, name = 'tatara_user_fixture' }) > 0
  end)
  wait('native diagnostics', function()
    return #vim.diagnostic.get(buf) > 0
  end)
  assert(vim.diagnostic.get(buf)[1].message == 'User LSP diagnostic')
  api.nvim_set_current_win(right)
  local unchanged = vim.fs.dirname(api.nvim_buf_get_name(buf)) .. '/Unchanged.swift'
  vim.cmd.edit(vim.fn.fnameescape(unchanged))
  local unchanged_buf = api.nvim_get_current_buf()
  assert(
    vim.bo[unchanged_buf].readonly and not vim.bo[unchanged_buf].modifiable,
    'Native navigation escaped immutable source protection: '
      .. vim.inspect({ name = api.nvim_buf_get_name(unchanged_buf), root = require('tatara').get_context().workspace })
  )
  assert(
    require('tatara').get_context().path == 'Sources/Unchanged.swift' and not require('tatara').get_context().reviewable,
    'Unchanged source acquired a review anchor'
  )
  require('tatara').comment()
  assert(api.nvim_get_current_buf() == unchanged_buf, 'Unchanged source opened a review composer')
  require('tatara').open_file('Sources/ReviewQueue.swift', { line = 5, side = 'RIGHT', native = true })
  wait('return from unchanged source', function()
    return api.nvim_get_current_buf() == buf
  end)
  left = assert(source_win('LEFT', tab))
  assert(vim.deep_equal(diagnostic_config, vim.diagnostic.config()), 'Plugin changed user diagnostics')
  api.nvim_set_current_win(right)
  assert(vim.fn.maparg('gd', 'n', false, true).callback == gd.callback, 'Plugin replaced user gd')
  assert(
    vim.fn.maparg('c', 'n', false, true).desc == 'User source mapping',
    'Plugin replaced a buffer-local user mapping'
  )
  vim.cmd('wincmd h')
  assert(api.nvim_get_current_win() == left, 'Native window movement failed')
  api.nvim_set_current_win(right)
  require('tatara').open_file('Sources/Selection.swift')
  wait('second source', function()
    return require('tatara').get_context().path == 'Sources/Selection.swift'
  end)
  api.nvim_feedkeys(vim.keycode('<C-o>'), 'nx', false)
  wait('native jump back', function()
    return require('tatara').get_context().path == 'Sources/ReviewQueue.swift'
  end)
  api.nvim_feedkeys(vim.keycode('<C-i>'), 'nx', false)
  wait('native jump forward', function()
    return require('tatara').get_context().path == 'Sources/Selection.swift'
  end)
  require('tatara').open_file('Sources/ReviewQueue.swift', { line = 5, column = 0, side = 'RIGHT' })
  wait('exact source restoration', function()
    return require('tatara').get_context().path == 'Sources/ReviewQueue.swift'
  end)
  assert(preparations == 1, 'The same immutable workspace was prepared repeatedly')
  require('tatara.config').get().layout.stacked_below = 100
  api.nvim_exec_autocmds('VimResized', {})
  local windows = require('tatara').get_context().windows
  assert(api.nvim_win_get_width(windows.files) >= 78, 'Narrow Files pane must span the width')
  assert(
    api.nvim_win_get_position(windows.right)[1] > api.nvim_win_get_position(windows.files)[1],
    'Narrow content must stay below Files'
  )
  assert(api.nvim_win_get_cursor(windows.right)[1] == 5, 'Resize changed the source position')
  require('tatara.config').get().layout.stacked_below = 1
  api.nvim_exec_autocmds('VimResized', {})
  api.nvim_set_current_win(windows.right)
  require('tatara').comment()
  local unsaved = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(unsaved, 0, -1, false, { 'Unwritten comment body' })
  vim.cmd.stopinsert()
  require('tatara').close()
  assert(api.nvim_tabpage_is_valid(tab), 'Closing discarded an active modified composer')
  vim.fn.maparg('<Esc>', 'n', false, true).callback()
  require('tatara').comment()
  assert(lines(api.nvim_get_current_buf()) == 'Unwritten comment body', 'Closing the composer discarded its body')
  local composer = api.nvim_get_current_buf()
  assert(vim.bo[composer].buftype == 'acwrite', 'Comment must be a native writable Markdown buffer')
  api.nvim_buf_set_lines(composer, 0, -1, false, { 'A review draft from Neovim.' })
  vim.cmd.stopinsert()
  vim.cmd.write()
  wait('draft saved', function()
    return events.TataraDraftChanged and events.TataraDraftChanged.count == 1
  end)
  require('tatara').review()
  local summary = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(summary, 0, -1, false, { 'Review summary from Neovim.' })
  vim.cmd.stopinsert()
  vim.cmd.write()
  wait('concrete preview', function()
    return lines(api.nvim_get_current_buf()):find('This will be posted to GitHub.', 1, true) ~= nil
  end)
  assert(
    lines(api.nvim_get_current_buf()):find('A review draft from Neovim.', 1, true),
    'Preview lost the inline draft'
  )
  assert(lines(api.nvim_get_current_buf()):find('Review summary from Neovim.', 1, true), 'Preview lost the summary')
  require('tatara').close()
  wait('review closed', function()
    return events.TataraClosed ~= nil
  end)
  assert(api.nvim_tabpage_is_valid(original_tab) and #api.nvim_tabpage_list_wins(original_tab) == #original_windows)
  assert(lines(original) == 'User work must remain intact' and vim.bo[original].modified, 'Plugin modified user work')
  assert(not vim.bo[buf].readonly and vim.bo[buf].modifiable, 'Plugin did not restore existing buffer options')
  assert(vim.deep_equal(diagnostic_config, vim.diagnostic.config()))
  print(
    'Neovim integration passed: immutable native buffers, first change, user LSP and diagnostics, mappings, windows, drafts, write preview and cleanup; no forge writes.'
  )
end
local ok, err = xpcall(run, debug.traceback)
for _, client in ipairs(vim.lsp.get_clients()) do
  client:stop(true)
end
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cq!')
else
  vim.cmd('qa!')
end
