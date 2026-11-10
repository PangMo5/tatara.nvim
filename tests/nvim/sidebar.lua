-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local api, T, D = vim.api, require('tatara'), require('tatara.diff')
local errors = {}
T.setup({
  backend = vim.env.TATARA_TEST_BACKEND or vim.uv.cwd() .. '/.artifacts/products/release-arm64/tatara',
  layout = { stacked_below = 1 },
  reduce_motion = true,
  notify = function(m, l)
    if l == vim.log.levels.ERROR then
      errors[#errors + 1] = m
    end
  end,
})
local function wait(label, fn)
  assert(
    vim.wait(15000, function()
      assert(#errors == 0, table.concat(errors, '\n'))
      return fn()
    end, 10),
    label
  )
end
local function key(lhs)
  assert(vim.fn.maparg(lhs, 'n', false, true).callback)()
end
local function run()
  T.open({ demo = true })
  wait('root', function()
    local w = T.get_context().windows
    return w.left and D.document(api.nvim_win_get_buf(w.right))
  end)
  local w = T.get_context().windows
  local files = api.nvim_win_get_buf(w.files)
  local rows = {}
  for i, line in ipairs(api.nvim_buf_get_lines(files, 0, -1, false)) do
    if line:find('ReviewQueue.swift', 1, true) then
      rows.review = i
    end
    if line:find('Selection.swift', 1, true) then
      rows.selection = i
    end
  end
  local ns = api.nvim_get_namespaces()['tatara.sidebar']
  local groups = {}
  for _, buf in ipairs({ files, api.nvim_win_get_buf(w.summary) }) do
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      groups[mark[4].hl_group] = true
    end
  end
  assert(
    groups.TataraPositive and groups.TataraNegative and groups.TataraPath and groups.TataraWarning,
    'Missing semantic sidebar colors'
  )
  local function select(row)
    api.nvim_set_current_win(w.files)
    api.nvim_win_set_cursor(w.files, { row, 0 })
    api.nvim_exec_autocmds('CursorMoved', { buffer = files })
  end
  select(rows.review)
  select(rows.selection)
  wait('latest focus preview', function()
    local doc = D.document(api.nvim_win_get_buf(T.get_context().windows.right))
    return doc and #doc.results == 1 and doc.results[1].path == 'Sources/Selection.swift'
  end)
  assert(api.nvim_get_current_win() == w.files, 'Preview stole Files focus')
  local selected = api.nvim_win_get_cursor(w.files)
  local function top()
    return api.nvim_win_call(T.get_context().windows.right, vim.fn.winsaveview).topline
  end
  local before = top()
  key('<C-f>')
  assert(top() > before, 'Files Ctrl-f did not page the diff')
  assert(
    api.nvim_get_current_win() == w.files and vim.deep_equal(selected, api.nvim_win_get_cursor(w.files)),
    'Paging moved Files focus/selection'
  )
  key('<C-b>')
  assert(top() <= before, 'Files Ctrl-b did not page back')
  key('<C-d>')
  key('<C-u>')
  assert(api.nvim_get_current_win() == w.files, 'Half-page navigation stole Files focus')
  select(2)
  wait('directory preview', function()
    local doc = D.document(api.nvim_win_get_buf(T.get_context().windows.right))
    return T.get_context().view == 'combined' and doc and #doc.results == 2
  end)
  assert(api.nvim_get_current_win() == w.files, 'Directory preview stole focus')
  select(rows.selection)
  wait('file after directory', function()
    local doc = D.document(api.nvim_win_get_buf(T.get_context().windows.right))
    return doc and #doc.results == 1
  end)
  key('<CR>')
  wait('native source', function()
    return vim.bo.buftype == '' and T.get_context().path == 'Sources/Selection.swift'
  end)
  w = T.get_context().windows
  for _, win in ipairs({ w.left, w.right }) do
    assert(not vim.wo[win].foldenable, 'Review opened folded')
    assert(vim.wo[win].foldexpr == "v:lua.require'tatara.diff'.fold(v:lnum)", 'Tree folding replaced review context')
  end
  key('g]')
  assert(T.get_context().view == 'discussion', 'Next section did not open Discussion')
  key('<LocalLeader>1')
  assert(T.get_context().view == 'overview', 'Overview shortcut did not work')
  T.close()
  print(
    'Neovim sidebar passed: semantic colors, latest cursor preview without focus theft, native Enter, unfolded source and section navigation.'
  )
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cq!')
else
  vim.cmd('qa!')
end
