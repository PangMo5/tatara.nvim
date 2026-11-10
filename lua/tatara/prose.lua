-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local M = {}
function M.render(buf, win)
  vim.bo[buf].filetype = 'markdown'
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = 'nc'
  vim.wo[win].foldenable = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].statuscolumn = ''
  vim.wo[win].cursorline = false
  vim.treesitter.start(buf, 'markdown')
end
return M
