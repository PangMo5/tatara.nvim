-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local api, T, D = vim.api, require('tatara'), require('tatara.diff')
local errors, events = {}, {}
T.setup({
  backend = vim.env.TATARA_TEST_BACKEND or vim.uv.cwd() .. '/.artifacts/products/release-arm64/tatara',
  layout = { stacked_below = 1 },
  reduce_motion = true,
  notify = function(message, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = message
    end
  end,
})
api.nvim_create_autocmd('User', {
  pattern = 'Tatara*',
  callback = function(event)
    events[event.match] = event.data
  end,
})
local function wait(label, condition)
  assert(
    vim.wait(15000, function()
      assert(#errors == 0, table.concat(errors, '\n'))
      return condition()
    end, 10),
    label
  )
end
local function text(buf)
  return table.concat(api.nvim_buf_get_lines(buf or 0, 0, -1, false), '\n')
end
local function key(lhs, mode)
  local map = vim.fn.maparg(lhs, mode or 'n', false, true)
  assert(map.callback, 'Missing mapping: ' .. lhs)()
end
local function escape()
  vim.cmd.stopinsert()
  key('<Esc>')
end
local function run()
  T.open({ demo = true })
  wait('ready', function()
    return events.TataraReady and T.get_context().view == 'combined'
  end)
  T.open_file('Sources/ReviewQueue.swift', { side = 'RIGHT', line = 5, native = true })
  wait('source', function()
    return T.get_context().view == 'diff' and vim.bo.buftype == ''
  end)
  local source, original = api.nvim_get_current_buf(), text()
  key('gH')
  wait('hunk reviewed', function()
    return text(api.nvim_win_get_buf(T.get_context().windows.files)):find('h1/1', 1, true)
  end)
  T.mark_reviewed()
  wait('file reviewed', function()
    return text(api.nvim_win_get_buf(T.get_context().windows.files)):find('✓', 1, true)
  end)
  assert(T.set_file_filter({ hide_reviewed = true }))
  wait('reviewed file hidden from continuous diff', function()
    local doc = D.document(api.nvim_win_get_buf(T.get_context().windows.right))
    return doc and #doc.results == 1 and doc.results[1].path == 'Sources/Selection.swift'
  end)
  assert(not text(api.nvim_win_get_buf(T.get_context().windows.files)):find('ReviewQueue.swift', 1, true))
  assert(T.set_file_filter({ hide_reviewed = false, include = 'Selection', exclude = '' }))
  wait('one filtered file', function()
    local doc = D.document(api.nvim_win_get_buf(T.get_context().windows.right))
    return doc and #doc.results == 1
  end)
  assert(T.set_file_filter({ include = '', exclude = '.' }))
  wait('empty filtered projection', function()
    local doc = D.document(api.nvim_win_get_buf(T.get_context().windows.right))
    return doc and #doc.results == 0
  end)
  T.grep('plain', 'guard')
  wait('empty scoped content search', function()
    return vim.bo.buftype == 'quickfix' and #vim.fn.getloclist(T.get_context().windows.right) == 0
  end)
  vim.cmd.lclose()
  assert(T.set_file_filter({ include = '', exclude = '' }))
  T.open_file('Sources/ReviewQueue.swift', { side = 'RIGHT', line = 5, native = true })
  wait('return to source', function()
    return api.nvim_get_current_buf() == source
  end)
  T.suggest({ start_line = 5, end_line = 6 })
  assert(text():find('```suggestion\n    guard files.indices.contains(index + 1)', 1, true))
  assert(text():find('    return files[index + 1]\n```', 1, true))
  vim.cmd.stopinsert()
  vim.cmd.write()
  wait('saved suggestion', function()
    return events.TataraDraftChanged and events.TataraDraftChanged.count == 1
  end)
  assert(text(source) == original and not vim.bo[source].modifiable and vim.bo[source].readonly)
  assert(T.get_context().line == 5, 'Saving a suggestion moved the source cursor')
  for row = 1, api.nvim_buf_line_count(source) do
    assert(vim.fn.foldclosed(row) == -1, 'Comment interaction hid source rows')
  end
  T.review()
  vim.cmd.stopinsert()
  api.nvim_buf_set_lines(0, 0, -1, false, { 'Saved summary for the exact revision' })
  key('g2')
  vim.cmd.write()
  wait('review preview', function()
    return text():find('APPROVE', 1, true) and text():find('Saved summary', 1, true)
  end)
  escape()
  escape()
  T.command({ fargs = { '44' } })
  wait('other PR', function()
    return T.get_context().number == 44
  end)
  T.command({ fargs = { '42' } })
  wait('restored PR', function()
    return T.get_context().number == 42 and T.get_context().view == 'combined'
  end)
  assert(text(api.nvim_win_get_buf(T.get_context().windows.files)):find('h1/1', 1, true))
  T.review()
  assert(text():find('Saved summary for the exact revision', 1, true))
  assert(vim.wo.winbar:find('TataraSelected# Approve', 1, true))
  escape()
  T.file_comment('Sources/Selection.swift')
  assert(vim.b.tatara_dialog.title:find('File comment', 1, true))
  api.nvim_buf_set_lines(0, 0, -1, false, { 'A comment about the entire file' })
  vim.cmd.stopinsert()
  vim.cmd.write()
  wait('file comment preview', function()
    return text():find('File comment · Sources/Selection.swift', 1, true)
      and text():find('A comment about the entire file', 1, true)
  end)
  escape()
  T.export_review('json')
  wait('JSON export', function()
    return vim.bo.filetype == 'json'
  end)
  local exported = vim.json.decode(text())
  assert(exported.schema == 1 and exported.identity.head == T.get_context().head)
  assert(#exported.review.drafts == 1 and exported.review.summary == 'Saved summary for the exact revision')
  assert(vim.bo.buftype == '', 'Export must support native :write')
  local filename = vim.fn.tempname() .. '.json'
  vim.cmd.write(vim.fn.fnameescape(filename))
  assert(vim.fn.readfile(filename)[1] == text())
  vim.fn.delete(filename)
  local export_buf, export_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  api.nvim_win_close(export_win, false)
  api.nvim_buf_delete(export_buf, { force = false })
  T.saved_reviews()
  wait('saved review workspace', function()
    return T.get_context().view == 'saved_reviews'
  end)
  assert(text():find('Saved reviews', 1, true) and text():find('Saved summary', 1, true))
  T.diff_view()
  wait('diff after saved reviews', function()
    return T.get_context().view == 'combined' or T.get_context().view == 'diff'
  end)
  T.close()
  print(
    'Neovim review workflow passed: durable drafts/summary/progress, filtered projections, immutable suggestions, file-comment preview, native JSON export and saved-review workspace; no forge writes.'
  )
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd.cquit(1)
end
vim.cmd.qa({ bang = true })
