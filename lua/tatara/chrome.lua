-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local api = vim.api
local C = require('tatara.config')
local M = { sessions = {}, tabs = {}, actions = {} }
local saved
local function valid(win)
  return win and api.nvim_win_is_valid(win)
end
local function escape(text)
  return tostring(text or ''):gsub('%%', '%%%%')
end
local function fit(text, width)
  if width <= 0 then
    return ''
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local low, high = 0, vim.fn.strchars(text)
  local ellipsis = vim.fn.strdisplaywidth('…') <= width and '…' or '.'
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, middle)) + vim.fn.strdisplaywidth(ellipsis) <= width then
      low = middle
    else
      high = middle - 1
    end
  end
  return vim.fn.strcharpart(text, 0, low) .. ellipsis
end
local function put(buf, lines)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
end
local function buffer(name)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, name)
  vim.bo[buf].bufhidden = 'wipe'
  return buf
end
function M.highlights()
  require('tatara.theme').apply()
  for name, link in pairs({
    Border = 'Comment',
    Focus = 'Special',
    Title = 'Title',
    Muted = 'Comment',
    Selected = 'Visual',
    Action = 'Special',
    Text = 'Normal',
    Path = 'Directory',
  }) do
    api.nvim_set_hl(0, 'Tatara' .. name, { default = true, link = link })
  end
end
local function acquire()
  if saved then
    return
  end
  saved = {}
  for key, value in pairs({
    showtabline = 2,
    tabline = '',
    laststatus = 3,
    statusline = '',
    showmode = false,
    showcmd = false,
    ruler = false,
  }) do
    saved[key] = vim.o[key]
    vim.o[key] = value
  end
end
local function release()
  if not saved then
    return
  end
  for key, value in pairs(saved) do
    vim.o[key] = value
  end
  saved = nil
end
local function header(win, title, trailing, focused, formatted)
  local width = api.nvim_win_get_width(win)
  local right = trailing ~= '' and width >= 48 and (' ' .. escape(trailing) .. ' ') or ''
  if
    formatted
    and api.nvim_eval_statusline(formatted, { winid = win, maxwidth = 10000 }).width
        + vim.fn.strdisplaywidth(trailing)
        + 3
      > width
  then
    right = ''
  end
  local line = '%#'
    .. (focused and 'TataraFocus' or 'TataraMuted')
    .. '# %<'
    .. (formatted or escape(title))
    .. '%#TataraHeader#%=%#TataraMuted#'
    .. right
    .. '%*'
  if vim.wo[win].winbar ~= line then
    vim.wo[win].winbar = line
  end
end
local function style(win, editor)
  api.nvim_win_call(win, function()
    vim.opt_local.fillchars:append({
      eob = ' ',
      vert = '│',
      horiz = '─',
      horizup = '┴',
      horizdown = '┬',
      vertleft = '┤',
      vertright = '├',
      verthoriz = '┼',
    })
    vim.opt_local.winhl:append({
      Normal = editor and 'TataraEditor' or 'TataraText',
      NormalNC = editor and 'TataraEditor' or 'TataraText',
      WinBar = 'TataraHeader',
      WinBarNC = 'TataraHeader',
      StatusLine = 'TataraStatus',
      StatusLineNC = 'TataraStatus',
      WinSeparator = 'TataraBorder',
      VertSplit = 'TataraBorder',
    })
  end)
  -- A statuscolumn is a source gutter, not the missing side of a drawn frame.
  if not vim.wo[win].number then
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].statuscolumn = ''
    vim.wo[win].foldcolumn = '0'
  end
end
local function tabline(s)
  local repository = (s.repository or ''):gsub('^github.com/', '')
  local title = '%#TataraTitle# tatara%#TataraHeader# · %<' .. escape(repository)
  if s.opts.demo and vim.o.columns >= 120 then
    title = title .. ' %#TataraMuted#' .. escape(C.text('DEMO · synthetic data')) .. '%#TataraHeader#'
  end
  local current = s:current_view()
  local items = {}
  for index, item in ipairs(s:views()) do
    M.actions[index] = function()
      if s.writing then
        return
      end
      if s.inline_editor and api.nvim_buf_is_valid(s.inline_editor.buf) then
        s.inline_editor.close()
        s.inline_editor = nil
      end
      if item[1] == 'diff' then
        s:diff_view()
      else
        s[item[1]](s)
      end
    end
    items[#items + 1] = '%'
      .. index
      .. '@v:lua.__tatara_view_click@%#'
      .. (item[1] == current and 'TataraSelected' or 'TataraMuted')
      .. '# '
      .. escape(C.text(item[2]))
      .. ' %#TataraHeader#%X'
  end
  return title
    .. '%#TataraHeader#%='
    .. table.concat(items, ' ')
    .. (s.opts.local_base and '  ' or ('  #' .. (s.detail and s.detail.item.id.number or '')))
    .. ' '
end
_G.__tatara_view_click = function(id)
  local f = M.actions[id]
  if f then
    f()
  end
end
local function hints(s)
  local buf = api.nvim_get_current_buf()
  local role = vim.b[buf].tatara_dialog
  if role then
    return role.hints or ''
  end
  if s.mode == 'list' then
    return 'j/k · '
      .. C.text('Move')
      .. '   Enter · '
      .. C.text('Open')
      .. '   / · '
      .. C.text('Search')
      .. '   f · '
      .. C.text('Filters and presets')
      .. '   L · '
      .. C.text('Load more')
  end
  local keys = C.get().keymaps
  local entries = {
    { 'comment', 'Comment' },
    { 'review', s.opts.local_base and 'Local comments' or 'Finish review' },
    { 'grep', 'Search file contents' },
    { 'comments', 'Comments' },
  }
  if not s.opts.local_base then
    table.insert(entries, 3, { 'pick', 'Select a pull request' })
  end
  local text = {}
  for _, entry in ipairs(entries) do
    if keys[entry[1]] then
      text[#text + 1] = keys[entry[1]] .. ' · ' .. C.text(entry[2])
    end
  end
  text[#text + 1] = '<C-w> · ' .. C.text('Move')
  local navigation = keys.previous_view and keys.next_view and (keys.previous_view .. '/' .. keys.next_view .. '   ')
    or ''
  return navigation .. table.concat(text, '   ')
end
function M.refresh(s, bars)
  if s.closed or api.nvim_get_current_tabpage() ~= s.tab then
    return
  end
  acquire()
  local line = tabline(s)
  if vim.o.tabline ~= line then
    vim.o.tabline = line
  end
  local current = api.nvim_get_current_win()
  if bars then
    if valid(s.summary_win) then
      style(s.summary_win)
      header(
        s.summary_win,
        s:summary_title() .. (s.opts.local_base and '' or (' · ' .. (C.get().keymaps.pick or ''))),
        '',
        current == s.summary_win
      )
    end
    if valid(s.files_win) then
      style(s.files_win)
      header(
        s.files_win,
        C.text(s.mode == 'list' and 'Pull requests' or 'Files')
          .. ' · '
          .. (
            s.mode == 'list' and #(s.items or {})
            or s.detail and ((s.visible_file_count or #s.detail.files) .. '/' .. #s.detail.files)
            or 0
          ),
        '',
        current == s.files_win
      )
    end
    for side, win in pairs({ LEFT = s.left_win, RIGHT = s.right_win }) do
      if valid(win) and api.nvim_win_get_config(win).relative == '' then
        local dialog = vim.b[api.nvim_win_get_buf(win)].tatara_dialog
        style(win, s.form and api.nvim_win_get_buf(win) == s.form.buf)
        local content_title = s.content_titles and s.content_titles[side] or s.content_title
        local title = dialog and dialog.title or content_title or C.text('Diff')
        if s.mode == 'diff' and s.path then
          title = s.path .. ' · ' .. side
        elseif s.mode == 'source' then
          local buf = api.nvim_win_get_buf(win)
          local source = vim.b[buf].tatara or s.extra_sources[buf]
          title = source and source.path or vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ':~:.')
        end
        if dialog then
          title = dialog.title
        elseif s.mode == 'overview' then
          title = C.text('Overview')
        elseif s.mode == 'checks' then
          title = C.text('Checks')
        elseif s.mode == 'discussion' then
          title = C.text('Discussion')
        elseif s.mode == 'saved_reviews' then
          title = C.text('Saved reviews')
        elseif (s.mode == 'combined' or s.mode == 'unified') and valid(s.left_win) then
          title = title .. ' · ' .. side
        end
        local formatted
        local path_title = s.mode == 'diff' and s.path
          or ((s.mode == 'combined' or s.mode == 'unified') and content_title ~= C.text('Diff') and content_title)
        if path_title and not dialog then
          formatted = '%#TataraPath#' .. escape(path_title)
          if valid(s.left_win) then
            formatted = formatted .. '%#' .. (win == current and 'TataraFocus' or 'TataraMuted') .. '# · ' .. side
          end
        end
        if not s.opts.local_base and s.form and s.form.kind == 'review' and api.nvim_win_get_buf(win) == s.form.buf then
          local parts = { escape(C.text('Finish review')) .. ' · ' }
          for index, event in ipairs({ 'Comment', 'Approve', 'Request changes' }) do
            M.actions[100 + index] = function()
              if s.form and s.form.set_event then
                s.form.set_event(index)
              end
            end
            parts[#parts + 1] = '%'
              .. (100 + index)
              .. '@v:lua.__tatara_view_click@%#'
              .. (s.form.event == index and 'TataraSelected' or 'TataraMuted')
              .. '# '
              .. escape(C.text(event))
              .. ' %*%X'
          end
          formatted = table.concat(parts, ' ')
          title = C.text('Finish review') .. ' · Comment Approve Request changes'
        end
        header(win, title, side == 'RIGHT' and s:revision().head:sub(1, 8) or '', win == current, formatted)
      end
    end
    for win, panel in pairs(s.chrome_panels or {}) do
      if valid(win) and api.nvim_win_get_buf(win) == panel.buf then
        style(win)
        header(win, panel.title, panel.trailing or '', win == current)
      else
        s.chrome_panels[win] = nil
      end
    end
  end
  local source = s:context()
  local mode = vim.fn.mode():match('^[i]') and 'Insert' or vim.fn.mode():match('^[vV]') and 'Visual' or 'Normal'
  local label = C.text(mode)
  if source.reviewable then
    label = label .. ' · ' .. source.side .. ' · ' .. source.line .. ':' .. (source.column + 1)
  end
  local status = next(s.rpc.pending) and (s.status or C.text('Loading…')) or C.text('Ready')
  status = fit(status, math.max(12, math.floor(vim.o.columns / 3)))
  local hint = fit(hints(s), vim.o.columns - vim.fn.strdisplaywidth(label) - vim.fn.strdisplaywidth(status) - 6)
  local text = '%#TataraStatus# '
    .. escape(label)
    .. '   %#TataraStatusMuted#'
    .. escape(hint)
    .. '%=%#TataraStatus# '
    .. escape(status)
    .. ' '
  vim.go.statusline = text
  -- With laststatus=3, a window-local value still overrides the global option.
  -- Child splits and a user's statusline provider must not leave stale footers.
  for _, win in ipairs(api.nvim_tabpage_list_wins(s.tab)) do
    if api.nvim_win_get_config(win).relative == '' then
      vim.wo[win].statusline = text
    end
  end
end
function M.panel(s, win, title, hints, trailing)
  s.chrome_panels = s.chrome_panels or {}
  local buf = api.nvim_win_get_buf(win)
  s.chrome_panels[win] = { buf = buf, title = title, trailing = trailing }
  vim.b[buf].tatara_dialog = { title = title, hints = hints }
  M.refresh(s, true)
end
function M.attach(s)
  M.sessions[s.tab] = s
  M.highlights()
  api.nvim_create_autocmd('ColorScheme', {
    group = s.group,
    callback = function()
      M.highlights()
      M.refresh(s, true)
    end,
  })
  api.nvim_create_autocmd({ 'WinEnter', 'CursorMoved', 'ModeChanged', 'VimResized', 'WinResized', 'User' }, {
    group = s.group,
    callback = function(event)
      if event.event == 'User' and not (event.match or ''):match('^Tatara') then
        return
      end
      if not s.closed and api.nvim_get_current_tabpage() == s.tab then
        M.refresh(s, event.event ~= 'CursorMoved' and event.event ~= 'ModeChanged')
      end
    end,
  })
  api.nvim_create_autocmd('TabLeave', {
    group = s.group,
    callback = function()
      if api.nvim_get_current_tabpage() == s.tab then
        release()
      end
    end,
  })
  api.nvim_create_autocmd('TabEnter', {
    group = s.group,
    callback = function()
      if not s.closed and api.nvim_get_current_tabpage() == s.tab then
        M.refresh(s, true)
      end
    end,
  })
end
function M.close(s)
  if s.toast_timer then
    s.toast_timer:stop()
    s.toast_timer:close()
    s.toast_timer = nil
  end
  if valid(s.toast_win) then
    api.nvim_win_close(s.toast_win, true)
    s.toast_win = nil
  end
  M.sessions[s.tab] = nil
  if next(M.sessions) == nil then
    M.actions = {}
  end
  if api.nvim_get_current_tabpage() == s.tab then
    release()
  end
end
function M.notify(s, message, level)
  s.notification_history = s.notification_history or {}
  s.notification_history[#s.notification_history + 1] = { message = tostring(message):sub(1, 8192), level = level }
  if #s.notification_history > 32 then
    table.remove(s.notification_history, 1)
  end
  if valid(s.toast_win) then
    api.nvim_win_close(s.toast_win, true)
  end
  if s.toast_timer then
    s.toast_timer:stop()
    s.toast_timer:close()
  end
  local text = vim.split(tostring(message), '\n', { plain = true })
  local lines = {}
  for i = 1, math.min(3, #text) do
    lines[#lines + 1] = vim.fn.strcharpart(text[i], 0, 70)
  end
  lines[#lines + 1] = '! · ' .. C.text('Details')
  local width = math.max(20, math.min(74, math.floor(vim.o.columns * 0.6)))
  local buf = buffer('tatara://' .. s.id .. '/notification/' .. vim.uv.hrtime())
  put(buf, lines)
  s.toast_win = api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = math.max(1, vim.o.lines - #lines - 4),
    col = math.max(0, vim.o.columns - width - 3),
    width = width,
    height = #lines,
    focusable = false,
    mouse = false,
    style = 'minimal',
    border = vim.o.winborder ~= '' and vim.o.winborder or 'rounded',
    title = level >= vim.log.levels.ERROR and C.text('Error') or 'Tatara',
    zindex = 80,
  })
  vim.wo[s.toast_win].winhl = 'Normal:TataraEditor,FloatBorder:TataraFloatBorder,FloatTitle:TataraFloatTitle'
  s.toast_timer = vim.defer_fn(function()
    if valid(s.toast_win) then
      api.nvim_win_close(s.toast_win, true)
      s.toast_win = nil
    end
    s.toast_timer = nil
  end, 5000)
end
return M
