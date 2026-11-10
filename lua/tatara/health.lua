-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}
function M.check()
  vim.health.start('tatara.nvim')
  if vim.fn.has('nvim-0.13') == 1 then
    vim.health.ok('Neovim nightly 0.13+ is available')
  else
    vim.health.error('Use Neovim nightly 0.13+ for this initial version')
  end
  local command = require('tatara.config').backend()
  local executable = type(command) == 'table' and command[1] or command
  if vim.fn.executable(executable) == 1 then
    vim.health.ok('Tatara backend: ' .. executable)
  else
    vim.health.error('Tatara backend is unavailable: ' .. executable, { 'See :help tatara-install.' })
  end
  for _, name in ipairs({ 'git', 'gh', 'difft' }) do
    if vim.fn.executable(name) == 1 then
      vim.health.ok(name .. ' is executable')
    else
      vim.health.error(name .. ' is missing from PATH or configuration')
    end
  end
  vim.health.info('Configure and enable LSP servers normally. Tatara does not start servers or change diagnostics.')
end
return M
