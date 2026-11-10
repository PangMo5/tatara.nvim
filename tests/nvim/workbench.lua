-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Same-task workflow acceptance, not a command-presence checklist.
local api, T, D = vim.api, require('tatara'), require('tatara.diff')
local errors, events = {}, {}
local original = api.nvim_get_current_buf()
api.nvim_buf_set_lines(original, 0, -1, false, { 'Unsaved user work' })
vim.o.cmdheight = 0
local globals = {}
-- cmdheight is tab-local and remains native; only the shared chrome options are leased.
for _, key in ipairs({ 'tabline', 'statusline', 'showtabline', 'laststatus' }) do
  globals[key] = vim.o[key]
end
local function wait(label, test)
  assert(
    vim.wait(15000, function()
      assert(#errors == 0, table.concat(errors, '\n'))
      return test()
    end, 10),
    'Timed out: ' .. label
  )
end
local function text(buf)
  return table.concat(api.nvim_buf_get_lines(buf or 0, 0, -1, false), '\n')
end
local function action(lhs)
  local map = vim.fn.maparg(lhs, 'n', false, true)
  assert(map.callback, 'Missing action ' .. lhs)
  map.callback()
end
local function write(value)
  api.nvim_buf_set_lines(0, 0, -1, false, { value })
  vim.cmd.stopinsert()
  vim.cmd.write()
end
local function escape()
  vim.cmd.stopinsert()
  action('<Esc>')
end
api.nvim_create_autocmd('User', {
  pattern = 'Tatara*',
  callback = function(event)
    events[event.match] = event.data
  end,
})
api.nvim_create_autocmd('FileType', {
  pattern = 'markdown',
  callback = function(event)
    vim.keymap.set('i', '<C-s>', function() end, { buffer = event.buf, desc = 'User completion key' })
    vim.keymap.set('n', 'q', function() end, { buffer = event.buf, desc = 'User macro key' })
  end,
})
T.setup({
  backend = vim.env.TATARA_TEST_BACKEND or vim.uv.cwd() .. '/.artifacts/products/release-arm64/tatara',
  layout = { stacked_below = 1 },
  reduce_motion = true,
  notify = function(message, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = message
    end
  end,
  select = function(items, opts, done)
    assert(opts.kind == 'tatara.reactions', 'Core flow fell back to a selector: ' .. opts.kind)
    done(items[6], 6)
  end,
})
local function run()
  T.open({ demo = true })
  assert(vim.o.cmdheight == 0, 'Review replaced the native command-line layout')
  wait('paired combined source', function()
    local w = T.get_context().windows
    return events.TataraReady
      and w.left
      and D.document(api.nvim_win_get_buf(w.left))
      and D.document(api.nvim_win_get_buf(w.right))
  end)
  local w = T.get_context().windows
  assert(
    vim.o.tabline:find('Overview', 1, true) and vim.o.tabline:find('Discussion', 1, true),
    'Content sections are not visible'
  )
  assert(vim.o.statusline:find('Comment', 1, true), 'Contextual actions are not visible')
  for _, side in ipairs({ 'LEFT', 'RIGHT' }) do
    local doc = D.document(api.nvim_win_get_buf(side == 'LEFT' and w.left or w.right))
    local originals = {}
    for _, r in ipairs(doc.results) do
      originals[r.path] = vim.split(side == 'LEFT' and r.before or r.after, '\n', { plain = true })
    end
    for row, p in pairs(doc.locations) do
      assert(
        p.side == side and doc.lines[row]:sub(p.offset + 1) == originals[p.path][p.line],
        'Source text/identity disagree'
      )
      assert(not p.alternate, 'Paired source aliases the other buffer; aliases belong only to unified rows')
    end
  end
  api.nvim_set_current_win(w.right)
  vim.cmd('wincmd h')
  assert(api.nvim_get_current_win() == w.left, 'Window navigation is not native')
  T.open_file('Sources/ReviewQueue.swift', { line = 5, side = 'RIGHT', native = true })
  wait('native source', function()
    return vim.bo.buftype == '' and T.get_context().path == 'Sources/ReviewQueue.swift'
  end)
  local source, source_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  assert(
    vim.fn.maparg('<Tab>', 'n', false, true).desc ~= 'Tatara: next_pane',
    'Pane mapping replaced the terminal Ctrl-i jumplist key'
  )
  local files = T.get_context().windows.files
  api.nvim_win_set_width(files, 26)
  api.nvim_exec_autocmds('WinResized', {})
  assert(api.nvim_win_get_width(files) == 26, 'Workspace fought a native window resize')
  T.comment()
  assert(vim.fn.maparg('<C-s>', 'i', false, true).desc == 'User completion key', 'Composer replaced Insert completion')
  assert(vim.fn.maparg('q', 'n', false, true).desc == 'User macro key', 'Composer replaced native macro recording')
  local cfg = api.nvim_win_get_config(0)
  assert(
    cfg.relative == 'win' and cfg.win == source_win and vim.bo.buftype == 'acwrite',
    'Comment editor is not anchored to the real source'
  )
  local hidden_editor = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(hidden_editor, 0, -1, false, { 'Body preserved through native window close' })
  vim.cmd.stopinsert()
  api.nvim_win_close(api.nvim_get_current_win(), false)
  wait('native composer close', function()
    return not api.nvim_buf_is_valid(hidden_editor)
  end)
  T.comment()
  assert(text() == 'Body preserved through native window close', 'Native window close lost the composer body')
  local background_editor = api.nvim_get_current_buf()
  T.review()
  wait('explicit review from composer', function()
    return not api.nvim_buf_is_valid(background_editor)
      and vim.bo.buftype == 'acwrite'
      and vim.b.tatara_dialog.title == 'Finish review'
  end)
  escape()
  wait('source after explicit review', function()
    return api.nvim_get_current_buf() == source
  end)
  T.comment()
  assert(text() == 'Body preserved through native window close', 'View change lost the composer body')
  write('Local draft from the inline editor')
  wait('direct save', function()
    return events.TataraDraftChanged and events.TataraDraftChanged.count == 1
  end)
  assert(api.nvim_get_current_buf() == source, 'Save did not return to source')
  assert(api.nvim_win_get_width(files) == 26, 'State update reset the user window size')
  api.nvim_win_close(files, false)
  T.mark_reviewed()
  assert(not api.nvim_win_is_valid(files), 'State update reopened a user-closed pane')
  T.command({ fargs = { 'files' } })
  assert(api.nvim_win_is_valid(T.get_context().windows.files), 'Explicit Files navigation did not restore the pane')
  api.nvim_set_current_win(source_win)
  T.open_file('Sources/Selection.swift', { line = 5, side = 'RIGHT', native = true })
  wait('other file', function()
    return T.get_context().path == 'Sources/Selection.swift' and vim.bo.buftype == ''
  end)
  for name, ns in pairs(api.nvim_get_namespaces()) do
    if name:match('^tatara%.conversations%.') then
      assert(#api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 0, 'A conversation leaked into another file')
    end
  end
  T.open_file('Sources/ReviewQueue.swift', { line = 5, side = 'RIGHT', native = true })
  wait('return to commented file', function()
    return api.nvim_get_current_buf() == source
  end)
  T.comment()
  api.nvim_buf_set_lines(0, 0, -1, false, { 'Single comment alongside a draft' })
  T.post_comment()
  wait('single preview', function()
    return text():find('This will be posted to GitHub.', 1, true)
  end)
  assert(
    text():find('Single comment alongside a draft', 1, true)
      and not text():find('Local draft from the inline editor', 1, true)
  )
  escape()
  wait('source after cancel', function()
    return api.nvim_get_current_buf() == source
  end)
  T.review()
  assert(vim.fn.maparg('<C-s>', 'i', false, true).desc == 'User completion key', 'Review replaced Insert completion')
  local summary = api.nvim_get_current_buf()
  assert(
    vim.bo.buftype == 'acwrite' and #api.nvim_tabpage_list_wins(0) >= 4,
    'R did not open the integrated review workspace'
  )
  vim.cmd.stopinsert()
  action('g2')
  assert(vim.wo.winbar:find('TataraSelected# Approve', 1, true), 'Selected event is not visible')
  write('A native review summary')
  wait('review preview', function()
    return text():find('This will be posted to GitHub.', 1, true)
  end)
  assert(text():find('APPROVE', 1, true) and text():find('Local draft from the inline editor', 1, true))
  escape()
  assert(api.nvim_get_current_buf() == summary and text() == 'A native review summary', 'Back lost the editing buffer')
  T.drafts()
  action('<CR>')
  wait('draft editor', function()
    return vim.bo.buftype == 'acwrite' and text():find('Local draft', 1, true)
  end)
  write('Edited inline draft')
  wait('draft editor closed', function()
    return vim.bo.buftype ~= 'acwrite'
  end)
  T.drafts()
  action('d')
  wait('last draft removed', function()
    return events.TataraDraftChanged.count == 0
  end)
  api.nvim_set_current_win(T.get_context().windows.right)
  escape()
  wait('return to source', function()
    return api.nvim_get_current_buf() == source
  end)
  T.filters()
  wait('filter editor', function()
    return vim.bo.buftype == 'acwrite'
  end)
  local query = api.nvim_get_current_buf()
  assert(vim.b[query].tatara_dialog.title == 'GitHub search query', 'Query is hidden in a menu')
  api.nvim_buf_set_lines(query, 0, -1, false, { 'is:open' })
  vim.cmd.stopinsert()
  local labels
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if vim.wo[win].winbar:find('Labels', 1, true) then
      labels = win
    end
  end
  assert(labels, 'Labels are not visible with presets and query')
  api.nvim_set_current_win(labels)
  api.nvim_win_set_cursor(labels, { 2, 0 })
  action('<CR>')
  wait('quoted label', function()
    return text(query):find('label:"needs review"', 1, true)
  end)
  api.nvim_set_current_win(T.get_context().windows.right)
  vim.cmd.write()
  wait('selection workspace', function()
    return vim.bo.filetype == 'tatara'
  end)
  assert(T.get_context().windows.files and T.get_context().windows.right, 'Selector has no preview split')
  T.list({ query = '' })
  wait('list ready', function()
    local selection = T.get_context().selection
    return selection and selection.query == '' and not selection.loading and text():find('#42', 1, true)
  end)
  action('L')
  wait('more PRs', function()
    return text():find('#44', 1, true)
  end)
  action('j')
  wait('selected preview', function()
    return text(api.nvim_win_get_buf(T.get_context().windows.right)):find('Keep review drafts', 1, true)
  end)
  assert(T.get_context().number == 42, 'Preview movement changed review ownership')
  action('<CR>')
  wait('accepted PR', function()
    return T.get_context().number == 44
  end)
  T.close()
  assert(text(original) == 'Unsaved user work' and vim.bo[original].modified, 'User work changed')
  for key, value in pairs(globals) do
    assert(vim.o[key] == value, 'Global UI option leaked: ' .. key)
  end
  print(
    'Workbench acceptance passed: visible sections, native splits, paired source identity, anchored editing, direct draft/single flow, integrated review/filters, preview ownership and restoration; no forge writes.'
  )
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cq!')
else
  vim.cmd('qa!')
end
