-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local C = require('tatara.config')
local api = vim.api
local t = C.text
local function known(x)
  return x ~= nil and x ~= vim.NIL
end
local names = {
  reply = 'Reply',
  edit = 'Edit comment',
  delete = 'Delete comment',
  react = 'React to comment',
  resolve = 'Resolve thread',
  unresolve = 'Reopen thread',
  copy = 'Copy',
  permalink = 'Open in browser',
}
local reactions = { 'THUMBS_UP', 'THUMBS_DOWN', 'LAUGH', 'HOORAY', 'CONFUSED', 'HEART', 'ROCKET', 'EYES' }
return function(Session)
  function Session:render_review_drafts(form)
    if self.form ~= form then
      return
    end
    if not form.list_buf then
      form.list_buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_name(form.list_buf, 'tatara://' .. self.id .. '/review-drafts')
      vim.bo[form.list_buf].bufhidden = 'hide'
      vim.b[form.list_buf].tatara_dialog = {
        title = t('Pending review'),
        hints = 'Enter · ' .. t('Edit') .. '   d · ' .. t('Remove') .. '   o · ' .. t('Open file'),
      }
      local function current()
        return self.draft[api.nvim_win_get_cursor(0)[1]]
      end
      vim.keymap.set('n', 'd', function()
        local item = current()
        if not item then
          return
        end
        self:call(
          'draft.remove',
          { id = item.id, expectedBody = item.body, head = form.head, number = form.number, mergeBase = form.mergeBase },
          function(items)
            self.draft = items
            self:render_review_drafts(form)
            self:repaint()
            self:render_files()
            self:emit('DraftChanged', { count = #items })
          end
        )
      end, { buffer = form.list_buf, desc = 'Tatara: remove pending comment' })
      vim.keymap.set('n', '<CR>', function()
        local item = current()
        if not item then
          return
        end
        self:float(
          vim.split(item.body, '\n', { plain = true }),
          t('Edit comment'),
          true,
          function(body, close)
            local comment = vim.deepcopy(item)
            comment.id = nil
            comment.body = body
            self:call('draft.update', {
              id = item.id,
              comment = comment,
              expectedBody = item.body,
              head = form.head,
              number = form.number,
              mergeBase = form.mergeBase,
            }, function(items)
              self.draft = items
              close(true)
              self:render_review_drafts(form)
              self:repaint()
              self:emit('DraftChanged', { count = #items })
            end)
          end,
          'draft:' .. item.id,
          { parent = form.windows.drafts, footer = ':write · ' .. t('Save') .. '   Esc · ' .. t('Back') }
        )
      end, { buffer = form.list_buf, desc = 'Tatara: edit pending comment' })
      vim.keymap.set('n', 'o', function()
        local item = current()
        if not item then
          return
        end
        require('tatara.forms').close(self, false)
        self:open_file(item.path, { side = item.side, line = item.line, native = true })
      end, { buffer = form.list_buf, desc = 'Tatara: pending comment source' })
    end
    local lines = {}
    for _, item in ipairs(self.draft) do
      lines[#lines + 1] = item.path
        .. ':'
        .. (item.start_line and (item.start_line .. '–') or '')
        .. item.line
        .. ' · '
        .. item.side
        .. '  '
        .. item.body:gsub('\n', ' '):sub(1, 100)
    end
    if #lines == 0 then
      lines = { t('No pending comments.') }
    end
    vim.bo[form.list_buf].modifiable = true
    api.nvim_buf_set_lines(form.list_buf, 0, -1, false, lines)
    vim.bo[form.list_buf].modifiable = false
    if not form.windows.drafts or not api.nvim_win_is_valid(form.windows.drafts) then
      form.windows.drafts = api.nvim_open_win(form.list_buf, false, { split = 'below', win = self.right_win })
      vim.wo[form.windows.drafts].number = false
      vim.wo[form.windows.drafts].relativenumber = false
    end
    api.nvim_win_set_height(form.windows.drafts, math.max(3, math.min(7, #lines + 1)))
    local win = form.windows.drafts
    require('tatara.chrome').panel(
      self,
      win,
      t('Pending review') .. ' · ' .. #self.draft,
      'Enter · ' .. t('Edit') .. '   d · ' .. t('Remove') .. '   o · ' .. t('Open file')
    )
  end
  function Session:review()
    if not self.detail or self.opening then
      return
    end
    if self.form and self.form.kind == 'review' then
      require('tatara.forms').resume(self)
      return
    end
    local form
    form = require('tatara.forms').open(
      self,
      'review',
      t('Finish review'),
      (self.review_state or {}).summary or '',
      'review',
      function(body, state)
        local event = ({ 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' })[state.event]
        self:call(
          'review.summary',
          { body = body, event = event, head = state.head, number = state.number, mergeBase = state.mergeBase },
          function(saved)
            if self.form ~= state then
              return
            end
            self:apply_review_state(saved)
            self:render_review_drafts(state)
            self:call('review.preview', {
              event = ({ 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' })[state.event],
              body = body,
              head = state.head,
              number = state.number,
              mergeBase = state.mergeBase,
            }, function(value)
              if self.form ~= state then
                return
              end
              self:preview(value)
            end)
          end
        )
      end
    )
    self.review_events = self.review_events or {}
    form.event = self.review_events[form.cache]
      or ({ COMMENT = 1, APPROVE = 2, REQUEST_CHANGES = 3 })[(self.review_state or {}).event]
      or 1
    local function select_event(index)
      if self.form ~= form then
        return
      end
      form.event = index
      self.review_events[form.cache] = index
      require('tatara.chrome').refresh(self, true)
    end
    for index = 1, self.detail.item.kind == 'issue' and 1 or 3 do
      vim.keymap.set('n', 'g' .. index, function()
        select_event(index)
      end, { buffer = form.buf, desc = 'Tatara: select review event' })
    end
    form.set_event = select_event
    form.render = function()
      self:render_review_drafts(form)
    end
    form.render()
    vim.b[form.buf].tatara_dialog = {
      title = t('Finish review'),
      hints = ':write · ' .. t('Preview') .. '   g1/g2/g3 · ' .. t('Comment') .. '/' .. t('Approve') .. '/' .. t(
        'Request changes'
      ) .. '   Esc · ' .. t('Back'),
    }
    api.nvim_set_current_win(self.right_win)
    require('tatara.chrome').refresh(self, true)
    vim.cmd.startinsert()
  end
  function Session:drafts()
    if not self.form or self.form.kind ~= 'review' then
      self:review()
    end
    local win = self.form and self.form.windows.drafts
    if win and api.nvim_win_is_valid(win) then
      vim.cmd.stopinsert()
      api.nvim_set_current_win(win)
    end
  end
  function Session:reader(selected)
    if not self.detail then
      return
    end
    local owner =
      { head = self:revision().head, mergeBase = self:revision().mergeBase, number = self.detail.item.id.number }
    self:call('comment.context', { key = selected.key }, function(context)
      local comment = context.comment
      comment.key = selected.key
      local root = known(comment.replyToID) and comment.replyToID or comment.id
      local thread = {}
      for _, value in ipairs(self.detail.comments) do
        if value.id == root or value.replyToID == root then
          thread[#thread + 1] = value
        end
      end
      if #thread == 0 then
        thread = { comment }
      end
      local lines = { '# @' .. comment.author, '' }
      if known(comment.anchor) and comment.anchor.subjectType == 'file' then
        lines[#lines + 1] = comment.anchor.path .. ' · ' .. t('File comment')
      elseif known(comment.anchor) then
        lines[#lines + 1] = comment.anchor.path
          .. ':'
          .. (known(comment.anchor.line) and comment.anchor.line or '—')
          .. ' · '
          .. (known(comment.anchor.side) and comment.anchor.side or '—')
      end
      if known(context.thread) then
        lines[#lines + 1] = t(context.thread.isResolved and 'Resolved' or 'Open')
      end
      for _, entry in ipairs(thread) do
        if entry.id == comment.id then
          entry = comment
        end
        vim.list_extend(lines, { '', '## @' .. entry.author, '', entry.body })
      end
      for _, reaction in ipairs(context.reactions) do
        lines[#lines + 1] = reaction.content .. ' ' .. reaction.count .. (reaction.viewerHasReacted and ' ✓' or '')
      end
      vim.list_extend(lines, {
        '',
        'r · ' .. t('Reply') .. '   e · ' .. t('Edit') .. '   a · ' .. t('React to comment') .. '   s · ' .. t(
          'Resolve thread'
        ),
      })
      local buf, _, close_reader =
        self:float(vim.split(table.concat(lines, '\n'), '\n', { plain = true }), t('Comments'), false, nil, nil, {
          parent = self.right_win,
          footer = 'r · '
            .. t('Reply')
            .. '   e · '
            .. t('Edit')
            .. '   a · '
            .. t('React to comment')
            .. '   Esc · '
            .. t('Back'),
        })
      local function mutation(action, reaction)
        local function preview(body, close)
          self:call('comment.preview', {
            key = selected.key,
            operation = action,
            body = body,
            reaction = reaction,
            expectedBody = comment.body,
            expectedUpdatedAt = comment.updatedAt,
            head = owner.head,
            number = owner.number,
            mergeBase = owner.mergeBase,
          }, function(value)
            if close then
              close()
            end
            close_reader()
            self:preview(value, function()
              self:reader(selected)
            end)
          end)
        end
        if action == 'reply' or action == 'edit' then
          self:float(
            vim.split(action == 'edit' and comment.body or '', '\n', { plain = true }),
            t('Write your review'),
            true,
            preview,
            'published:' .. selected.key .. ':' .. action,
            { parent = self.right_win, footer = ':write · ' .. t('Preview') .. '   Esc · ' .. t('Back') }
          )
        else
          preview('')
        end
      end
      local function copy()
        vim.fn.setreg('+', comment.body)
        C.notify(t('Copied'))
      end
      local function permalink()
        if known(comment.url) then
          vim.ui.open(comment.url)
        end
      end
      local allowed = {}
      for _, action in ipairs(context.actions) do
        allowed[action] = true
      end
      local function reaction()
        if not allowed.react then
          return
        end
        self:select(reactions, {
          prompt = t('React to comment'),
          kind = 'tatara.reactions',
          format_item = function(value)
            for _, item in ipairs(context.reactions) do
              if item.content == value then
                return value .. ' ' .. item.count .. (item.viewerHasReacted and ' ✓' or '')
              end
            end
            return value
          end,
        }, function(value)
          if value then
            mutation('react', value)
          end
        end)
      end
      for key, action in pairs({ r = 'reply', e = 'edit', d = 'delete' }) do
        if allowed[action] then
          vim.keymap.set('n', key, function()
            mutation(action)
          end, { buffer = buf, desc = 'Tatara: ' .. action })
        end
      end
      if allowed.react then
        vim.keymap.set('n', 'a', reaction, { buffer = buf, desc = 'Tatara: reaction' })
      end
      local resolve = allowed.resolve and 'resolve' or allowed.unresolve and 'unresolve'
      if resolve then
        vim.keymap.set('n', 's', function()
          mutation(resolve)
        end, { buffer = buf, desc = 'Tatara: thread resolution' })
      end
      vim.keymap.set('n', 'o', permalink, { buffer = buf, desc = 'Tatara: comment permalink' })
      vim.keymap.set('n', 'y', copy, { buffer = buf, desc = 'Tatara: copy comment' })
      vim.keymap.set('n', '<CR>', function()
        if known(comment.anchor) and known(comment.anchor.line) then
          close_reader()
          self:open_file(comment.anchor.path, { side = comment.anchor.side, line = comment.anchor.line, native = true })
        end
      end, { buffer = buf, desc = 'Tatara: comment source' })
    end)
  end
  function Session:comments(at_cursor)
    if not self.detail then
      return
    end
    local source = at_cursor and self:source_at_cursor()
    if not source then
      self:discussion()
      return
    end
    local line = source.line or api.nvim_win_get_cursor(0)[1]
    local nearest, distance
    for _, comment in ipairs(self.detail.comments) do
      local anchor = comment.anchor
      if known(anchor) and anchor.path == source.path and anchor.side == source.side and known(anchor.line) then
        local delta = math.abs(anchor.line - line)
        if not distance or delta < distance then
          nearest, distance = comment, delta
        end
      end
    end
    if nearest then
      self:reader(nearest)
    else
      self:discussion()
    end
  end
  function Session:discussion()
    if not self.detail then
      return
    end
    local lines = { '# ' .. t('Discussion'), '' }
    local rows = {}
    for _, comment in ipairs(self.detail.comments) do
      local start = #lines + 1
      vim.list_extend(lines, { '## @' .. comment.author, '' })
      vim.list_extend(lines, vim.split(comment.body, '\n', { plain = true }))
      lines[#lines + 1] = ''
      for i = start, #lines do
        rows[i] = comment
      end
    end
    -- document() preserves Markdown as native prose; Enter opens the chosen reader.
    self:document(lines, 'discussion')
    local buf = api.nvim_win_get_buf(self.right_win)
    self:map(buf, 'n', 'open', function()
      local comment = rows[api.nvim_win_get_cursor(0)[1]]
      if comment then
        self:reader(comment)
      end
    end)
    api.nvim_set_current_win(self.right_win)
  end
  function Session:jump_comment(direction)
    if not self.detail then
      return
    end
    local source = self:source_at_cursor()
    local items = {}
    for _, comment in ipairs(self.detail.comments) do
      if known(comment.anchor) and known(comment.anchor.line) then
        items[#items + 1] = comment
      end
    end
    table.sort(items, function(a, b)
      if a.anchor.path == b.anchor.path then
        return a.anchor.line < b.anchor.line
      end
      return a.anchor.path < b.anchor.path
    end)
    if #items == 0 then
      return
    end
    local index = direction > 0 and 1 or #items
    if source then
      local line = source.line or api.nvim_win_get_cursor(0)[1]
      if direction > 0 then
        for i, comment in ipairs(items) do
          if
            comment.anchor.path > source.path or (comment.anchor.path == source.path and comment.anchor.line > line)
          then
            index = i
            break
          end
        end
      else
        for i = #items, 1, -1 do
          local a = items[i].anchor
          if a.path < source.path or (a.path == source.path and a.line < line) then
            index = i
            break
          end
        end
      end
    end
    local anchor = items[index].anchor
    self:open_file(anchor.path, { line = anchor.line, side = anchor.side, native = true })
  end
end
