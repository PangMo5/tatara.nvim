-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local api, D = vim.api, require('tatara.diff')
local cases = {
  { path = 'asset.bin', binary = true, diff = vim.NIL },
  { path = 'new.txt', previousPath = 'old.txt', diff = { status = 'unchanged', rows = {}, alignment = vim.NIL } },
  { path = 'unavailable.txt', error = 'Immutable source could not be read.', diff = vim.NIL },
}
local function run()
  D.highlights()
  local buffers, windows = {}, {}
  for _, side in ipairs({ 'LEFT', 'RIGHT' }) do
    local doc = D.projection(cases, side)
    assert(next(doc.locations) == nil, 'Non-source rows acquired review anchors')
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, doc.lines)
    buffers[side] = buf
    windows[side] = side == 'LEFT' and api.nvim_get_current_win()
      or api.nvim_open_win(buf, false, { split = 'right', win = windows.LEFT })
    api.nvim_win_set_buf(windows[side], buf)
    D.paint_projection(buf, doc)
    local text = table.concat(doc.lines, '\n')
    assert(
      text:find('Binary file', 1, true)
        and text:find('new.txt ← old.txt', 1, true)
        and text:find(cases[3].error, 1, true),
      'Projection hid non-source file context'
    )
  end
  D.align_projections(cases, buffers, { windows.LEFT, windows.RIGHT })
  local function line(number, text, role)
    return { number = number, spans = { { text = text, role = role } } }
  end
  local variants = {
    {
      path = 'modified.swift',
      diff = {
        status = 'changed',
        alignment = { { 1, 1 } },
        rows = {
          { left = line(1, 'let old = 1', 'removed'), right = line(1, 'let new = 2', 'added') },
        },
      },
    },
    {
      path = 'created.swift',
      diff = {
        status = 'created',
        alignment = vim.NIL,
        rows = {
          { left = vim.NIL, right = line(1, 'let 새파일 = 1', 'added') },
          { left = vim.NIL, right = line(2, '', 'added') },
        },
      },
    },
    {
      path = 'deleted.swift',
      diff = {
        status = 'deleted',
        alignment = vim.NIL,
        rows = {
          { left = line(1, 'let old = 1', 'removed'), right = vim.NIL },
        },
      },
    },
    {
      path = 'unchanged.swift',
      diff = {
        status = 'unchanged',
        alignment = vim.NIL,
        rows = {
          { left = line(8, 'let same = 1', 'unchanged'), right = line(8, 'let same = 1', 'unchanged') },
        },
      },
    },
  }
  -- Repeatedly replace the actual paired preview, just as rapid Files movement does.
  for iteration = 1, 16 do
    local result = variants[(iteration - 1) % #variants + 1]
    for _, side in ipairs({ 'LEFT', 'RIGHT' }) do
      local doc = D.projection({ result }, side)
      api.nvim_buf_set_lines(buffers[side], 0, -1, false, doc.lines)
      D.paint_projection(buffers[side], doc)
      for _, p in pairs(doc.locations) do
        assert(p.path == result.path, 'Preview retained a previous file identity')
      end
    end
    D.align_projections({ result }, buffers, { windows.LEFT, windows.RIGHT })
  end
  local invalid = {
    path = 'invalid.swift',
    diff = {
      status = 'changed',
      alignment = vim.NIL,
      rows = {
        { left = line(1, 'a', 'removed'), right = line(1, 'b', 'added') },
      },
    },
  }
  assert(
    not pcall(D.align_projections, { invalid }, buffers, { windows.LEFT, windows.RIGHT }),
    'Missing modified-file alignment was silently accepted'
  )
  for _, side in ipairs({ 'LEFT', 'RIGHT' }) do
    local doc = D.projection(cases, side)
    api.nvim_buf_set_lines(buffers[side], 0, -1, false, doc.lines)
    D.paint_projection(buffers[side], doc)
  end
  require('tatara.conversations').paint({
    id = 'projection-test',
    left_win = windows.LEFT,
    right_win = windows.RIGHT,
    draft = {},
    detail = {
      comments = {
        {
          author = 'reviewer',
          body = 'File-wide feedback',
          anchor = { path = 'asset.bin', subjectType = 'file', line = vim.NIL, side = vim.NIL },
        },
      },
    },
  }, cases, buffers, true)
  local ns = api.nvim_get_namespaces()['tatara.conversations.projection-test']
  local found = false
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buffers.RIGHT, ns, 0, -1, { details = true })) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(line) do
        if chunk[1]:find('File comment', 1, true) then
          found = true
        end
      end
    end
  end
  assert(
    found and next(D.document(buffers.RIGHT).locations) == nil,
    'File comment lost its header or acquired a fabricated source line'
  )
  print(
    'Neovim projection passed: non-source cases, 16 created/deleted/modified/unchanged preview transitions and rejection of invalid changed alignment.'
  )
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cq!')
else
  vim.cmd('qa!')
end
