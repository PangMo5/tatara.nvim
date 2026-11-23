-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local api = vim.api
local C = require('tatara.config')
local M = {}
local function valid(win)
  return win and api.nvim_win_is_valid(win)
end
local function put(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
end
function M.origin(s)
  local win = api.nvim_get_current_win() == s.left_win and s.left_win or s.right_win
  local source = valid(win) and api.nvim_win_call(win, function()
    return s:context()
  end) or {}
  return {
    mode = s.mode,
    path = s.path,
    target = { path = source.path, side = source.side, line = source.line, column = source.column, native = true },
    head = s:revision().head,
    mergeBase = s:revision().mergeBase,
  }
end
function M.restore(s, origin)
  if s.closed then
    return
  end
  if origin.head ~= s:revision().head or origin.mergeBase ~= s:revision().mergeBase then
    s:overview()
  elseif origin.mode == 'combined' then
    s:combined()
  elseif origin.path and (origin.mode == 'diff' or origin.mode == 'unified' or origin.mode == 'source') then
    s:open_file(origin.path, origin.target)
  elseif origin.mode == 'checks' then
    s:checks()
  elseif origin.mode == 'discussion' then
    s:discussion()
  else
    s:overview()
  end
end
function M.open(s, kind, title, body, key, save)
  if s.form then
    M.close(s, false)
  end
  local origin = M.origin(s)
  s:cancel_files()
  if valid(s.left_win) then
    s:close_content_window(s.left_win, true)
    s.left_win = nil
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, 'tatara://' .. s.id .. '/' .. kind)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  local cache = s:revision().head .. ':' .. s.detail.item.id.number .. ':' .. key
  put(buf, vim.split(s.composer_drafts[cache] or body or '', '\n', { plain = true }))
  local form = {
    buf = buf,
    kind = kind,
    origin = origin,
    cache = cache,
    windows = {},
    title = title,
    head = s:revision().head,
    mergeBase = s:revision().mergeBase,
    number = s.detail.item.id.number,
  }
  s.form = form
  s.mode = kind
  vim.b[buf].tatara_dialog = {
    title = title,
    hints = ':write · ' .. C.text('Preview') .. '   <C-w> · ' .. C.text('Move') .. '   Esc · ' .. C.text('Back'),
  }
  s.applying_file = true
  api.nvim_win_set_buf(s.right_win, buf)
  s.applying_file = false
  vim.wo[s.right_win].number = false
  vim.wo[s.right_win].relativenumber = false
  vim.wo[s.right_win].wrap = true
  vim.wo[s.right_win].scrollbind = false
  vim.wo[s.right_win].foldmethod = 'manual'
  local function capture()
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    local bytes, count = #text, 0
    for id, value in pairs(s.composer_drafts) do
      if id ~= cache then
        bytes = bytes + #value
        count = count + 1
      end
    end
    assert(bytes <= 8 * 1024 * 1024 and count < 128, 'Composer drafts exceed their session limit')
    s.composer_drafts[cache] = text
    vim.bo[buf].modified = false
    return text
  end
  form.capture = capture
  api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      save(capture(), form)
    end,
  })
  vim.keymap.set('n', '<C-s>', function()
    vim.cmd.stopinsert()
    vim.cmd.write()
  end, { buffer = buf, desc = 'Tatara: preview review' })
  vim.keymap.set('n', '<Esc>', function()
    M.close(s, true)
  end, { buffer = buf, desc = 'Tatara: return to source' })
  api.nvim_set_current_win(s.right_win)
  s:layout()
  require('tatara.chrome').refresh(s, true)
  return form
end
function M.suspend(s)
  if not s.form then
    return
  end
  s.form.capture()
  for _, win in pairs(s.form.windows) do
    if valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  s.form.windows = {}
end
function M.resume(s)
  local form = s.form
  if not form or not api.nvim_buf_is_valid(form.buf) then
    return
  end
  api.nvim_win_set_buf(s.right_win, form.buf)
  api.nvim_set_current_win(s.right_win)
  s.mode = form.kind
  if form.render then
    form.render()
  end
  require('tatara.chrome').refresh(s, true)
end
function M.close(s, restore)
  local form = s.form
  if not form then
    return
  end
  if api.nvim_buf_is_valid(form.buf) then
    form.capture()
  end
  M.suspend(s)
  s.form = nil
  for _, key in ipairs({ 'list_buf', 'presets_buf', 'labels_buf' }) do
    local buf = form[key]
    if buf and api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
      api.nvim_buf_delete(buf, {})
    end
  end
  if api.nvim_buf_is_valid(form.buf) then
    vim.bo[form.buf].bufhidden = 'wipe'
  end
  if restore then
    M.restore(s, form.origin)
  end
  if api.nvim_buf_is_valid(form.buf) and #vim.fn.win_findbuf(form.buf) == 0 then
    api.nvim_buf_delete(form.buf, {})
  end
end
function M.preview(s, lines, title, on_back)
  local form = s.form
  local origin = not form and M.origin(s)
  if form then
    M.suspend(s)
  end
  if valid(s.left_win) then
    s:close_content_window(s.left_win, true)
    s.left_win = nil
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, 'tatara://' .. s.id .. '/write-preview/' .. vim.uv.hrtime())
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  put(buf, lines)
  vim.bo[buf].modifiable = false
  vim.b[buf].tatara_dialog =
    { title = title, hints = 'Enter · ' .. C.text('Confirm') .. '   Esc · ' .. C.text('Edit') }
  s.applying_file = true
  api.nvim_win_set_buf(s.right_win, buf)
  s.applying_file = false
  require('tatara.prose').render(buf, s.right_win)
  s.mode = 'preview'
  api.nvim_set_current_win(s.right_win)
  vim.wo[s.right_win].wrap = true
  vim.wo[s.right_win].number = false
  local function close(success)
    if success then
      if s.form then
        M.close(s, false)
      end
      M.restore(s, form and form.origin or origin)
    elseif on_back then
      on_back()
    elseif s.form then
      M.resume(s)
    else
      M.restore(s, origin)
    end
    if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
      api.nvim_buf_delete(buf, {})
    end
  end
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, function()
      close(false)
    end, { buffer = buf })
  end
  s:layout()
  require('tatara.chrome').refresh(s, true)
  return buf, s.right_win, close
end
return M
