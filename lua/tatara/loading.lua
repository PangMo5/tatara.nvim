-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- The original Tatara forge artwork, rendered in an owned non-focusable window.
local M = {}
local api = vim.api
local frames
local angles = { -140, -140, -158, -177, -181, -181, -162, -148 }
local function make(frame)
  local p = {}
  local function pixel(x, y, ink)
    if x >= 0 and x < 34 and y >= 0 and y < 28 then
      p[y * 34 + x] = ink
    end
  end
  local function polygon(v, ink)
    for y = 0, 27 do
      for x = 0, 33 do
        local inside = false
        local prev = v[#v]
        for _, cur in ipairs(v) do
          if
            (cur[2] > y + 0.5) ~= (prev[2] > y + 0.5)
            and x + 0.5 < (prev[1] - cur[1]) * (y + 0.5 - cur[2]) / (prev[2] - cur[2]) + cur[1]
          then
            inside = not inside
          end
          prev = cur
        end
        if inside then
          pixel(x, y, ink)
        end
      end
    end
  end
  local function rect(x, y, w, h, ink, clip)
    for r = y, y + h - 1 do
      for c = x, x + w - 1 do
        if not clip or p[r * 34 + c] then
          pixel(c, r, ink)
        end
      end
    end
  end
  polygon({
    { 1, 18 },
    { 8, 16 },
    { 9, 15 },
    { 29, 15 },
    { 31, 17 },
    { 28, 20 },
    { 22, 21 },
    { 22, 23 },
    { 27, 24 },
    { 28, 27 },
    { 9, 27 },
    { 10, 25 },
    { 15, 23 },
    { 14, 21 },
    { 8, 21 },
    { 5, 20 },
  }, 'steel')
  rect(8, 15, 23, 1, 'edge', true)
  rect(3, 19, 27, 1, 'shadow', true)
  rect(16, 21, 6, 3, 'shadow', true)
  rect(10, 25, 17, 1, 'edge', true)
  rect(9, 26, 20, 1, 'shadow', true)
  rect(13, 13, 8, 2, 'wood')
  rect(14, 13, 6, 1, 'heat')
  local angle = angles[frame] * math.pi / 180
  local dx, dy = math.cos(angle), math.sin(angle)
  local hx, hy = 26 + dx * 10, 9.5 + dy * 10
  local steps = math.ceil(math.max(math.abs(26 - hx), math.abs(9.5 - hy)) * 2)
  for i = 0, steps do
    rect(math.floor(hx + (26 - hx) * i / steps + 0.5), math.floor(hy + (9.5 - hy) * i / steps + 0.5), 2, 2, 'wood')
  end
  local corners = {}
  for _, point in ipairs({ { -3.5, -1.5 }, { 3.5, -1.5 }, { 3.5, 1.5 }, { -3.5, 1.5 } }) do
    corners[#corners + 1] = { hx - dy * point[1] + dx * point[2], hy + dx * point[1] + dy * point[2] }
  end
  polygon(corners, 'head')
  if frame == 5 or frame == 6 then
    for _, v in
      ipairs(
        frame == 5 and { { 11, 11 }, { 13, 9 }, { 22, 10 }, { 24, 13 } }
          or { { 8, 9 }, { 12, 6 }, { 25, 7 }, { 28, 12 } }
      )
    do
      pixel(v[1], v[2], 'spark')
    end
  end
  local rows = {}
  for y = 0, 26, 2 do
    local row = {}
    for x = 0, 33 do
      local top, bottom = p[y * 34 + x], p[(y + 1) * 34 + x]
      row[#row + 1] = {
        text = top and (bottom and (top == bottom and '█' or '▀') or '▀') or (bottom and '▄' or ' '),
        fg = top or bottom,
        bg = top and bottom and top ~= bottom and bottom or nil,
      }
    end
    rows[#rows + 1] = row
  end
  return rows
end
function M.refresh(s)
  if s.closed then
    return M.close(s)
  end
  local busy = s.rpc and next(s.rpc.pending) ~= nil
  if not busy then
    return M.close(s)
  end
  if not s.loading_timer and not require('tatara.config').get().reduce_motion then
    s.loading_timer = vim.uv.new_timer()
    s.loading_timer:start(
      150,
      150,
      vim.schedule_wrap(function()
        if s.closed then
          M.close(s)
          return
        end
        s.loading_frame = ((s.loading_frame or 0) + 1) % 8
        M.draw(s)
        require('tatara.chrome').refresh(s, false)
      end)
    )
  end
  M.draw(s)
end
function M.draw(s)
  if
    s.detail
    or not s.right_win
    or not api.nvim_win_is_valid(s.right_win)
    or api.nvim_get_current_tabpage() ~= s.tab
  then
    return
  end
  local width, height = api.nvim_win_get_width(s.right_win), api.nvim_win_get_height(s.right_win)
  if width < 36 or height < 18 then
    return
  end
  if not s.loading_win or not api.nvim_win_is_valid(s.loading_win) then
    s.loading_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(s.loading_buf, 'tatara://' .. s.id .. '/forge-loading')
    vim.bo[s.loading_buf].bufhidden = 'wipe'
    s.loading_win = api.nvim_open_win(s.loading_buf, false, {
      relative = 'win',
      win = s.right_win,
      row = math.floor((height - 17) / 2),
      col = math.floor((width - 34) / 2),
      width = 34,
      height = 17,
      focusable = false,
      mouse = false,
      style = 'minimal',
      zindex = 40,
    })
  end
  frames = frames or {}
  local index = (s.loading_frame or 0) + 1
  frames[index] = frames[index] or make(index)
  local lines = { '           t a t a r a', '' }
  for _, row in ipairs(frames[index]) do
    local text = {}
    for _, g in ipairs(row) do
      text[#text + 1] = g.text
    end
    lines[#lines + 1] = table.concat(text)
  end
  lines[#lines + 1] = require('tatara.config').text('Loading…')
  api.nvim_buf_set_lines(s.loading_buf, 0, -1, false, lines)
  local ns = api.nvim_create_namespace('tatara.forge-art')
  api.nvim_buf_clear_namespace(s.loading_buf, ns, 0, -1)
  local palette = require('tatara.theme').palette()
  local colors = {
    steel = '#9399b2',
    edge = palette and palette.text or '#bac2de',
    shadow = palette and palette.surface or '#585b70',
    wood = palette and palette.peach or '#fab387',
    head = palette and palette.text or '#cdd6f4',
    heat = '#f9e2af',
    spark = '#f5e0dc',
  }
  for y, row in ipairs(frames[index]) do
    for x, g in ipairs(row) do
      if g.fg then
        local name = 'TataraForge_' .. g.fg .. '_' .. (g.bg or 'none')
        api.nvim_set_hl(0, name, { fg = colors[g.fg], bg = g.bg and colors[g.bg] or nil })
        local first
        -- All artwork glyphs are one cell; UTF-8 byte positions remain explicit.
        local before = {}
        for n = 1, x - 1 do
          before[#before + 1] = row[n].text
        end
        first = #table.concat(before)
        api.nvim_buf_set_extmark(s.loading_buf, ns, y + 1, first, { end_col = first + #g.text, hl_group = name })
      end
    end
  end
end
function M.close(s)
  if s.loading_timer then
    s.loading_timer:stop()
    s.loading_timer:close()
    s.loading_timer = nil
  end
  if s.loading_win and api.nvim_win_is_valid(s.loading_win) then
    api.nvim_win_close(s.loading_win, true)
  end
  s.loading_win = nil
end
return M
