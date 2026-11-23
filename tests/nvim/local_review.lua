-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local api, T = vim.api, require('tatara')
local root = vim.fn.tempname()
local repo = root .. '/repo'
vim.fn.mkdir(repo, 'p')
vim.env.XDG_DATA_HOME = root .. '/data'
local events, errors, clipboard = {}, {}, nil
vim.keymap.set('n', '<C-x>', '<Cmd>close<CR>')
T.setup({
  backend = vim.env.TATARA_TEST_BACKEND,
  language = 'en',
  layout = { stacked_below = 1 },
  reduce_motion = true,
  notify = function(message, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = message
    end
  end,
})
vim.g.clipboard = {
  name = 'Tatara local review fixture',
  copy = {
    ['+'] = function(lines)
      clipboard = table.concat(lines, '\n')
    end,
  },
  paste = {
    ['+'] = function()
      return { vim.split(clipboard or '', '\n', { plain = true }), 'v' }
    end,
  },
  cache_enabled = 0,
}
api.nvim_create_autocmd('User', {
  pattern = 'Tatara*',
  callback = function(event)
    events[event.match] = event.data
  end,
})
local function wait(label, predicate)
  assert(
    vim.wait(15000, function()
      assert(#errors == 0, table.concat(errors, '\n'))
      return predicate()
    end, 10),
    label
  )
end
local function git(...)
  local args = { 'git', '-C', repo, '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false' }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function key(lhs)
  assert(vim.fn.maparg(lhs, 'n', false, true).callback, 'Missing mapping: ' .. lhs)()
end
local function open(revision, flag)
  events.TataraReady = nil
  vim.cmd('Tatara local base' .. (flag and (' ' .. flag) or ''))
  wait('Open local comparison', function()
    return events.TataraReady and T.get_context().view == 'combined'
  end)
  local context = T.get_context()
  assert(context.kind == 'localComparison' and (not revision or context.head == revision))
  return context
end
local function contents(path)
  local file = assert(io.open(path, 'rb'))
  local data = file:read('*a')
  file:close()
  return data
end
local function close_content(side)
  local previous = T.get_context().windows[side]
  local buffer = api.nvim_win_get_buf(previous)
  local cursor = api.nvim_win_get_cursor(previous)
  local wrap = vim.wo[previous].wrap
  api.nvim_set_current_win(previous)
  api.nvim_feedkeys(vim.keycode('<C-x>'), 'mx', false)
  wait('Keep the closed diff pane visible', function()
    local win = T.get_context().windows[side]
    return win ~= previous and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buffer
  end)
  local win = T.get_context().windows[side]
  assert(vim.deep_equal(api.nvim_win_get_cursor(win), cursor) and vim.wo[win].wrap == wrap)
  assert(api.nvim_get_current_win() == win)
end
local function run()
  git('init', '-q', '-b', 'base')
  git('config', 'user.name', 'Tatara fixture')
  git('config', 'user.email', 'tatara@localhost')
  local before = { 'first', 'old value', 'third', 'fourth', 'fifth', 'sixth', 'seventh' }
  vim.fn.writefile(before, repo .. '/before [brackets].txt')
  git('add', '.')
  git('commit', '-qm', 'Common ancestor')
  local merge_base = git('rev-parse', 'HEAD')
  git('switch', '-qc', 'feature')
  git('mv', 'before [brackets].txt', 'after name.txt')
  local after = vim.deepcopy(before)
  after[2] = 'new value'
  vim.fn.writefile(after, repo .. '/after name.txt')
  vim.fn.writefile({ 'committed only' }, repo .. '/committed.txt')
  git('add', '.')
  git('commit', '-qm', 'Local rename')
  local head = git('rev-parse', 'HEAD')
  git('switch', '-q', 'base')
  vim.fn.writefile({ 'base branch only' }, repo .. '/base.txt')
  git('add', '.')
  git('commit', '-qm', 'Advance base separately')
  git('switch', '-q', 'feature')
  vim.fn.writefile({ 'unsaved working tree version' }, repo .. '/after name.txt')
  vim.cmd.cd(vim.fn.fnameescape(repo))
  local context = open(head, '--no-worktree')
  assert(context.merge_base == merge_base)
  local paths = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(context.windows.files), 0, -1, false), '\n')
  assert(paths:find('after name.txt', 1, true) and not paths:find('base.txt', 1, true), paths)
  close_content('right')
  close_content('left')
  local pair = T.get_context().windows
  local left, right = api.nvim_win_get_buf(pair.left), api.nvim_win_get_buf(pair.right)
  api.nvim_set_current_win(pair.files)
  vim.cmd.only()
  wait('Keep both diff panes after :only', function()
    local windows = T.get_context().windows
    return api.nvim_win_is_valid(windows.left)
      and api.nvim_win_is_valid(windows.right)
      and api.nvim_win_get_buf(windows.left) == left
      and api.nvim_win_get_buf(windows.right) == right
  end)
  assert(api.nvim_get_current_win() == pair.files)
  T.open_file('after name.txt', { side = 'LEFT', line = 2, native = true })
  wait('Open immutable source', function()
    return T.get_context().view == 'diff' and vim.bo.buftype == ''
  end)
  assert(T.get_context().side == 'LEFT' and vim.bo.readonly)
  assert(api.nvim_get_current_line() == 'old value')
  assert(not vim.startswith(api.nvim_buf_get_name(0), repo .. '/'))
  close_content('left')
  vim.cmd('1,2Tatara comment')
  assert(vim.b.tatara_dialog.title == 'Local comments')
  api.nvim_buf_set_lines(0, 0, -1, false, { 'Keep this invariant when renaming.' })
  vim.cmd.write()
  wait('Save a range comment', function()
    return events.TataraDraftChanged and events.TataraDraftChanged.count == 1
  end)
  T.close()
  open(head, '--no-worktree')
  vim.cmd('Tatara drafts')
  assert(not T.get_context().windows.left, 'Opening the drafts form left an unwanted diff split')
  assert(api.nvim_get_current_line():find('Keep this invariant when renaming.', 1, true))
  key('y')
  wait('Copy local review', function()
    return clipboard ~= nil
  end)
  assert(clipboard:find(head, 1, true) and clipboard:find(merge_base, 1, true), clipboard)
  assert(clipboard:find('before [brackets].txt:1-2', 1, true), clipboard)
  assert(clipboard:find('Renamed to', 1, true) and clipboard:find('LEFT (merge base)', 1, true), clipboard)
  assert(clipboard:find('Keep this invariant when renaming.', 1, true), clipboard)
  T.close()
  assert(vim.fn.readfile(repo .. '/after name.txt')[1] == 'unsaved working tree version')

  vim.fn.writefile({ 'ignored.txt', 'staged.txt' }, repo .. '/.git/info/exclude', 'a')
  vim.fn.writefile({ 'staged only' }, repo .. '/staged.txt')
  vim.fn.writefile({ 'staged version' }, repo .. '/mixed.txt')
  git('add', '-f', 'staged.txt', 'mixed.txt')
  vim.fn.writefile({ 'working tree version' }, repo .. '/mixed.txt')
  vim.fn.writefile({ 'new file' }, repo .. '/untracked.txt')
  local long_line = ('a'):rep(511) .. '한' .. ('b'):rep(10000)
  vim.fn.writefile({ long_line }, repo .. '/long.txt')
  vim.fn.writefile({ 'ignored file' }, repo .. '/ignored.txt')
  git('update-index', '--split-index')
  local index_path = git('rev-parse', '--path-format=absolute', '--git-path', 'index')
  local index_before = contents(index_path)
  local snapshot = open()
  assert(snapshot.head ~= head and snapshot.merge_base == merge_base)
  assert(git('rev-parse', snapshot.head .. '^') == head)
  assert(git('show', snapshot.head .. ':mixed.txt') == 'working tree version')
  assert(git('show', ':mixed.txt') == 'staged version')
  local files = git('ls-tree', '-r', '--name-only', snapshot.head)
  for _, path in ipairs({ 'committed.txt', 'after name.txt', 'staged.txt', 'mixed.txt', 'untracked.txt' }) do
    assert(vim.tbl_contains(vim.split(files, '\n'), path), files)
  end
  assert(not files:find('ignored.txt', 1, true) and not files:find('base.txt', 1, true), files)
  assert(contents(index_path) == index_before and git('rev-parse', 'HEAD') == head)
  local right = snapshot.windows.right
  local preview = require('tatara.diff').document(api.nvim_win_get_buf(right))
  local preview_row
  for row, location in pairs(preview.locations) do
    if location.path == 'long.txt' then
      preview_row = row
      assert(location.line == 1 and location.side == 'RIGHT')
      assert(preview.lines[row]:sub(location.offset + 1) == ('a'):rep(511) .. '…')
      break
    end
  end
  assert(preview_row, 'Long line lost its projection anchor')
  api.nvim_set_current_win(right)
  api.nvim_win_set_cursor(right, { preview_row, preview.locations[preview_row].offset })
  key('<CR>')
  wait('Open the complete long line', function()
    return T.get_context().view == 'diff' and T.get_context().path == 'long.txt'
  end)
  assert(api.nvim_get_current_line() == long_line and not vim.wo.wrap)
  key('gw')
  assert(vim.wo.wrap)
  key('gw')
  assert(not vim.wo.wrap)
  T.open_file('mixed.txt', { side = 'RIGHT', line = 1, native = true })
  wait('Open immutable snapshot source', function()
    return T.get_context().view == 'diff' and api.nvim_get_current_line() == 'working tree version'
  end)
  assert(vim.bo.readonly and vim.wo.wrap and not vim.startswith(api.nvim_buf_get_name(0), repo .. '/'))
  events.TataraDraftChanged = nil
  vim.cmd('Tatara comment')
  api.nvim_buf_set_lines(0, 0, -1, false, { 'Review the saved worktree value.' })
  vim.cmd.write()
  wait('Save a snapshot comment', function()
    return events.TataraDraftChanged and events.TataraDraftChanged.count == 1
  end)
  T.close()
  open(snapshot.head, '--worktree')
  clipboard = nil
  vim.cmd('Tatara export clipboard')
  wait('Copy the snapshot review', function()
    return clipboard ~= nil
  end)
  assert(clipboard:find(snapshot.head, 1, true) and clipboard:find('Branch HEAD at capture: ' .. head, 1, true))
  assert(clipboard:find('mixed.txt:1', 1, true) and clipboard:find('Review the saved worktree value.', 1, true))
  vim.fn.writefile({ 'also changed after the capture' }, repo .. '/untracked.txt')
  events.TataraRefreshed = nil
  vim.cmd('Tatara refresh')
  wait('Recapture worktree', function()
    return events.TataraRefreshed and T.get_context().head ~= snapshot.head
  end)
  assert(git('show', snapshot.head .. ':untracked.txt') == 'new file')
  assert(git('show', T.get_context().head .. ':untracked.txt') == 'also changed after the capture')
  assert(contents(index_path) == index_before and git('rev-parse', 'HEAD') == head)
  T.close()
end
local ok, message = xpcall(run, debug.traceback)
pcall(T.close)
vim.cmd.cd(vim.fn.fnameescape(vim.fn.fnamemodify(root, ':h')))
vim.fn.delete(root, 'rf')
assert(ok, message)
print('Tatara local review scenario passed')
