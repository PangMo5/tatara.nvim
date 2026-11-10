-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local api = vim.api
local C = require('tatara.config')
local M = {}
local ns = api.nvim_create_namespace('tatara.sidebar')
local function mark(buf, row, first, last, group)
  if last > first then
    api.nvim_buf_set_extmark(
      buf,
      ns,
      row,
      first,
      { end_col = last, hl_group = group, hl_mode = 'combine', priority = 150 }
    )
  end
end
local function matches(buf, row, text, pattern, group, offset)
  local start = 1
  while true do
    local a, b = text:find(pattern, start)
    if not a then
      break
    end
    mark(buf, row, (offset or 0) + a - 1, (offset or 0) + b, group)
    start = b + 1
  end
end
function M.file(s, row)
  local node = s.rows[row]
  if not node then
    return
  end
  local text = api.nvim_buf_get_lines(s.files_buf, row - 1, row, false)[1]
  if not text then
    return
  end
  api.nvim_buf_clear_namespace(s.files_buf, ns, row - 1, row)
  if node.directory then
    mark(s.files_buf, row - 1, 0, #text, 'TataraPath')
    return
  end
  local first = text:find('%S') or 1
  local status = text:sub(first, first)
  mark(
    s.files_buf,
    row - 1,
    first - 1,
    first,
    status == 'A' and 'TataraPositive' or status == 'D' and 'TataraNegative' or 'TataraWarning'
  )
  local offset = node.stats_offset or #text
  local stats = text:sub(offset + 1)
  matches(s.files_buf, row - 1, stats, '%+%d+', 'TataraPositive', offset)
  matches(s.files_buf, row - 1, stats, '−%d+', 'TataraNegative', offset)
  matches(s.files_buf, row - 1, stats, 'h%d+/%d+', 'TataraPositive', offset)
  matches(s.files_buf, row - 1, stats, 'c%d+', 'DiagnosticHint', offset)
  matches(s.files_buf, row - 1, stats, 'E%d+', 'DiagnosticError', offset)
  matches(s.files_buf, row - 1, stats, 'W%d+', 'DiagnosticWarn', offset)
  matches(s.files_buf, row - 1, stats, '✓', 'TataraPositive', offset)
end
function M.files(s)
  api.nvim_buf_clear_namespace(s.files_buf, ns, 0, -1)
  for row in pairs(s.rows) do
    M.file(s, row)
  end
end
function M.summary(buf, item)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row, text in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if row == 1 then
      mark(buf, row - 1, 0, #text, 'TataraTitle')
      matches(buf, row - 1, text, '^#%d+', 'TataraAction')
    end
    matches(buf, row - 1, text, '@[%w_%-]+', 'TataraPath')
    matches(buf, row - 1, text, '%+%d+', 'TataraPositive')
    matches(buf, row - 1, text, '−%d+', 'TataraNegative')
    if text:find(' → ', 1, true) then
      mark(buf, row - 1, 0, #text, 'TataraPath')
    end
    for key, group in pairs({
      Open = 'TataraPositive',
      Draft = 'TataraWarning',
      Merged = 'TataraAction',
      Closed = 'TataraNegative',
      Approved = 'TataraPositive',
      ['Review required'] = 'TataraWarning',
      ['Changes requested'] = 'TataraNegative',
      Passed = 'TataraPositive',
      Failed = 'TataraNegative',
      Pending = 'TataraWarning',
    }) do
      local label = C.text(key)
      local a, b = text:find(label, 1, true)
      if a then
        mark(buf, row - 1, a - 1, b, group)
      end
    end
    for _, key in ipairs({
      'Files',
      'Comments',
      'Commits',
      'Assignees',
      'Labels',
      'Milestone',
      'Updated',
      'Requested reviewers',
    }) do
      local label = C.text(key)
      if text:sub(1, #label) == label then
        mark(buf, row - 1, 0, #label, 'TataraMuted')
      end
    end
    if text:sub(1, #C.text('Labels')) == C.text('Labels') then
      local start = text:find(': ', 1, true)
      if start then
        mark(buf, row - 1, start + 1, #text, 'TataraAction')
      end
    end
  end
end
return M
