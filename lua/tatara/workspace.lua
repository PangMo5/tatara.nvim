-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local api = vim.api
local C = require('tatara.config')
local D = require('tatara.diff')
local t = C.text
local function list(value)
  return type(value) == 'table' and value or {}
end
local function known(value)
  return value ~= nil and value ~= vim.NIL
end
local function count(value)
  return known(value) and tostring(value) or '—'
end
local function enum(value, kind)
  return type(value) == 'table' and value[kind] and (value[kind]._0 or value[kind]) or {}
end
return function(Session, scratch, replace, valid)
  function Session:revision()
    return self.detail and known(self.detail.revision) and self.detail.revision or { head = '', mergeBase = '' }
  end
  function Session:source_at_cursor(row)
    local buf = api.nvim_get_current_buf()
    local document = D.document(buf)
    if document then
      local location = document.locations[row or api.nvim_win_get_cursor(0)[1]]
      return location
        and vim.tbl_extend('force', location, {
          session = self.id,
          head = document.head,
          merge_base = document.merge_base,
        })
    end
    local source = vim.b[buf].tatara or self.extra_sources[buf]
    return row and source and vim.tbl_extend('force', source, { line = row }) or source
  end
  function Session:adopt_source(buf)
    if not self.current_result or not self.detail then
      return
    end
    local name = vim.fs.normalize(api.nvim_buf_get_name(buf))
    for side, workspace in pairs({ RIGHT = self.current_result.workspace, LEFT = self.current_result.baseWorkspace }) do
      if known(workspace) then
        local prefix = vim.fs.normalize(workspace.root) .. '/'
        if name:sub(1, #prefix) == prefix then
          if vim.bo[buf].modified then
            return
          end
          if not self.saved_options[buf] then
            self.saved_options[buf] =
              { readonly = vim.bo[buf].readonly, modifiable = vim.bo[buf].modifiable, value = vim.b[buf].tatara }
          end
          vim.bo[buf].readonly = true
          vim.bo[buf].modifiable = false
          self:common_maps(buf)
          self:map(buf, 'n', 'comment', function()
            self:comment()
          end)
          self:map(buf, 'x', 'comment', function()
            self:comment({ visual = true })
          end)
          local path = name:sub(#prefix + 1)
          local changed
          for _, file in ipairs(self.detail.files) do
            local expected = side == 'LEFT' and known(file.previousPath) and file.previousPath or file.path
            if expected == path then
              changed = file.path
              break
            end
          end
          local source = {
            session = self.id,
            path = changed or path,
            side = side,
            head = self:revision().head,
            merge_base = self:revision().mergeBase,
            reviewable = changed ~= nil,
          }
          if changed then
            vim.b[buf].tatara = source
            return source
          end
          self.extra_sources[buf] = source
          return
        end
      end
    end
  end
  function Session:summary_lines(item, detail)
    local info = known(item.github) and item.github or {}
    local metadata = detail and enum(detail.metadata, 'github') or {}
    local state = item.isDraft and 'Draft'
      or (item.state == 'merged' and 'Merged' or item.state == 'closed' and 'Closed' or 'Open')
    local lines = { '#' .. item.id.number .. ' ' .. item.title, '@' .. item.author .. ' · ' .. t(state) }
    local reviews =
      { APPROVED = 'Approved', CHANGES_REQUESTED = 'Changes requested', REVIEW_REQUIRED = 'Review required' }
    local checks =
      { SUCCESS = 'Passed', FAILURE = 'Failed', ERROR = 'Error', PENDING = 'Pending', EXPECTED = 'Expected' }
    if item.kind == 'pullRequest' then
      lines[#lines + 1] = t(reviews[info.reviewDecision] or 'Not reported')
        .. ' · CI '
        .. t(checks[info.checksState] or 'Not reported')
      local head = info.headBranch or metadata.headBranch
      local base = info.baseBranch or metadata.baseBranch
      if known(head) then
        lines[#lines + 1] = head .. ' → ' .. (known(base) and base or '—')
      end
      lines[#lines + 1] = t('Files')
        .. ' '
        .. count(detail and #detail.files or info.changedFiles)
        .. ' · '
        .. t('Comments')
        .. ' '
        .. count(detail and #detail.comments or info.commentCount)
        .. (#self.draft > 0 and (' · ' .. t('Pending') .. ' ' .. #self.draft) or '')
      lines[#lines + 1] = '+'
        .. count(info.additions)
        .. ' −'
        .. count(info.deletions)
        .. ' · '
        .. t('Commits')
        .. ' '
        .. count(info.commits)
    else
      lines[#lines + 1] = t('Comments') .. ' ' .. count(detail and #detail.comments or info.commentCount)
    end
    if #list(info.requestedReviewers) > 0 then
      lines[#lines + 1] = t('Requested reviewers') .. ' @' .. table.concat(info.requestedReviewers, ', @')
    end
    if #list(info.requestedTeams) > 0 then
      lines[#lines + 1] = t('Requested reviewers') .. ' ' .. table.concat(info.requestedTeams, ', ')
    end
    if #list(info.assignees) > 0 then
      lines[#lines + 1] = t('Assignees') .. ' @' .. table.concat(info.assignees, ', @')
    end
    if #list(item.labels) > 0 then
      lines[#lines + 1] = t('Labels') .. ': ' .. table.concat(item.labels, ', ')
    end
    if known(info.milestone) then
      lines[#lines + 1] = t('Milestone') .. ': ' .. info.milestone
    end
    if known(info.updatedAt) then
      lines[#lines + 1] = t('Updated') .. ' ' .. info.updatedAt
    end
    return lines
  end
  function Session:layout()
    if not valid(self.files_win) or not valid(self.right_win) then
      return
    end
    local narrow = vim.o.columns < C.get().layout.stacked_below
    local moved = self.narrow ~= narrow
    local resized = self.layout_rows ~= vim.o.lines
    local summary_changed = self.layout_summary ~= self.summary_win
    vim.wo[self.files_win].winfixheight = narrow
    if moved then
      api.nvim_win_call(self.files_win, function()
        vim.cmd(narrow and 'wincmd K' or 'wincmd H')
      end)
      self.narrow = narrow
    end
    local summary_height = math.max(3, math.min(10, math.floor((vim.o.lines - 4) / 4)))
    if valid(self.summary_win) then
      if moved then
        api.nvim_win_set_config(self.summary_win, { split = 'above', win = self.files_win })
      end
      if moved or summary_changed or resized then
        api.nvim_win_set_height(self.summary_win, summary_height)
      end
    end
    if narrow then
      if moved or self.layout_files ~= self.files_win or summary_changed or resized then
        api.nvim_win_set_height(
          self.files_win,
          math.max(3, math.floor((vim.o.lines - 4) / 2) - (valid(self.summary_win) and summary_height + 1 or 0))
        )
      end
      if valid(self.left_win) and (moved or self.layout_left ~= self.left_win) then
        api.nvim_win_set_config(self.left_win, { split = 'above', win = self.right_win })
      end
    else
      if moved or self.layout_files ~= self.files_win then
        api.nvim_win_set_width(self.files_win, C.get().layout.sidebar_width)
      end
      if valid(self.left_win) and (moved or self.layout_left ~= self.left_win) then
        api.nvim_win_set_config(self.left_win, { split = 'left', win = self.right_win })
      end
    end
    self.layout_left = self.left_win
    self.layout_rows = vim.o.lines
    self.layout_files, self.layout_summary = self.files_win, self.summary_win
    require('tatara.chrome').refresh(self, true)
  end
  function Session:render_files()
    if not self.detail or not api.nvim_buf_is_valid(self.files_buf) then
      return
    end
    if self.sidebar_hidden and not valid(self.files_win) then
      return
    end
    if not valid(self.files_win) then
      self.files_win = api.nvim_open_win(self.files_buf, false, { split = 'left', win = self.right_win })
      vim.wo[self.files_win].wrap = false
      vim.wo[self.files_win].number = false
      vim.wo[self.files_win].relativenumber = false
      vim.wo[self.files_win].signcolumn = 'no'
      vim.wo[self.files_win].winfixwidth = true
      self.narrow = nil
    end
    api.nvim_win_set_buf(self.files_win, self.files_buf)
    vim.wo[self.files_win].cursorline = true
    vim.wo[self.files_win].winhl = 'CursorLine:TataraTreeSelection'
    local cursor = valid(self.files_win) and api.nvim_win_get_cursor(self.files_win)[1] or 1
    local selected = self.rows[cursor] and self.rows[cursor].path
    if not valid(self.summary_win) and not self.summary_hidden then
      self.summary_buf = scratch('tatara://' .. self.id .. '/summary', 'markdown')
      self.summary_win = api.nvim_open_win(self.summary_buf, false, { split = 'above', win = self.files_win })
      vim.wo[self.summary_win].winfixheight = true
      vim.wo[self.summary_win].winfixwidth = true
      vim.wo[self.summary_win].cursorline = false
      vim.wo[self.summary_win].number = false
      vim.wo[self.summary_win].relativenumber = false
      vim.wo[self.summary_win].wrap = false
      vim.wo[self.summary_win].signcolumn = 'no'
      self:common_maps(self.summary_buf)
    end
    if valid(self.summary_win) then
      replace(self.summary_buf, self:summary_lines(self.detail.item, self.detail))
      require('tatara.presentation').summary(self.summary_buf, self.detail.item)
      vim.wo[self.summary_win].winbar = ' '
        .. t(self.detail.item.kind == 'issue' and 'Current issue' or 'Current pull request')
        .. ' · #'
        .. self.detail.item.id.number
    end
    local lines, nodes, seen = {}, {}, {}
    lines[#lines + 1] = '▾ /'
    self.root_row = #lines
    nodes[#lines] = { path = '/', directory = true }
    self.file_row_indices, self.file_row_labels = {}, {}
    local counts = {}
    for _, comment in ipairs(self.detail.comments) do
      if known(comment.anchor) then
        counts[comment.anchor.path] = (counts[comment.anchor.path] or 0) + 1
      end
    end
    local visible_files = self:visible_files()
    self.visible_file_count = #visible_files
    local hunk_counts = {}
    for _, hunk in ipairs(self.detail.hunks or {}) do
      local count = hunk_counts[hunk.path] or { total = 0, reviewed = 0 }
      count.total = count.total + 1
      count.reviewed = count.reviewed + (self.reviewed_hunks[hunk.id] and 1 or 0)
      hunk_counts[hunk.path] = count
    end
    for _, file in ipairs(visible_files) do
      local parent, depth, hidden = '', 1, false
      local parts = C.get().layout.files == 'list' and { file.path } or vim.split(file.path, '/', { plain = true })
      for i, part in ipairs(parts) do
        local path = parent == '' and part or (parent .. '/' .. part)
        local directory = i < #parts
        if not hidden and (not directory or not seen[path]) then
          seen[path] = true
          local marker = directory and (self.collapsed[path] and '▸ ' or '▾ ')
            or ((file.status == 'removed' and 'D' or (file.status or 'M'):sub(1, 1):upper()) .. ' ')
          local changes = ''
          if not directory then
            changes = (file.additions > 0 and (' +' .. file.additions) or '')
              .. (file.deletions > 0 and (' −' .. file.deletions) or '')
            changes = changes .. ((counts[path] or 0) > 0 and (' c' .. counts[path]) or '')
            local hunks = hunk_counts[path]
            changes = changes .. (hunks and hunks.reviewed > 0 and (' h' .. hunks.reviewed .. '/' .. hunks.total) or '')
            changes = changes .. (self.reviewed[self:reviewed_key(path)] and ' ✓' or '')
          end
          lines[#lines + 1] = string.rep('  ', depth) .. marker .. part .. changes
          nodes[#lines] = {
            path = path,
            directory = directory,
            file = file,
            stats_offset = #string.rep('  ', depth) + #marker + #part,
          }
          if not directory then
            self.file_row_indices[path], self.file_row_labels[#lines] = #lines, lines[#lines]
            lines[#lines] = lines[#lines] .. (self.diagnostic_counts[path] or '')
          end
        end
        hidden = hidden or (directory and self.collapsed[path])
        parent, depth = path, depth + 1
      end
    end
    self.rows = nodes
    replace(self.files_buf, lines)
    require('tatara.presentation').files(self)
    if valid(self.files_win) then
      vim.wo[self.files_win].winbar = ' '
        .. t('Files')
        .. ' · '
        .. self.visible_file_count
        .. '/'
        .. #self.detail.files
        .. ' · #'
        .. self.detail.item.id.number
      local row = self.root_row
      for i, node in pairs(nodes) do
        if node.path == selected then
          row = i
          break
        end
      end
      api.nvim_win_set_cursor(self.files_win, { row, 0 })
      self.file_focus_path = nodes[row] and nodes[row].path
    end
    self:layout()
  end
  function Session:show_files()
    self.sidebar_hidden = false
    self.summary_hidden = false
    self:render_files()
    if valid(self.files_win) then
      api.nvim_set_current_win(self.files_win)
    end
  end
  function Session:activate()
    local node = self.rows[api.nvim_win_get_cursor(self.files_win)[1]]
    if not node then
      return
    end
    if node.path == '/' then
      self:combined()
    elseif node.directory then
      self.collapsed[node.path] = not self.collapsed[node.path]
      self:render_files()
    else
      self:open_file(node.path)
    end
  end
  function Session:preview_file_selection()
    if not self.detail or self.opening or self.form or self.mode == 'list' then
      return
    end
    local node = self.rows[api.nvim_win_get_cursor(self.files_win)[1]]
    if not node then
      return
    end
    local key = self:revision().head .. ':' .. node.path
    if
      self.file_preview_key == key
      and (
        (self.mode == 'diff' or self.mode == 'unified') and self.path == node.path
        or self.mode == 'combined' and self.preview_directory == node.path
        or self.file_request and self.rpc.pending[self.file_request]
      )
    then
      return
    end
    self.file_preview_key = key
    if node.directory then
      if self.mode == 'combined' and self.preview_directory == node.path then
        return
      end
      self:combined(true, node.path)
      return
    end
    local generation = self:cancel_files()
    local function show(result)
      if
        self.closed
        or generation ~= self.file_generation
        or not valid(self.files_win)
        or api.nvim_get_current_win() ~= self.files_win
        or api.nvim_get_current_buf() ~= self.files_buf
      then
        return
      end
      local selected = self.rows[api.nvim_win_get_cursor(self.files_win)[1]]
      if not selected or selected.path ~= node.path then
        return
      end
      self:project({ result }, false, nil, false, true)
      self:emit('FilePreviewed', { path = node.path })
    end
    self.file_request = self:call('file', { path = node.path, checkout = false }, show, true, function(message)
      show({ path = node.path, error = message })
    end)
  end
  function Session:fold(expand)
    local node = self.rows[api.nvim_win_get_cursor(self.files_win)[1]]
    if not node then
      return
    end
    if node.directory and node.path ~= '/' then
      self.collapsed[node.path] = not expand
      self:render_files()
    elseif not expand then
      local parent = node.path:match('^(.*)/')
      for i, row in pairs(self.rows) do
        if row.path == parent then
          api.nvim_win_set_cursor(self.files_win, { i, 0 })
          return
        end
      end
      api.nvim_win_set_cursor(self.files_win, { self.root_row, 0 })
    elseif not node.directory then
      self:open_file(node.path)
    end
  end
  function Session:overview()
    if not self.detail then
      return
    end
    local lines = self:summary_lines(self.detail.item, self.detail)
    table.insert(lines, 1, '# ' .. t('Overview'))
    vim.list_extend(lines, { '', self.repository, '', self.detail.item.body or '' })
    self:document(lines, 'overview')
  end
  function Session:checks()
    if not self.detail then
      return
    end
    local metadata = enum(self.detail.metadata, 'github')
    local lines = { '# ' .. t('Checks'), '' }
    vim.list_extend(lines, list(metadata.checks))
    vim.list_extend(lines, { '', '# ' .. t('Review'), '' })
    vim.list_extend(lines, list(metadata.reviews))
    if #list(metadata.checks) == 0 then
      table.insert(lines, 3, t('Not reported'))
    end
    self:document(lines, 'checks')
  end
  function Session:document(lines, mode)
    self.file_preview_key = nil
    if self.form then
      require('tatara.forms').close(self, false)
    end
    self:cancel_files()
    local context = self:context()
    if self:source_at_cursor() then
      self.view_position = { line = context.line, column = context.column, side = context.side, head = context.head }
    end
    local buf = mode == 'overview' and self.overview_buf or scratch('tatara://' .. self.id .. '/' .. mode, 'markdown')
    replace(buf, vim.split(table.concat(lines, '\n'), '\n', { plain = true }))
    self:common_maps(buf)
    vim.wo[self.right_win].diff = false
    vim.wo[self.right_win].scrollbind = false
    api.nvim_win_set_buf(self.right_win, buf)
    require('tatara.prose').render(buf, self.right_win)
    vim.wo[self.right_win].winbar = ' '
      .. t(mode == 'checks' and 'Checks' or mode == 'discussion' and 'Discussion' or 'Overview')
      .. ' · #'
      .. self.detail.item.id.number
    if valid(self.left_win) then
      api.nvim_win_close(self.left_win, true)
      self.left_win = nil
    end
    self.mode = mode
    self:layout()
  end
  function Session:project(results, combined, target, focus, wide)
    self.projection_wide = combined or wide or false
    local paired = self.projection_wide and vim.o.columns >= C.get().layout.stacked_below
    local docs = { RIGHT = D.projection(results, paired and 'RIGHT' or nil) }
    if paired then
      docs.LEFT = D.projection(results, 'LEFT')
    end
    self.projection_buffers = self.projection_buffers or {}
    self.projection_paired = paired
    for side, doc in pairs(docs) do
      doc.head, doc.merge_base = self:revision().head, self:revision().mergeBase
      doc.results, doc.combined = results, combined
      local buf = self.projection_buffers[side]
        or scratch('tatara://' .. self.id .. '/projection/' .. side, 'tatara-diff')
      self.projection_buffers[side] = buf
      replace(buf, doc.lines)
      self:common_maps(buf)
      self:map(buf, 'n', 'comment', function()
        self:comment()
      end)
      self:map(buf, 'x', 'comment', function()
        self:comment({ visual = true })
      end)
      self:map(buf, 'n', 'open', function()
        local location = self:source_at_cursor()
        if location then
          self:open_file(location.path, {
            path = location.path,
            side = location.side,
            line = location.line,
            column = math.max(0, api.nvim_win_get_cursor(0)[2] - location.offset),
            native = true,
          })
        end
      end)
      for _, action in ipairs({ 'definition', 'references', 'hover' }) do
        self:map(buf, 'n', action, function()
          local location = self:source_at_cursor()
          if location then
            self:open_file(location.path, {
              path = location.path,
              side = location.side,
              line = location.line,
              column = math.max(0, api.nvim_win_get_cursor(0)[2] - location.offset),
              native = true,
              source_action = C.get().keymaps[action],
            })
          end
        end)
      end
      if side == 'LEFT' and not valid(self.left_win) then
        self.left_win = api.nvim_open_win(buf, false, { split = 'left', win = self.right_win })
      end
      local win = side == 'LEFT' and self.left_win or self.right_win
      self.applying_file = true
      api.nvim_win_set_buf(win, buf)
      self.applying_file = false
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].diff = false
      vim.wo[win].wrap = self.wrap ~= false
      vim.wo[win].scrollbind = paired
      vim.wo[win].foldmethod = 'manual'
      vim.wo[win].foldenable = false
      vim.wo[win].cursorline = win == api.nvim_get_current_win()
      D.paint_projection(buf, doc)
      self:paint_projection_notes(buf, doc)
    end
    if not paired and valid(self.left_win) then
      api.nvim_win_close(self.left_win, true)
      self.left_win = nil
    end
    self.mode = combined and 'combined' or 'unified'
    self.projection_paired = paired
    self.projection_results = results
    self.projection_buf = self.projection_buffers.RIGHT
    if not combined then
      self.path = results[1].path
    end
    local side = target and target.side or 'RIGHT'
    if not docs[side] then
      side = 'RIGHT'
    end
    local doc, win = docs[side], side == 'LEFT' and self.left_win or self.right_win
    local first, column = 1, 0
    for row, location in pairs(doc.locations) do
      if
        target
        and (not target.path or target.path == location.path)
        and (
          (location.line == target.line and location.side == target.side)
          or (location.alternate and location.alternate.line == target.line and location.alternate.side == target.side)
        )
      then
        first = row
        break
      end
    end
    if target and doc.locations[first] then
      local location = doc.locations[first]
      column = target.column or 0
      if target.encoding == 'utf-16' then
        column = vim.str_byteindex(doc.lines[first]:sub(location.offset + 1), 'utf-16', column, true)
      end
      column = location.offset + column
    end
    if focus ~= false then
      api.nvim_set_current_win(win)
    end
    api.nvim_win_set_cursor(win, { first, column })
    self:layout()
    if paired then
      D.align_projections(results, self.projection_buffers, { self.left_win, self.right_win })
      require('tatara.conversations').paint(self, results, self.projection_buffers, true)
    end
    self:update_sticky()
  end
  function Session:update_sticky()
    if self.closed or not valid(self.right_win) then
      return
    end
    self.content_titles = {}
    for side, win in pairs({ LEFT = self.left_win, RIGHT = self.right_win }) do
      if valid(win) then
        local doc = D.document(api.nvim_win_get_buf(win))
        if doc then
          local top = api.nvim_win_call(win, function()
            return vim.fn.line('w0')
          end)
          self.content_titles[side] = doc.headers[top] and C.text('Diff') or doc.header_paths[top] or C.text('Diff')
        end
      end
    end
    self.content_title = self.content_titles.RIGHT or self.content_title
    require('tatara.chrome').refresh(self, true)
  end
  function Session:combined(preserve_focus, directory)
    if not self.detail or self.opening then
      return
    end
    if self.form then
      require('tatara.forms').close(self, false)
    end
    local generation, head = self:cancel_files(), self:revision().head
    local origin = api.nvim_get_current_win()
    local results, index, completed, bytes = {}, 0, 0, 0
    self.preview_directory = directory or '/'
    self.path = nil
    local files = {}
    for _, file in ipairs(self:visible_files()) do
      if not directory or directory == '/' or file.path:sub(1, #directory + 1) == directory .. '/' then
        files[#files + 1] = file
      end
    end
    local function owned()
      return not self.closed and generation == self.file_generation and head == self:revision().head
    end
    local function publish()
      if owned() and completed == #files and api.nvim_get_current_tabpage() == self.tab then
        self:project(results, true, nil, not preserve_focus and api.nvim_get_current_win() == origin)
        self:emit('FileOpened', self:context())
      end
    end
    local enqueue
    local function receive(i, result)
      if not owned() then
        return
      end
      bytes = bytes
        + (known(result.before) and #result.before or 0)
        + (known(result.after) and #result.after or 0)
        + (result.diff and known(result.diff.alignment) and #result.diff.alignment * 16 or 0)
      if bytes > 64 * 1024 * 1024 then
        self.file_generation = self.file_generation + 1
        for _, id in ipairs(self.file_requests) do
          self:cancel(id)
        end
        C.notify('Combined diff exceeds its 64 MiB presentation limit. Open individual files.', vim.log.levels.ERROR)
        return
      end
      results[i] = result
      completed = completed + 1
      enqueue()
      publish()
    end
    enqueue = function()
      if not owned() then
        return
      end
      index = index + 1
      local i = index
      local file = files[i]
      if not file then
        return
      end
      self.file_requests[#self.file_requests + 1] = self:call(
        'file',
        { path = file.path, checkout = false },
        function(result)
          receive(i, result)
        end,
        true,
        function(message)
          receive(i, { path = file.path, error = message })
        end
      )
    end
    for _ = 1, math.min(4, #files) do
      enqueue()
    end
    if #files == 0 then
      publish()
    end
  end
  function Session:mark_reviewed()
    local source = self:source_at_cursor()
    local node = api.nvim_get_current_buf() == self.files_buf and self.rows[api.nvim_win_get_cursor(0)[1]] or nil
    local path = source and source.path or node and not node.directory and node.path
    if not path then
      return
    end
    local desired = not self.reviewed[self:reviewed_key(path)]
    for _, queued in ipairs(self.mark_queue or {}) do
      if queued.path == path then
        desired = not queued.reviewed
      end
    end
    self:save_review_mark({ path = path, reviewed = desired })
  end
  function Session:repaint()
    if self.current_result and self.current_buffers then
      self:paint_annotations(self.current_result, self.current_buffers)
    end
    for _, buf in pairs(self.projection_buffers or {}) do
      local doc = D.document(buf)
      if doc and doc.head == self:revision().head then
        self:paint_projection_notes(buf, doc)
      end
    end
    if (self.mode == 'combined' or self.mode == 'unified') and self.projection_paired and self.projection_results then
      require('tatara.conversations').paint(self, self.projection_results, self.projection_buffers, true)
      D.reflow(self.projection_buffers, { self.left_win, self.right_win })
    end
  end
  function Session:paint_projection_notes(buf, document)
    if self.projection_paired then
      return
    end
    require('tatara.conversations').paint(self, document.results, { RIGHT = buf }, true)
  end
  function Session:reviewed_key(path)
    return self.detail.item.id.number .. ':' .. self:revision().head .. ':' .. path
  end
  function Session:theme()
    self:select(
      { 'mocha', 'macchiato', 'frappe', 'latte', 'inherit' },
      { prompt = t('Theme'), kind = 'tatara.theme' },
      function(name)
        if name and not self.closed then
          C.get().theme = name
          require('tatara.theme').apply(true)
          require('tatara.chrome').refresh(self, true)
        end
      end
    )
  end
  function Session:diff_view()
    if self.path then
      local target = self.view_position and self.view_position.head == self:revision().head and self.view_position
        or nil
      self:open_file(self.path, target)
    else
      self:combined(false, self.preview_directory)
    end
  end
  function Session:cycle_view(delta)
    local views = { 'overview', 'diff', 'discussion', 'checks' }
    local current = (self.mode == 'combined' or self.mode == 'unified') and 'diff' or self.mode
    local index = 1
    for i, view in ipairs(views) do
      if view == current then
        index = i
      end
    end
    local selected = views[(index - 1 + delta) % #views + 1]
    if selected == 'diff' then
      self:diff_view()
    else
      self[selected](self)
    end
  end
  function Session:notifications()
    local lines = {}
    for _, item in ipairs(self.notification_history or {}) do
      vim.list_extend(lines, vim.split(item.message, '\n', { plain = true }))
      lines[#lines + 1] = ''
    end
    if #lines == 0 then
      lines = { t('No matches.') }
    end
    self:float(lines, t('Details'), false)
  end
  function Session:refresh()
    if self.writing then
      C.notify(t('Submitting…'))
      return
    end
    local old = self:revision().head
    local mode, path = self.mode, self.path
    local source = self:source_at_cursor()
    local line = source and (source.line or api.nvim_win_get_cursor(0)[1])
    self:call('refresh', {}, function(detail)
      self.detail = detail
      self.draft = detail.drafts or {}
      self:apply_review_state(detail.reviewState)
      if old ~= self:revision().head then
        self.draft = {}
        self.composer_drafts = {}
      end
      self:render_files()
      if mode == 'combined' then
        self:combined()
      elseif mode == 'checks' then
        self:checks()
      elseif path and (mode == 'diff' or mode == 'unified') then
        self:open_file(path, old == self:revision().head and source and { line = line, side = source.side } or nil)
      else
        self:overview()
      end
      self:emit('Refreshed', self:context())
    end)
  end
  function Session:browser()
    if self.detail then
      vim.ui.open(self.detail.item.url)
    end
  end
  function Session:help()
    local lines = { '# Tatara', '', ':Tatara · ' .. t('Select a pull request'), '' }
    for action, key in pairs(C.get().keymaps) do
      if key then
        lines[#lines + 1] = key .. '  ' .. action
      end
    end
    vim.list_extend(lines, {
      '',
      'h/j/k/l, w/b/e, /, n/N, <C-o>/<C-i>: Neovim',
      'gd, gr, K, diagnostics: user LSP',
      '<CR>: ' .. t('Open file'),
      ':Tatara drafts, checks, discussion, combined, filters, list, issues',
    })
    self:float(lines, t('Help'), false)
  end
end
