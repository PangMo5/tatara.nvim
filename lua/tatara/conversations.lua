-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local api = vim.api
local M = {}
local function known(x)
  return x ~= nil and x ~= vim.NIL
end
local function wrap(text, width)
  local lines = {}
  for source in (text .. '\n'):gmatch('(.-)\n') do
    source = source:gsub('^#+%s*', ''):gsub('%*%*', ''):gsub('`', '')
    if source ~= '' then
      local line = ''
      for _, char in ipairs(vim.fn.split(source, '\zs')) do
        if vim.fn.strdisplaywidth(line .. char) > width then
          lines[#lines + 1] = line
          line = ''
        end
        line = line .. char
        if #lines >= 7 then
          return lines
        end
      end
      lines[#lines + 1] = line
    elseif #lines > 0 then
      lines[#lines + 1] = ''
    end
    if #lines >= 7 then
      break
    end
  end
  return lines
end
function M.paint(s, results, buffers, projections)
  s.conversation_ns = s.conversation_ns or api.nvim_create_namespace('tatara.conversations.' .. s.id)
  local map, headers, opposite = { LEFT = {}, RIGHT = {} }, { LEFT = {}, RIGHT = {} }, { LEFT = {}, RIGHT = {} }
  local allowed = {}
  for _, result in ipairs(results) do
    allowed[result.path] = true
  end
  for side, buf in pairs(buffers) do
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_clear_namespace(buf, s.conversation_ns, 0, -1)
    end
    if projections then
      local doc = require('tatara.diff').document(buf)
      for row, location in pairs(doc.locations) do
        map[location.side][location.path .. ':' .. location.line] = { buf = buf, row = row }
        if location.alternate then
          map[location.alternate.side][location.path .. ':' .. location.alternate.line] = { buf = buf, row = row }
        end
      end
      for row, path in pairs(doc.headers) do
        headers[side][path] = { buf = buf, row = row }
        if not buffers.LEFT then
          headers.LEFT[path] = { buf = buf, row = row }
        end
      end
    else
      for _, result in ipairs(results) do
        headers[side][result.path] = { buf = buf, row = 0 }
      end
    end
  end
  for _, result in ipairs(results) do
    local previous = { 0, 0 }
    for _, pair in ipairs(known(result.diff) and known(result.diff.alignment) and result.diff.alignment or {}) do
      for i = 1, 2 do
        if known(pair[i]) then
          previous[i] = pair[i]
        end
      end
      for i, side in ipairs({ 'LEFT', 'RIGHT' }) do
        if known(pair[i]) then
          opposite[side][result.path .. ':' .. pair[i]] = previous[i == 1 and 2 or 1]
        end
      end
    end
  end
  local rows = {}
  local function append(target, lines)
    if not target or not target.buf then
      return
    end
    rows[target.buf] = rows[target.buf] or {}
    rows[target.buf][target.row] = rows[target.buf][target.row] or {}
    vim.list_extend(rows[target.buf][target.row], lines)
  end
  local function add(path, side, line, title, body, pending, outdated)
    if not allowed[path] then
      return
    end
    local target
    if projections then
      target = map[side][path .. ':' .. tostring(line)]
    elseif buffers[side] and known(line) then
      target = { buf = buffers[side], row = line }
    end
    if outdated or not target then
      target = headers[side][path]
    end
    if not target then
      return
    end
    local win = s.right_win
    if buffers.LEFT and target.buf == buffers.LEFT then
      win = s.left_win
    end
    local width = math.max(16, (win and api.nvim_win_is_valid(win) and api.nvim_win_get_width(win) or 60) - 8)
    local lines =
      { { { '  │ ' .. title, pending and 'TataraPending' or 'DiagnosticHint' } }, { { '  │', 'TataraBorder' } } }
    for _, text in ipairs(wrap(body:sub(1, 1400), width)) do
      lines[#lines + 1] = { { '  │ ', 'TataraBorder' }, { text, 'TataraText' } }
    end
    lines[#lines + 1] = { { '  │', 'TataraBorder' } }
    lines[#lines + 1] = { { '', 'Normal' } }
    append(target, lines)
    if buffers.LEFT and buffers.RIGHT and buffers.LEFT ~= buffers.RIGHT then
      local other = side == 'LEFT' and 'RIGHT' or 'LEFT'
      local n = opposite[side][path .. ':' .. tostring(line)] or 0
      local counterpart
      if projections then
        counterpart = map[other][path .. ':' .. n] or headers[other][path]
      else
        counterpart = { buf = buffers[other], row = n }
      end
      local blank = {}
      for _ = 1, #lines do
        blank[#blank + 1] = { { '', 'Normal' } }
      end
      append(counterpart, blank)
    end
  end
  for _, item in ipairs(s.draft) do
    add(
      item.path,
      item.side,
      item.line,
      require('tatara.config').text('Pending review') .. ' · ' .. item.side .. ':' .. item.line,
      item.body,
      true,
      false
    )
  end
  for _, item in ipairs(s.detail.comments) do
    local a = item.anchor
    if known(a) and a.subjectType == 'file' then
      add(
        a.path,
        'RIGHT',
        nil,
        '@' .. item.author .. ' · ' .. require('tatara.config').text('File comment'),
        item.body,
        false,
        true
      )
    elseif known(a) and known(a.side) then
      local old = not known(a.line)
      add(
        a.path,
        a.side,
        known(a.line) and a.line or 1,
        '@'
          .. item.author
          .. ' · '
          .. a.side
          .. ':'
          .. (known(a.line) and a.line or a.originalLine or '—')
          .. (old and (' · ' .. require('tatara.config').text('Outdated')) or ''),
        item.body,
        false,
        old
      )
    end
  end
  for buf, entries in pairs(rows) do
    local count = api.nvim_buf_line_count(buf)
    for row, lines in pairs(entries) do
      api.nvim_buf_set_extmark(
        buf,
        s.conversation_ns,
        math.max(0, math.min(count, row) - 1),
        0,
        { virt_lines = lines, virt_lines_above = row == 0, virt_lines_leftcol = true }
      )
    end
  end
end
return M
