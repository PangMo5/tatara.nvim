-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('tatara.structural-diff')
local gap_ns = api.nvim_create_namespace('tatara.structural-alignment')
local plans = {}
local documents, folds = {}, {}
function M.document(buf)
  return documents[buf]
end
function M.forget(buf)
  documents[buf] = nil
  folds[buf] = nil
end
local function present(x)
  return x ~= nil and x ~= vim.NIL
end
local function changed(line)
  if not present(line) then
    return false
  end
  for _, span in ipairs(line.spans) do
    if span.role == 'added' or span.role == 'removed' then
      return true
    end
  end
  return false
end
function M.highlights()
  for name, link in pairs({ Added = 'diffAdded', Removed = 'diffRemoved' }) do
    local color = api.nvim_get_hl(0, { name = link, link = false }).fg
    if not color then
      color = api.nvim_get_hl(0, { name = name == 'Added' and 'DiagnosticOk' or 'DiagnosticError', link = false }).fg
    end
    for suffix, style in pairs({ [''] = {}, Bold = { bold = true }, Comment = { italic = true } }) do
      api.nvim_set_hl(0, 'Tatara' .. name .. suffix, vim.tbl_extend('force', { default = true, fg = color }, style))
    end
  end
  api.nvim_set_hl(0, 'TataraComment', { default = true, link = 'Comment' })
  api.nvim_set_hl(0, 'TataraPending', { default = true, link = 'DiagnosticHint' })
  api.nvim_set_hl(0, 'TataraPath', { default = true, link = 'Directory' })
end
function M.group(span)
  if span.role ~= 'added' and span.role ~= 'removed' then
    return nil
  end
  return 'Tatara'
    .. (span.role == 'added' and 'Added' or 'Removed')
    .. (span.highlight == 'comment' and 'Comment' or (span.bold and 'Bold' or ''))
end
local function paint(buf, row, offset, spans)
  local column = offset
  local signed = false
  local text = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  for _, span in ipairs(spans) do
    local finish, group = column + #span.text, M.group(span)
    if group and finish > column and column < #text then
      api.nvim_buf_set_extmark(
        buf,
        ns,
        row,
        column,
        { end_col = math.min(finish, #text), hl_group = group, priority = 150, hl_mode = 'combine' }
      )
      if not signed then
        api.nvim_buf_set_extmark(
          buf,
          ns,
          row,
          0,
          { sign_text = span.role == 'added' and '+' or '−', sign_hl_group = group, priority = 5 }
        )
        signed = true
      end
    end
    column = finish
  end
end
function M.clear(buf)
  if buf and api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    folds[buf] = nil
    plans[buf] = nil
    api.nvim_buf_clear_namespace(buf, gap_ns, 0, -1)
  end
end
function M.fold(line)
  return (folds[api.nvim_get_current_buf()] or {})[line] or 0
end
-- Structural alignment is applied as virtual filler and native folds. Real source
-- bytes, line numbers, filetypes and user LSP buffers remain unchanged.
function M.configure_folds(win)
  vim.wo[win].foldmethod = 'expr'
  vim.wo[win].foldexpr = "v:lua.require'tatara.diff'.fold(v:lnum)"
  vim.wo[win].foldenable = require('tatara.config').get().diff.context_folds
end
function M.apply(result, buffers, windows)
  local visible = { LEFT = {}, RIGHT = {} }
  for side, buf in pairs(buffers) do
    M.clear(buf)
    for _, row in ipairs(result.diff.rows) do
      local line = row[side == 'LEFT' and 'left' or 'right']
      if present(line) then
        visible[side][line.number] = true
        paint(buf, line.number - 1, 0, line.spans)
      end
    end
  end
  if result.diff.status == 'changed' then
    assert(present(result.diff.alignment), 'Difftastic did not supply complete source alignment')
    for _, side in ipairs({ 'LEFT', 'RIGHT' }) do
      local buf = buffers[side]
      local levels = {}
      for line = 1, api.nvim_buf_line_count(buf) do
        levels[line] = require('tatara.config').get().diff.context_folds and not visible[side][line] and 1 or 0
      end
      folds[buf] = levels
    end
  end
  local rows = {}
  if present(result.diff.alignment) then
    for _, pair in ipairs(result.diff.alignment) do
      rows[#rows + 1] = pair
    end
  else
    for _, row in ipairs(result.diff.rows) do
      rows[#rows + 1] =
        { present(row.left) and row.left.number or vim.NIL, present(row.right) and row.right.number or vim.NIL }
    end
  end
  plans[buffers.RIGHT] = { rows = rows, buffers = buffers, windows = windows }
  for _, win in ipairs(windows) do
    vim.wo[win].diff = false
    vim.wo[win].wrap = true
    vim.wo[win].scrollbind = true
    vim.wo[win].foldmethod = 'manual'
    api.nvim_win_call(win, function()
      vim.cmd('normal! zE')
    end)
    M.configure_folds(win)
    vim.wo[win].foldlevel = 0
    vim.wo[win].cursorline = win == api.nvim_get_current_win()
  end
  M.reflow(buffers, windows)
end
function M.reflow(buffers, windows)
  local plan = plans[buffers.RIGHT]
  if not plan then
    return
  end
  for i, side in ipairs({ 'LEFT', 'RIGHT' }) do
    if not windows[i] or not api.nvim_win_is_valid(windows[i]) or api.nvim_win_get_buf(windows[i]) ~= buffers[side] then
      return
    end
  end
  for _, side in ipairs({ 'LEFT', 'RIGHT' }) do
    api.nvim_buf_clear_namespace(buffers[side], gap_ns, 0, -1)
  end
  local padding = { LEFT = {}, RIGHT = {} }
  local previous = { 0, 0 }
  for _, pair in ipairs(plan.rows) do
    local heights = { 0, 0 }
    for i, side in ipairs({ 'LEFT', 'RIGHT' }) do
      if present(pair[i]) then
        local h =
          api.nvim_win_text_height(windows[i], { start_row = pair[i] - 1, end_row = pair[i] - 1, start_vcol = 0 })
        heights[i] = h.all - h.fill
        previous[i] = pair[i]
      end
    end
    local height = math.max(heights[1], heights[2])
    for i, side in ipairs({ 'LEFT', 'RIGHT' }) do
      local missing = height - heights[i]
      if missing > 0 then
        padding[side][previous[i]] = (padding[side][previous[i]] or 0) + missing
      end
    end
  end
  for side, rows in pairs(padding) do
    for line, count in pairs(rows) do
      local filler = {}
      for _ = 1, count do
        filler[#filler + 1] = { { '', 'Normal' } }
      end
      api.nvim_buf_set_extmark(
        buffers[side],
        gap_ns,
        math.max(0, line - 1),
        0,
        { virt_lines = filler, virt_lines_above = line == 0 }
      )
    end
  end
end
-- Native scrollbind cannot map different buffer rows through structural virtual
-- filler. Correct its follower viewport using the same immutable alignment, while
-- retaining native motions, folds, window options and the user's scrollbind switch.
function M.sync(buffers, windows, origin)
  local plan = plans[buffers.RIGHT]
  if not plan then
    return
  end
  local from = origin == windows[1] and 1 or origin == windows[2] and 2
  if not from then
    return
  end
  local to = 3 - from
  for i, side in ipairs({ 'LEFT', 'RIGHT' }) do
    if
      not windows[i]
      or not api.nvim_win_is_valid(windows[i])
      or api.nvim_win_get_buf(windows[i]) ~= buffers[side]
      or not vim.wo[windows[i]].scrollbind
    then
      return
    end
  end
  local source, target = windows[from], windows[to]
  local info = vim.fn.getwininfo(source)[1]
  local function viewport(win)
    local view = api.nvim_win_call(win, vim.fn.winsaveview)
    local prefix = api.nvim_win_text_height(win, { end_row = view.topline - 1, end_vcol = 0 }).all
    local skip = view.skipcol > 0
        and api.nvim_win_text_height(win, {
          start_row = view.topline - 1,
          end_row = view.topline - 1,
          start_vcol = 0,
          end_vcol = view.skipcol,
        }).all
      or 0
    return view, prefix - view.topfill + skip
  end
  local source_view, source_top = viewport(source)
  for _, pair in ipairs(plan.rows) do
    if present(pair[from]) and present(pair[to]) and pair[from] >= source_view.topline then
      local a, b = pair[from], pair[to]
      if
        api.nvim_win_call(source, function()
          return vim.fn.foldclosed(a)
        end) == -1
        and api.nvim_win_call(target, function()
          return vim.fn.foldclosed(b)
        end) == -1
      then
        -- screenpos() can still refer to the preceding draw inside WinScrolled.
        -- Read the native topline/topfill/skipcol instead of the last grid.
        local offset = api.nvim_win_text_height(source, { end_row = a - 1, end_vcol = 0 }).all - source_top
        if offset >= 0 and offset < info.height then
          local target_info = vim.fn.getwininfo(target)[1]
          local prefix = api.nvim_win_text_height(target, { end_row = b - 1, end_vcol = 0 }).all
          local target_view, target_top = viewport(target)
          if prefix - target_top == offset then
            return
          end
          local goal = prefix - offset
          if goal < 0 then
            return
          end -- Independently collapsed user folds are kept intact.
          local low, high = 1, api.nvim_buf_line_count(api.nvim_win_get_buf(target))
          while low < high do
            local middle = math.floor((low + high) / 2)
            if api.nvim_win_text_height(target, { end_row = middle - 1 }).all > goal then
              high = middle
            else
              low = middle + 1
            end
          end
          local start = api.nvim_win_text_height(target, { end_row = low - 1, end_vcol = 0 }).all
          local skip = goal > start
              and api.nvim_win_text_height(
                target,
                { start_row = low - 1, end_row = low - 1, start_vcol = 0, max_height = goal - start }
              ).end_vcol
            or 0
          api.nvim_win_call(target, function()
            local view = target_view
            local cursor = api.nvim_win_text_height(target, { end_row = view.lnum - 1, end_vcol = 0 }).all
            local scrolloff = vim.wo[target].scrolloff
            if scrolloff < 0 then
              scrolloff = vim.go.scrolloff
            end
            local margin = math.min(scrolloff, math.floor((target_info.height - 1) / 2))
            if cursor < goal + margin or cursor >= goal + target_info.height - margin then
              -- A follower cursor outside its native scrolloff margin makes
              -- winrestview recenter the viewport and undo the alignment.
              local first, last = 1, api.nvim_buf_line_count(api.nvim_win_get_buf(target))
              local center = goal + math.floor(target_info.height / 2)
              while first < last do
                local middle = math.floor((first + last) / 2)
                if api.nvim_win_text_height(target, { end_row = middle - 1, end_vcol = 0 }).all >= center then
                  last = middle
                else
                  first = middle + 1
                end
              end
              view.lnum, view.col = first, 0
            end
            view.topline, view.topfill, view.skipcol = low, math.max(0, start - goal), skip
            vim.fn.winrestview(view)
          end)
          return
        end
      end
    end
  end
end
function M.projection(results, side_filter)
  local lines, locations, spans, headers, header_paths = {}, {}, {}, {}, {}
  local current_path
  local function append(text, location, tokens)
    lines[#lines + 1] = text
    header_paths[#lines] = current_path
    locations[#lines], spans[#lines] = location, tokens
  end
  if #results == 0 then
    append(require('tatara.config').text('No changes'))
  end
  for _, result in ipairs(results) do
    current_path = result.path
    local title = result.path .. (present(result.previousPath) and (' ← ' .. result.previousPath) or '')
    append(title)
    headers[#lines] = result.path
    if result.error then
      append(result.error)
    elseif result.binary then
      append(require('tatara.config').text('Binary file'))
    elseif #result.diff.rows == 0 then
      append(require('tatara.config').text('No changes'))
    else
      for _, row in ipairs(result.diff.rows) do
        local l, r = row.left, row.right
        if not present(l) and not present(r) then
          append('…')
        else
          local shared = present(l)
            and present(r)
            and not changed(l)
            and not changed(r)
            and vim.deep_equal(l.spans, r.spans)
          for _, side in ipairs(side_filter and { side_filter } or shared and { 'RIGHT' } or { 'LEFT', 'RIGHT' }) do
            local line = row[side == 'LEFT' and 'left' or 'right']
            if present(line) then
              local marker = shared and ' ' or (side == 'LEFT' and '−' or '+')
              local prefix = string.format('%5d %s ', line.number, marker)
              local text = {}
              for _, span in ipairs(line.spans) do
                text[#text + 1] = span.text
              end
              append(prefix .. table.concat(text), {
                path = result.path,
                line = line.number,
                side = side,
                offset = #prefix,
                alternate = not side_filter and shared and { side = 'LEFT', line = l.number } or nil,
              }, line.spans)
            end
          end
        end
      end
    end
    append('')
  end
  return { lines = lines, locations = locations, spans = spans, headers = headers, header_paths = header_paths }
end
function M.align_projections(results, buffers, windows)
  local left, right = M.document(buffers.LEFT), M.document(buffers.RIGHT)
  local indices = { LEFT = {}, RIGHT = {} }
  for side, doc in pairs({ LEFT = left, RIGHT = right }) do
    for row, location in pairs(doc.locations) do
      indices[side][location.path .. ':' .. location.line] = row
    end
  end
  local rows = {}
  for _, result in ipairs(results) do
    for row, path in pairs(left.headers) do
      if path == result.path then
        local other
        for r, p in pairs(right.headers) do
          if p == path then
            other = r
            break
          end
        end
        rows[#rows + 1] = { row, other or vim.NIL }
        break
      end
    end
    if present(result.diff) and #result.diff.rows > 0 then
      local alignment = result.diff.alignment
      if result.diff.status == 'created' or result.diff.status == 'deleted' then
        -- Difftastic's whole-file variants deliberately omit aligned_lines.
        -- Their typed source rows define a unique one-sided alignment.
        alignment = {}
        local created = result.diff.status == 'created'
        for index, row in ipairs(result.diff.rows) do
          local line = row[created and 'right' or 'left']
          assert(
            present(line) and line.number == index and not present(row[created and 'left' or 'right']),
            'Invalid whole-file source coordinates'
          )
          alignment[#alignment + 1] = created and { vim.NIL, line.number } or { line.number, vim.NIL }
        end
      elseif result.diff.status == 'unchanged' then
        alignment = {}
        for _, row in ipairs(result.diff.rows) do
          assert(
            present(row.left) and present(row.right) and row.left.number == row.right.number,
            'Invalid unchanged source coordinates'
          )
          alignment[#alignment + 1] = { row.left.number, row.right.number }
        end
      else
        assert(present(alignment), 'Difftastic must provide complete source alignment')
      end
      for _, pair in ipairs(alignment) do
        local l = present(pair[1]) and indices.LEFT[result.path .. ':' .. pair[1]] or vim.NIL
        local r = present(pair[2]) and indices.RIGHT[result.path .. ':' .. pair[2]] or vim.NIL
        if present(l) or present(r) then
          rows[#rows + 1] = { l, r }
        end
      end
    end
  end
  plans[buffers.RIGHT] = { rows = rows, buffers = buffers, windows = windows }
  M.reflow(buffers, windows)
end
function M.paint_projection(buf, document)
  M.clear(buf)
  documents[buf] = document
  for row, spans in pairs(document.spans) do
    paint(buf, row - 1, document.locations[row].offset, spans)
  end
  for row in pairs(document.headers) do
    api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = 'TataraPath' })
  end
end
return M
