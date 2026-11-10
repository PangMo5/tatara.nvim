-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local M = {}
local colors = {
  mocha = {
    text = '#cdd6f4',
    muted = '#7f849c',
    border = '#6c7086',
    accent = '#b4befe',
    blue = '#89b4fa',
    green = '#a6e3a1',
    red = '#f38ba8',
    peach = '#fab387',
    base = '#1e1e2e',
    surface = '#313244',
  },
  macchiato = {
    text = '#cad3f5',
    muted = '#8087a2',
    border = '#6e738d',
    accent = '#b7bdf8',
    blue = '#8aadf4',
    green = '#a6da95',
    red = '#ed8796',
    peach = '#f5a97f',
    base = '#24273a',
    surface = '#363a4f',
  },
  frappe = {
    text = '#c6d0f5',
    muted = '#838ba7',
    border = '#737994',
    accent = '#babbf1',
    blue = '#8caaee',
    green = '#a6d189',
    red = '#e78284',
    peach = '#ef9f76',
    base = '#303446',
    surface = '#414559',
  },
  latte = {
    text = '#4c4f69',
    muted = '#8c8fa1',
    border = '#9ca0b0',
    accent = '#7287fd',
    blue = '#1e66f5',
    green = '#40a02b',
    red = '#d20f39',
    peach = '#fe640b',
    base = '#eff1f5',
    surface = '#ccd0da',
  },
}
function M.palette()
  local selected = require('tatara.config').get().theme
  if selected == 'auto' then
    selected = (vim.g.colors_name or ''):match('catppuccin%-(%w+)')
      or (vim.o.background == 'light' and 'latte' or 'mocha')
  end
  return colors[selected], selected
end
function M.apply(force)
  local p = M.palette()
  if not p then
    for name, link in pairs({
      Text = 'Normal',
      Header = 'Normal',
      Status = 'StatusLine',
      StatusMuted = 'StatusLine',
      Muted = 'Comment',
      Border = 'WinSeparator',
      Focus = 'Special',
      Title = 'Title',
      Path = 'Directory',
      Selected = 'Visual',
      Action = 'Special',
      Editor = 'NormalFloat',
      FloatBorder = 'FloatBorder',
      FloatTitle = 'FloatTitle',
      TreeSelection = 'CursorLine',
      Positive = 'DiagnosticOk',
      Negative = 'DiagnosticError',
      Warning = 'DiagnosticWarn',
    }) do
      vim.api.nvim_set_hl(0, 'Tatara' .. name, { default = not force, link = link })
    end
    return
  end
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  local groups = {
    Text = { fg = p.text, bg = normal.bg },
    Header = { fg = p.text, bg = normal.bg },
    Status = { fg = p.text, bg = p.surface },
    StatusMuted = { fg = p.muted, bg = p.surface },
    Muted = { fg = p.muted, bg = normal.bg },
    Border = { fg = p.border, bg = normal.bg },
    Focus = { fg = p.accent, bg = normal.bg, bold = true },
    Title = { fg = p.text, bg = normal.bg, bold = true },
    Path = { fg = p.blue, bold = true },
    Selected = { fg = p.base, bg = p.accent, bold = true },
    Action = { fg = p.accent, bold = true },
    Editor = { fg = p.text, bg = p.surface },
    FloatBorder = { fg = p.accent, bg = p.surface },
    FloatTitle = { fg = p.accent, bg = p.surface, bold = true },
    TreeSelection = { fg = p.text, bg = p.surface },
    Positive = { fg = p.green },
    Negative = { fg = p.red },
    Warning = { fg = p.peach },
  }
  for name, value in pairs(groups) do
    value.default = not force
    vim.api.nvim_set_hl(0, 'Tatara' .. name, value)
  end
end
return M
