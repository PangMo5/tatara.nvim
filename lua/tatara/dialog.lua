-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local api = vim.api
local M = {}
local function valid(win)
  return win and api.nvim_win_is_valid(win)
end
function M.open(s, buf, title, placement, on_closed)
  local saved_heights = {}
  local parent = placement and (placement.parent or s.right_win)
  local parent_buf = valid(parent) and api.nvim_win_get_buf(parent)
  local parent_cursor = valid(parent) and api.nvim_win_get_cursor(parent)
  local parent_view = valid(parent) and api.nvim_win_call(parent, vim.fn.winsaveview)
  local source_navigated = false
  local resolved_doc = parent_buf and require('tatara.diff').document(parent_buf)
  local generation = s.file_generation
  local group = api.nvim_create_augroup('TataraDialog' .. s.id .. vim.uv.hrtime(), { clear = true })
  local disposed, pending = false, false
  local initial = true
  local function resolve_anchor()
    if not parent then
      return true
    end
    if not valid(parent) or generation ~= s.file_generation then
      return false
    end
    local current = api.nvim_win_get_buf(parent)
    if not placement.source then
      return current == parent_buf
    end
    local source = placement.source
    local doc = require('tatara.diff').document(current)
    local row
    if doc and doc.head == source.head and doc.merge_base == source.merge_base then
      for index, location in pairs(doc.locations) do
        local alternate = location.alternate
        if
          location.path == source.path
          and (
            (location.side == source.side and location.line == source.line)
            or (alternate and alternate.side == source.side and alternate.line == source.line)
          )
        then
          row = index
          break
        end
      end
    elseif current == parent_buf then
      row = source.line
    end
    if not row or row > api.nvim_buf_line_count(current) then
      return false
    end
    if placement.anchor ~= row or resolved_doc ~= doc then
      placement.anchor = row
      resolved_doc = doc
      if placement.on_anchor_changed then
        placement.on_anchor_changed(current, row)
      end
    end
    return true
  end
  local function geometry()
    local border = vim.o.winborder ~= '' and vim.o.winborder or 'rounded'
    local options = {
      relative = 'editor',
      anchor = 'NW',
      row = math.floor(vim.o.lines * 0.18),
      col = math.floor(vim.o.columns * 0.15),
      width = math.max(16, math.floor(vim.o.columns * 0.7)),
      height = math.max(3, math.floor(vim.o.lines * 0.6)),
      style = 'minimal',
      border = border,
    }
    if border ~= 'none' then
      options.title = title
    end
    if valid(parent) then
      if placement.spanning and valid(s.left_win) and valid(s.right_win) then
        local l, r = api.nvim_win_get_position(s.left_win), api.nvim_win_get_position(s.right_win)
        if l[2] == r[2] then
          local other = parent == s.left_win and s.right_win or s.left_win
          if not saved_heights[other] then
            saved_heights[other] = api.nvim_win_get_height(other)
          end
          if api.nvim_win_get_height(other) ~= 1 then
            api.nvim_win_set_height(other, 1)
          end
        end
      end
      local height = api.nvim_win_get_height(parent)
      options.relative, options.win, options.col = 'win', parent, 0
      options.width = math.max(16, api.nvim_win_get_width(parent) - 2)
      if placement.spanning and valid(s.left_win) and valid(s.right_win) then
        local l, r = api.nvim_win_get_position(s.left_win), api.nvim_win_get_position(s.right_win)
        local start = math.min(l[2], r[2])
        local finish = math.max(l[2] + api.nvim_win_get_width(s.left_win), r[2] + api.nvim_win_get_width(s.right_win))
        options.width = math.max(16, finish - start - 2)
        options.col = start - api.nvim_win_get_position(parent)[2]
      end
      options.height = math.max(3, math.min(12, height - 3))
      if placement.anchor then
        if initial and api.nvim_win_get_cursor(parent)[1] == placement.anchor then
          api.nvim_win_call(parent, function()
            vim.cmd(vim.wo[parent].foldenable and 'normal! zvzt' or 'normal! zt')
          end)
        end
        -- Measure the finalized native viewport. Buffer-relative floats are
        -- clamped back over the anchor when virtual lines or scrolloff move it.
        vim.cmd.redraw()
        local h = api.nvim_win_text_height(
          parent,
          { start_row = placement.anchor - 1, end_row = placement.anchor - 1, start_vcol = 0 }
        )
        local position = vim.fn.screenpos(parent, placement.anchor, 1)
        local parent_top = api.nvim_win_get_position(parent)[1]
        local top = parent_top + 1
        if placement.spanning and valid(s.left_win) and valid(s.right_win) then
          top = math.min(api.nvim_win_get_position(s.left_win)[1], api.nvim_win_get_position(s.right_win)[1])
        end
        local border_height = border == 'none' and 0 or 2
        local bottom = math.min(parent_top + height, vim.o.lines - math.max(1, vim.o.cmdheight) - 1)
        local source_top = position.row - 1
        local source_bottom = source_top + h.all - h.fill
        local below = bottom - source_bottom - border_height - 2
        local above = source_top - top - border_height - 1
        if below >= 3 or below >= above then
          options.height = math.max(1, math.min(12, below))
          options.row = source_bottom + 1 - parent_top
        else
          options.height = math.max(1, math.min(12, above))
          options.row = source_top - options.height - border_height - 1 - parent_top
        end
      else
        options.row = math.max(0, height - options.height - 2)
      end
      options.footer, options.footer_pos = placement.footer, 'left'
    end
    return options
  end
  local win = api.nvim_open_win(buf, true, geometry())
  initial = false
  vim.w[win].tatara_anchor = placement and placement.anchor and { win = parent, row = placement.anchor } or nil
  vim.wo[win].winhl =
    'Normal:TataraEditor,FloatBorder:TataraFloatBorder,FloatTitle:TataraFloatTitle,FloatFooter:TataraFloatTitle,WinBar:TataraEditor,WinBarNC:TataraEditor'
  local function reflow()
    if pending or disposed then
      return
    end
    pending = true
    vim.schedule(function()
      pending = false
      if not disposed and valid(win) then
        if not resolve_anchor() then
          on_closed()
          return
        end
        api.nvim_win_set_config(win, geometry())
        vim.w[win].tatara_anchor = placement and placement.anchor and { win = parent, row = placement.anchor } or nil
        require('tatara.chrome').refresh(s, true)
      end
    end)
  end
  api.nvim_create_autocmd(
    { 'VimResized', 'WinResized', 'WinScrolled', 'BufWinEnter' },
    { group = group, callback = reflow }
  )
  api.nvim_create_autocmd('User', { group = group, pattern = 'Tatara*', callback = reflow })
  api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      if valid(win) and api.nvim_get_current_win() == parent then
        source_navigated = true
      end
    end,
  })
  -- Opening a focused float runs the user's WinLeave/folding handlers. Resolve
  -- the anchor again against that resulting viewport, without changing its view.
  reflow()
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        if not disposed then
          on_closed()
        end
      end)
    end,
  })
  local function dispose()
    if disposed then
      return
    end
    disposed = true
    local restore_source = valid(parent)
      and api.nvim_win_get_buf(parent) == parent_buf
      and generation == s.file_generation
    local cursor = restore_source and (source_navigated and api.nvim_win_get_cursor(parent) or parent_cursor)
    local view = restore_source and (source_navigated and api.nvim_win_call(parent, vim.fn.winsaveview) or parent_view)
    api.nvim_del_augroup_by_id(group)
    for other, height in pairs(saved_heights) do
      if
        valid(other)
        and valid(parent)
        and api.nvim_win_get_position(other)[2] == api.nvim_win_get_position(parent)[2]
      then
        api.nvim_win_set_height(other, height)
      end
    end
    if restore_source then
      api.nvim_win_set_cursor(parent, cursor)
      api.nvim_win_call(parent, function()
        vim.fn.winrestview(view)
      end)
    end
  end
  return win, dispose
end
return M
