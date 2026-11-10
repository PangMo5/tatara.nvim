-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local root = vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2)))
local result = vim.system({ 'swift', 'Scripts/Tatara.swift', 'build', 'release' }, { cwd = root, text = true }):wait()
if result.code ~= 0 then
  local output = table.concat({ result.stdout or '', result.stderr or '' }, '\n')
  error('Tatara backend build failed. See :help tatara-install.\n' .. vim.trim(output), 0)
end
