-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local api = vim.api
local C = require('tatara.config')
local t = C.text
local function set(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[value] = true
  end
  return result
end
return function(Session)
  function Session:apply_review_state(state)
    self.review_state = state or { summary = '', event = 'COMMENT' }
    self.draft = {}
    for _, entry in ipairs(state and state.drafts or {}) do
      local comment = vim.deepcopy(entry.comment)
      comment.id = entry.id
      self.draft[#self.draft + 1] = comment
    end
    self.reviewed, self.reviewed_hunks = {}, set(state and state.reviewedHunks)
    for _, path in ipairs(state and state.reviewedFiles or {}) do
      self.reviewed[self:reviewed_key(path)] = true
    end
  end
  function Session:save_review_mark(params)
    self.mark_queue = self.mark_queue or {}
    params.head, params.number = self:revision().head, self.detail.item.id.number
    params.mergeBase = self:revision().mergeBase
    self.mark_queue[#self.mark_queue + 1] = params
    local function next_mark()
      local value = self.mark_queue[1]
      if not value then
        self.mark_saving = false
        return
      end
      self.mark_saving = true
      local function done(state)
        table.remove(self.mark_queue, 1)
        if state then
          self:apply_review_state(state)
          if (self.file_filter or C.get().files).hide_reviewed then
            self:set_file_filter({})
          else
            self:render_files()
          end
          self:repaint()
          self:emit('ReviewProgressChanged', self:context())
        end
        next_mark()
      end
      self:call('review.mark', value, done, true, function()
        done()
      end)
    end
    if not self.mark_saving then
      next_mark()
    end
  end
  function Session:hunk_at_cursor()
    local source = self:source_at_cursor()
    if not source then
      return
    end
    local line = source.line or api.nvim_win_get_cursor(0)[1]
    for _, hunk in ipairs(self.detail.hunks or {}) do
      local first = source.side == 'LEFT' and hunk.oldStart or hunk.newStart
      local count = source.side == 'LEFT' and hunk.oldCount or hunk.newCount
      if hunk.path == source.path and count > 0 and line >= first and line < first + count then
        return hunk
      end
    end
  end
  function Session:mark_hunk_reviewed()
    local hunk = self:hunk_at_cursor()
    if not hunk then
      C.notify(t("Choose a source line included in this file's patch."), vim.log.levels.WARN)
      return
    end
    local desired = not self.reviewed_hunks[hunk.id]
    for _, queued in ipairs(self.mark_queue or {}) do
      if queued.hunk == hunk.id then
        desired = not queued.reviewed
      end
    end
    self:save_review_mark({ hunk = hunk.id, reviewed = desired })
  end
  function Session:jump_hunk(direction)
    local ctx = self:context()
    local hunks = {}
    for _, hunk in ipairs(self.detail and self.detail.hunks or {}) do
      if self:file_visible(hunk.path) then
        local side = hunk.newCount > 0 and 'RIGHT' or 'LEFT'
        hunks[#hunks + 1] = { path = hunk.path, side = side, line = side == 'RIGHT' and hunk.newStart or hunk.oldStart }
      end
    end
    local current = self:hunk_at_cursor()
    local index
    for i, hunk in ipairs(self.detail.hunks or {}) do
      if current and current.id == hunk.id then
        for j, target in ipairs(hunks) do
          if target.path == hunk.path and target.line == (hunk.newCount > 0 and hunk.newStart or hunk.oldStart) then
            index = j
            break
          end
        end
        break
      end
    end
    if not index then
      for i, target in ipairs(hunks) do
        if target.path == ctx.path then
          index = direction > 0 and i - 1 or i + 1
          break
        end
      end
    end
    if #hunks == 0 then
      return
    end
    local target = hunks[((index or (direction > 0 and 0 or #hunks + 1)) - 1 + direction) % #hunks + 1]
    self:open_file(target.path, target)
  end
  function Session:jump_file(direction)
    local files, path = self:visible_files(), self:context().path
    if api.nvim_get_current_buf() == self.files_buf then
      local row = self.rows[api.nvim_win_get_cursor(0)[1]]
      path = row and row.path or path
    end
    local index = direction > 0 and 0 or #files + 1
    for i, file in ipairs(files) do
      if file.path == path then
        index = i
        break
      end
    end
    if #files > 0 then
      self:open_file(files[(index - 1 + direction) % #files + 1].path)
    end
  end
  function Session:file_visible(path)
    local filter = self.file_filter or C.get().files
    if filter.hide_reviewed and self.reviewed[self:reviewed_key(path)] then
      return false
    end
    if
      not self.filter_patterns
      or self.filter_patterns.include ~= filter.include
      or self.filter_patterns.exclude ~= filter.exclude
    then
      self.filter_patterns = {
        include = filter.include,
        exclude = filter.exclude,
        yes = filter.include ~= '' and vim.regex(filter.include) or nil,
        no = filter.exclude ~= '' and vim.regex(filter.exclude) or nil,
      }
    end
    return (not self.filter_patterns.yes or self.filter_patterns.yes:match_str(path) ~= nil)
      and (not self.filter_patterns.no or self.filter_patterns.no:match_str(path) == nil)
  end
  function Session:visible_files()
    local result = {}
    for _, file in ipairs(self.detail and self.detail.files or {}) do
      if self:file_visible(file.path) then
        result[#result + 1] = file
      end
    end
    return result
  end
  function Session:search_paths()
    local filter = self.file_filter or C.get().files
    if filter.include == '' and filter.exclude == '' and not filter.hide_reviewed then
      return nil
    end
    local paths = {}
    for _, file in ipairs(self:visible_files()) do
      paths[#paths + 1] = file.path
    end
    return paths
  end
  function Session:set_file_filter(filter)
    if filter and filter.hide_reviewed ~= nil and type(filter.hide_reviewed) ~= 'boolean' then
      return false
    end
    local value = vim.tbl_extend('force', self.file_filter or C.get().files, filter or {})
    for _, field in ipairs({ 'include', 'exclude' }) do
      if type(value[field]) ~= 'string' or #value[field] > 4096 then
        return false
      end
      local ok, message = pcall(vim.regex, value[field])
      if not ok then
        C.notify(message, vim.log.levels.ERROR)
        return false
      end
    end
    self.file_filter = value
    self:render_files()
    if self.mode == 'combined' then
      self:combined(true, self.preview_directory)
    elseif self.path and not self:file_visible(self.path) then
      self:combined(true)
    end
    self:emit('FileFilterChanged', vim.deepcopy(value))
    return true
  end
  function Session:filter_files()
    local current = self.file_filter or C.get().files
    self:float(
      { 'include=' .. current.include, 'exclude=' .. current.exclude },
      t('File filters'),
      true,
      function(body, close)
        local filter = {}
        for _, line in ipairs(vim.split(body, '\n', { plain = true })) do
          local key, pattern = line:match('^(%a+)=(.*)$')
          if (key ~= 'include' and key ~= 'exclude') or filter[key] then
            C.notify(t('Use include= and exclude= followed by a Neovim regular expression.'), vim.log.levels.ERROR)
            return
          end
          filter[key] = pattern
        end
        if self:set_file_filter(filter) then
          close(true)
        end
      end,
      nil,
      { parent = self.right_win, footer = ':write · ' .. t('Apply') .. '   Esc · ' .. t('Back') }
    )
  end
  function Session:toggle_reviewed()
    self:set_file_filter({ hide_reviewed = not (self.file_filter or C.get().files).hide_reviewed })
  end
  function Session:file_comment(path)
    if not self.detail or self.opening or self.detail.item.kind ~= 'pullRequest' then
      return
    end
    local ctx = self:context()
    if not path and api.nvim_get_current_buf() == self.files_buf then
      local row = self.rows[api.nvim_win_get_cursor(0)[1]]
      path = row and not row.directory and row.path
    end
    path = path or ctx.path
    local found = false
    for _, file in ipairs(self.detail.files) do
      if file.path == path then
        found = true
        break
      end
    end
    if not found then
      C.notify(t('Choose a source position.'), vim.log.levels.WARN)
      return
    end
    local head, number, base = self:revision().head, self.detail.item.id.number, self:revision().mergeBase
    local editor
    editor = self:float(
      { '' },
      t('File comment') .. ' · ' .. path,
      true,
      function(body, close)
        self:call(
          'review.preview',
          { single = true, fileComment = { path = path, body = body }, head = head, number = number, mergeBase = base },
          function(value)
            if not editor or not api.nvim_buf_is_valid(editor) then
              return
            end
            close()
            self:preview(value)
          end
        )
      end,
      'file-comment:' .. path,
      {
        parent = self.right_win,
        spanning = true,
        footer = ':write · ' .. t('Preview comment') .. '   Esc · ' .. t('Back'),
      }
    )
  end
  function Session:typed_comment()
    local types = C.get().comment_types
    if #types == 0 then
      self:comment()
      return
    end
    local source = self:context()
    self:select(types, {
      prompt = t('Comment type'),
      kind = 'tatara.comment_type',
      format_item = function(item)
        return item.label or item.id
      end,
    }, function(item)
      if item then
        local current = self:context()
        if current.path == source.path and current.line == source.line and current.side == source.side then
          self:comment({ body = item.prefix or (item.id .. ': ') })
        end
      end
    end)
  end
  function Session:suggest(opts)
    opts = vim.tbl_extend('force', opts or {}, { suggestion = true })
    self:comment(opts)
  end
  function Session:export_review(format, destination)
    self:call('review.export', { format = format or 'markdown' }, function(value)
      local text = type(value) == 'string' and value or vim.json.encode(value)
      if destination == 'clipboard' then
        vim.fn.setreg('+', text)
        C.notify(t('Copied'))
        return
      end
      local buf = api.nvim_create_buf(true, false)
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
      vim.bo[buf].filetype = format == 'json' and 'json' or 'markdown'
      api.nvim_open_win(buf, true, { split = 'below', win = self.right_win })
    end)
  end
  function Session:saved_reviews()
    local generation = self.file_generation
    self:call('review.sessions', {}, function(items)
      if generation ~= self.file_generation or api.nvim_get_current_tabpage() ~= self.tab then
        return
      end
      local lines, rows = { '# ' .. t('Saved reviews'), '' }, {}
      for _, item in ipairs(items) do
        local identity = item.identity
        local row = #lines + 1
        local block = {
          '#'
            .. identity.number
            .. ' · '
            .. identity.head:sub(1, 8)
            .. ' · '
            .. t('Pending')
            .. ' '
            .. item.drafts
            .. ' · '
            .. t('Reviewed')
            .. ' '
            .. item.reviewed,
          item.excerpt:gsub('\n', ' '),
          '',
        }
        vim.list_extend(lines, block)
        for index = row, #lines do
          rows[index] = item
        end
      end
      if #items == 0 then
        lines[#lines + 1] = t('No matches.')
      end
      self:document(lines, 'saved_reviews')
      local buf = api.nvim_win_get_buf(self.right_win)
      vim.wo[self.right_win].winbar = ' ' .. t('Saved reviews')
      vim.keymap.set('n', '<CR>', function()
        local item = rows[api.nvim_win_get_cursor(0)[1]]
        if not item then
          return
        end
        if
          item.identity.number == self.detail.item.id.number
          and item.identity.head == self:revision().head
          and item.identity.mergeBase == self:revision().mergeBase
        then
          self:drafts()
        else
          C.notify(t('Saved reviews are restored only at their exact revision.'), vim.log.levels.WARN)
        end
      end, { buffer = buf, desc = 'Tatara: resume exact revision' })
      vim.keymap.set('n', 'd', function()
        local item = rows[api.nvim_win_get_cursor(0)[1]]
        if not item then
          return
        end
        self:select({ t('Delete'), t('Cancel') }, {
          prompt = t('Saved reviews')
            .. ' · #'
            .. item.identity.number
            .. ' · '
            .. item.identity.head:sub(1, 8)
            .. ' · '
            .. t('Pending')
            .. ' '
            .. item.drafts,
          kind = 'tatara.forget_review',
        }, function(action)
          if action == t('Delete') then
            self:call('review.forget', { id = item.id, updatedAt = item.updatedAt }, function(state)
              self:apply_review_state(state)
              if
                item.identity.number == self.detail.item.id.number
                and item.identity.head == self:revision().head
                and item.identity.mergeBase == self:revision().mergeBase
              then
                self.composer_drafts = {}
              end
              self:render_files()
              self:repaint()
              self:saved_reviews()
            end)
          end
        end)
      end, { buffer = buf, desc = 'Tatara: delete saved revision with confirmation' })
      api.nvim_set_current_win(self.right_win)
    end)
  end
end
