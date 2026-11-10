-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.number = true
vim.o.hidden = true
vim.cmd('filetype plugin indent on')
vim.cmd('syntax enable')
vim.schedule(function()
  vim.opt.rtp:prepend(vim.env.TATARA_SOURCE_ROOT)
  require('tatara').setup({ backend = vim.env.TATARA_TEST_BACKEND })
  require('tatara').open({ demo = true })
end)
