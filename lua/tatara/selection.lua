-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local api = vim.api
local C = require('tatara.config')
local t = C.text
return function(Session, scratch, replace, valid)
  local function show_initial_error(self, message)
    if not self.detail and self.mode ~= 'list' then
      replace(self.files_buf, vim.split(message, '\n', { plain = true }))
    end
  end
  function Session:open_pr(number, kind)
    if self.writing then
      C.notify(t('Submitting…'))
      return
    end
    for _, win in ipairs(api.nvim_tabpage_list_wins(self.tab)) do
      if vim.bo[api.nvim_win_get_buf(win)].modified then
        C.notify('Finish or close modified review buffers before switching pull requests.', vim.log.levels.WARN)
        return
      end
    end
    self.picker_generation = (self.picker_generation or 0) + 1
    self.list_generation = self.list_generation + 1
    local generation = self.list_generation
    self:cancel(self.list_request)
    self:cancel(self.open_request)
    self.opening = true
    self:cancel_files()
    local function opened(detail)
      self.opening = false
      self.detail = detail
      self.draft, self.collapsed, self.diagnostic_counts = detail.drafts or {}, {}, {}
      self:apply_review_state(detail.reviewState)
      self.mark_queue, self.mark_saving = {}, false
      self.current_result, self.current_buffers = nil, nil
      self.path = nil
      self:render_files()
      if valid(self.files_win) then
        api.nvim_win_set_cursor(self.files_win, { self.root_row, 0 })
      end
      self:overview()
      if detail.item.kind == 'pullRequest' and #detail.files > 0 and C.get().initial_view == 'diff' then
        self:combined(true)
      end
      self:emit('Ready', self:context())
    end
    local function failed(message, err)
      if not number and err.data and err.data.kind == 'noCurrentPullRequest' then
        if not self.detail and self.mode ~= 'list' then
          replace(self.files_buf, { message })
        end
        if generation == self.list_generation then
          self:list({ kind = 'pullRequest', notice = message })
        end
        return true
      end
      show_initial_error(self, message)
    end
    self.open_request = self:call('open', { number = number, kind = kind or 'pullRequest' }, opened, false, failed)
  end
  function Session:list(opts)
    opts = opts or {}
    if opts.query ~= nil then
      self.forge_query = opts.query
    end
    self.list_kind = opts.kind or self.list_kind or 'pullRequest'
    self.list_generation = self.list_generation + 1
    local generation, kind, query = self.list_generation, self.list_kind, self.forge_query or ''
    self:cancel(self.list_request)
    local function listed(page)
      if generation ~= self.list_generation then
        return
      end
      self.next_page = page.nextPage ~= vim.NIL and page.nextPage or nil
      local owner = kind .. '\0' .. query
      if opts.page and self.items and self.items_owner == owner then
        vim.list_extend(self.items, page.items)
      else
        self.items = page.items
      end
      self.items_owner = owner
      if opts.quick then
        require('tatara.picker').pulls(self, self.items)
        return
      end
      if not self.selection_origin or self.mode ~= 'list' then
        self.selection_origin = require('tatara.forms').origin(self)
      end
      if self.form then
        require('tatara.forms').close(self, false)
      end
      self:cancel_files()
      if valid(self.summary_win) then
        self.internal_layout = true
        api.nvim_win_close(self.summary_win, true)
        self.internal_layout = false
        self.summary_win = nil
      end
      if valid(self.left_win) then
        api.nvim_win_close(self.left_win, true)
        self.left_win = nil
      end
      self.list_buf = self.list_buf or scratch('tatara://' .. self.id .. '/pull-requests', 'tatara')
      if not valid(self.files_win) then
        self.files_win = api.nvim_open_win(self.list_buf, false, { split = 'left', win = self.right_win })
      end
      api.nvim_win_set_buf(self.files_win, self.list_buf)
      vim.wo[self.files_win].number = false
      vim.wo[self.files_win].relativenumber = false
      vim.wo[self.files_win].wrap = false
      local lines = opts.notice and { opts.notice, '' } or {}
      self.item_rows, self.item_offsets = {}, {}
      for index, item in ipairs(self.items) do
        local info = item.github ~= vim.NIL and item.github or {}
        local state = item.isDraft and '◌'
          or item.state == 'merged' and '◆'
          or item.state == 'closed' and '×'
          or '○'
        self.item_offsets[index] = #lines + 1
        lines[#lines + 1] = state .. ' #' .. item.id.number .. ' ' .. item.title
        lines[#lines + 1] = '  @'
          .. item.author
          .. ' · '
          .. t(
            item.isDraft and 'Draft'
              or item.state == 'closed' and 'Closed'
              or item.state == 'merged' and 'Merged'
              or 'Open'
          )
        lines[#lines + 1] = '  '
          .. (info.headBranch or '')
          .. (info.baseBranch and (' → ' .. info.baseBranch) or '')
          .. (info.changedFiles and (' · ' .. t('Files') .. ' ' .. info.changedFiles) or '')
        for row = #lines - 2, #lines do
          self.item_rows[row] = item
        end
        lines[#lines + 1] = ''
      end
      if #self.item_offsets == 0 then
        lines[#lines + 1] = t('No matches.')
      end
      replace(self.list_buf, lines)
      self:common_maps(self.list_buf)
      vim.keymap.set('n', '<Esc>', function()
        self.list_generation = self.list_generation + 1
        self:cancel(self.list_request)
        self:cancel(self.inspect_request)
        if self.detail then
          self:render_files()
          require('tatara.forms').restore(self, self.selection_origin)
        else
          self:close()
        end
      end, { buffer = self.list_buf, desc = 'Tatara: cancel PR selection' })
      self:map(self.list_buf, 'n', 'open', function()
        local item = self.item_rows[api.nvim_win_get_cursor(0)[1]]
        if item then
          self:open_pr(item.id.number, item.kind)
        end
      end)
      self:map(self.list_buf, 'n', 'more', function()
        if self.next_page then
          self:list({ page = self.next_page })
        end
      end)
      self:map(self.list_buf, 'n', 'kind', function()
        self:list({ kind = kind == 'issue' and 'pullRequest' or 'issue' })
      end)
      local function move(delta)
        local row = api.nvim_win_get_cursor(self.files_win)[1]
        local current = 1
        for index, start in ipairs(self.item_offsets) do
          if start <= row then
            current = index
          end
        end
        local next_index = math.max(1, math.min(#self.item_offsets, current + delta))
        if self.item_offsets[next_index] then
          api.nvim_win_set_cursor(self.files_win, { self.item_offsets[next_index], 0 })
          self:inspect_selected()
        end
      end
      vim.keymap.set('n', 'j', function()
        move(1)
      end, { buffer = self.list_buf, desc = 'Tatara: next pull request' })
      vim.keymap.set('n', 'k', function()
        move(-1)
      end, { buffer = self.list_buf, desc = 'Tatara: previous pull request' })
      if not self.list_cursor_group then
        self.list_cursor_group = true
        api.nvim_create_autocmd('CursorMoved', {
          group = self.group,
          buffer = self.list_buf,
          callback = function()
            if self.mode == 'list' and api.nvim_get_current_buf() == self.list_buf then
              self:inspect_selected()
            end
          end,
        })
      end
      self.mode = 'list'
      self.preview_selected = nil
      api.nvim_set_current_win(self.files_win)
      api.nvim_win_set_cursor(self.files_win, { self.item_offsets[1] or 1, 0 })
      self:layout()
      self:inspect_selected()
    end
    self.list_request = self:call(
      'pulls',
      { page = opts.page or 1, kind = kind, query = query },
      listed,
      false,
      function(message)
        show_initial_error(self, message)
      end
    )
  end
  function Session:inspect_selected()
    if self.mode ~= 'list' or not valid(self.files_win) then
      return
    end
    local item = self.item_rows[api.nvim_win_get_cursor(self.files_win)[1]]
    if not item or self.preview_selected == item.id.number then
      return
    end
    self.preview_selected = item.id.number
    self:cancel(self.inspect_request)
    local generation = self.list_generation
    self.inspect_request = self:call('inspect', { number = item.id.number, kind = item.kind }, function(detail)
      if self.mode ~= 'list' or generation ~= self.list_generation or self.preview_selected ~= item.id.number then
        return
      end
      local buf = self.selection_preview_buf or scratch('tatara://' .. self.id .. '/pull-request-preview', 'markdown')
      self.selection_preview_buf = buf
      local lines = self:summary_lines(detail.item, detail)
      vim.list_extend(lines, { '', detail.item.body or '' })
      replace(buf, vim.split(table.concat(lines, '\n'), '\n', { plain = true }))
      self.applying_file = true
      api.nvim_win_set_buf(self.right_win, buf)
      self.applying_file = false
      vim.wo[self.right_win].number = false
      vim.wo[self.right_win].relativenumber = false
      vim.wo[self.right_win].wrap = true
      vim.wo[self.right_win].scrollbind = false
      self.content_title = '#' .. item.id.number .. ' · ' .. t('Preview')
      self:layout()
      require('tatara.prose').render(buf, self.right_win)
      require('tatara.chrome').refresh(self, true)
    end, false)
    local ns = self.namespace
    api.nvim_buf_clear_namespace(self.list_buf, ns, 0, -1)
    for row, entry in pairs(self.item_rows) do
      if entry.id.number == item.id.number then
        api.nvim_buf_set_extmark(self.list_buf, ns, row - 1, 0, { line_hl_group = 'TataraSelected' })
      end
    end
  end

  function Session:find_files()
    if self.detail then
      require('tatara.picker').files(self)
    end
  end
  function Session:grep(mode, query)
    if not self.detail then
      return
    end
    mode = mode or 'plain'
    if not query and require('tatara.picker').content(self, mode) then
      return
    end
    local head, number = self:revision().head, self.detail.item.id.number
    local function search(value)
      if value == nil or self.closed or head ~= self:revision().head or number ~= self.detail.item.id.number then
        return
      end
      self:cancel(self.search_request)
      self.search_generation = (self.search_generation or 0) + 1
      local generation = self.search_generation
      self.search_request = self:call(
        'search.content',
        { query = value, mode = mode, paths = self:search_paths() },
        function(items)
          if generation ~= self.search_generation then
            return
          end
          items = vim.tbl_filter(function(item)
            return self:file_visible(item.location.path)
          end, items)
          local owner_head, owner_number = self:revision().head, self.detail.item.id.number
          local locations = {}
          for _, item in ipairs(items) do
            locations[#locations + 1] = {
              module = item.location.path .. ':' .. item.location.line .. ' · ' .. item.location.side,
              lnum = item.location.line,
              col = 1,
              text = item.excerpt,
              valid = 1,
              user_data = item,
            }
          end
          api.nvim_win_call(self.right_win, function()
            vim.fn.setloclist(0, {}, 'r', { title = t('Search file contents') .. ' · ' .. value, items = locations })
            vim.cmd.lopen()
          end)
          local list = vim.fn.getloclist(self.right_win, { winid = 0 })
          if list.winid and list.winid ~= 0 then
            api.nvim_set_current_win(list.winid)
            local buf = api.nvim_win_get_buf(list.winid)
            vim.keymap.set('n', '<CR>', function()
              local hit = items[api.nvim_win_get_cursor(0)[1]]
              if
                hit
                and not self.closed
                and owner_head == self:revision().head
                and owner_number == self.detail.item.id.number
              then
                self:open_file(hit.location.path, {
                  side = hit.location.side,
                  line = hit.location.line,
                  column = hit.column,
                  encoding = 'utf-16',
                  ranges = hit.ranges,
                })
              end
            end, { buffer = buf, desc = 'Tatara: open immutable content match' })
          end
        end
      )
    end
    if query then
      search(query)
    else
      vim.ui.input({ prompt = t('Search file contents') .. ': ' }, search)
    end
  end
end
