-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local api = vim.api
local original, tab = api.nvim_get_current_buf(), api.nvim_get_current_tabpage()
api.nvim_buf_set_lines(original, 0, -1, false, { 'Unsaved user work' })
vim.cmd.tabnew()
local stale_tab = api.nvim_get_current_tabpage()
local stale = api.nvim_get_current_buf()
api.nvim_buf_set_name(stale, 'tatara://expired/summary')
local unloaded = vim.fn.bufadd('tatara://expired/unloaded')
vim.cmd.tabnew()
local preserved = api.nvim_get_current_buf()
api.nvim_buf_set_name(preserved, 'tatara://expired/user-note')
api.nvim_buf_set_lines(preserved, 0, -1, false, { 'User content must remain' })
vim.bo[preserved].modified = false
vim.cmd.runtime('plugin/tatara.lua')
local function run()
  api.nvim_exec_autocmds('SessionLoadPost', {})
  assert(vim.wait(1000, function()
    return not api.nvim_buf_is_valid(stale)
  end, 10))
  assert(not api.nvim_tabpage_is_valid(stale_tab), 'Empty restored review tab survived')
  assert(not api.nvim_buf_is_valid(unloaded), 'Unloaded restored placeholder survived')
  assert(
    api.nvim_tabpage_is_valid(tab)
      and api.nvim_buf_get_lines(original, 0, -1, false)[1] == 'Unsaved user work'
      and vim.bo[original].modified,
    'Session cleanup changed user work'
  )
  assert(
    api.nvim_buf_get_lines(preserved, 0, -1, false)[1] == 'User content must remain',
    'Session cleanup removed nonempty content'
  )
  print(
    'Neovim session restore passed: empty expired review removed; modified user work and nonempty URI content preserved.'
  )
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cq!')
else
  vim.cmd('qa!')
end
