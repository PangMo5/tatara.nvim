-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local C = require('tatara.config')
local RPC = require('tatara.rpc')
local Session = {}
Session.__index = Session
local api = vim.api
local t = C.text
local Diff = require('tatara.diff')

local function scratch(name, ft)
  local existing = vim.fn.bufnr(name)
  if existing >= 0 and api.nvim_buf_is_valid(existing) then
    return existing
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, name)
  if ft then
    vim.bo[buf].filetype = ft
  end
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  return buf
end
local function replace(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
end
local function valid(win)
  return win and api.nvim_win_is_valid(win)
end
local function null(value)
  return value == nil or value == vim.NIL
end
local function error_text(err)
  return C.text(err.message or 'Backend error')
    .. (err.data and err.data.detail ~= '' and ('\n' .. err.data.detail) or '')
end

function Session.new(opts)
  local backend = C.backend()
  assert(
    vim.fn.executable(type(backend) == 'table' and backend[1] or backend) == 1,
    'Build and configure the Tatara backend first'
  )
  local self = setmetatable({
    id = tostring(vim.uv.hrtime()),
    opts = opts,
    wrap = opts.wrap ~= false,
    collapsed = {},
    rows = {},
    owned_maps = {},
    saved_options = {},
    extra_sources = {},
    namespace = api.nvim_create_namespace('tatara-' .. tostring(vim.uv.hrtime())),
    file_generation = 0,
    closed = false,
    draft = {},
    reviewed = {},
    reviewed_hunks = {},
    mode = 'overview',
    list_generation = 0,
    file_requests = {},
    composer_drafts = {},
    progress_ids = {},
    prepared_workspaces = {},
  }, Session)
  self.previous_tab = api.nvim_get_current_tabpage()
  self.source_options = {}
  for _, option in ipairs({ 'number', 'relativenumber', 'signcolumn', 'statuscolumn', 'foldcolumn' }) do
    self.source_options[option] = vim.wo[option]
  end
  vim.cmd.tabnew()
  self.tab = api.nvim_get_current_tabpage()
  self.files_buf = scratch('tatara://' .. self.id .. '/files', 'tatara')
  self.files_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(self.files_win, self.files_buf)
  self.overview_buf = scratch('tatara://' .. self.id .. '/overview', 'markdown')
  self.right_win = api.nvim_open_win(self.overview_buf, false, { split = 'right', win = self.files_win })
  self.diagnostic_counts = {}
  self.file_row_indices = {}
  self.file_row_labels = {}
  vim.wo[self.files_win].wrap = false
  vim.wo[self.files_win].number = false
  vim.wo[self.files_win].relativenumber = false
  vim.wo[self.files_win].signcolumn = 'no'
  vim.wo[self.files_win].foldcolumn = '0'
  vim.wo[self.files_win].winfixwidth = true
  self.group = api.nvim_create_augroup('Tatara' .. self.id, { clear = true })
  api.nvim_create_autocmd('WinClosed', {
    group = self.group,
    callback = function(event)
      if self.closed or self.internal_layout then
        return
      end
      if tonumber(event.match) == self.files_win then
        self.sidebar_hidden = true
      end
      if tonumber(event.match) == self.summary_win then
        self.summary_hidden = true
      end
    end,
  })
  api.nvim_create_autocmd('TabClosed', {
    group = self.group,
    callback = function()
      vim.schedule(function()
        if not self.closed and not api.nvim_tabpage_is_valid(self.tab) then
          self:close()
        end
      end)
    end,
  })
  api.nvim_create_autocmd('BufEnter', {
    group = self.group,
    callback = function(event)
      if self.closed or self.applying_file or api.nvim_get_current_tabpage() ~= self.tab then
        return
      end
      local win = api.nvim_get_current_win()
      if win ~= self.left_win and win ~= self.right_win then
        return
      end
      local owned_prefix = 'tatara://' .. self.id .. '/'
      if api.nvim_buf_get_name(event.buf):sub(1, #owned_prefix) == owned_prefix then
        return
      end
      local source = vim.b[event.buf].tatara or self:adopt_source(event.buf)
      if
        source
        and source.session == self.id
        and self.path
        and (source.path ~= self.path or (self.mode == 'source' and not valid(self.left_win)))
        and self.detail
        and source.head == self:revision().head
        and source.merge_base == self:revision().mergeBase
      then
        vim.schedule(function()
          if
            not self.closed
            and valid(win)
            and api.nvim_win_get_buf(win) == event.buf
            and (self.path ~= source.path or (self.mode == 'source' and not valid(self.left_win)))
          then
            local cursor = api.nvim_win_get_cursor(win)
            self:open_file(
              source.path,
              { side = source.side, line = cursor[1], column = cursor[2], record_jump = false }
            )
          end
        end)
      elseif
        not source
        or (self.detail and (source.head ~= self:revision().head or source.merge_base ~= self:revision().mergeBase))
      then
        if
          api.nvim_buf_get_name(event.buf):sub(1, #('tatara://' .. self.id .. '/')) ~= ('tatara://' .. self.id .. '/')
        then
          self:cancel_files()
        end
        for _, target in pairs({ self.left_win, self.right_win }) do
          if valid(target) then
            api.nvim_win_call(target, function()
              vim.cmd.diffoff()
            end)
          end
        end
        vim.wo[win].winbar = ' %f'
        local other = win == self.left_win and self.right_win or self.left_win
        if valid(other) then
          local ok = pcall(api.nvim_win_close, other, false)
          if ok then
            self.right_win = win
            self.left_win = nil
          end
        end
        self.mode = 'source'
      end
    end,
  })
  api.nvim_create_autocmd({ 'VimResized', 'WinResized', 'TabEnter' }, {
    group = self.group,
    callback = function()
      if not self.closed and api.nvim_get_current_tabpage() == self.tab then
        local old_narrow = self.narrow
        local source_win = valid(self.active_source_win) and self.active_source_win or self.right_win
        local position = valid(source_win)
            and api.nvim_win_call(source_win, function()
              return self:context()
            end)
          or self:context()
        self:layout()
        if
          old_narrow ~= self.narrow
          and (self.mode == 'combined' or self.mode == 'unified')
          and self.projection_results
        then
          self:project(self.projection_results, self.mode == 'combined', position, false, self.projection_wide)
        end
        if not self.applying_file and self.mode == 'diff' and self.current_buffers and valid(self.left_win) then
          Diff.reflow(self.current_buffers, { self.left_win, self.right_win })
          require('tatara.conversations').paint(self, { self.current_result }, self.current_buffers, false)
        elseif
          (self.mode == 'combined' or self.mode == 'unified')
          and self.projection_paired
          and valid(self.left_win)
        then
          Diff.reflow(self.projection_buffers, { self.left_win, self.right_win })
          require('tatara.conversations').paint(self, self.projection_results, self.projection_buffers, true)
        end
      end
    end,
  })
  Diff.highlights()
  api.nvim_create_autocmd('ColorScheme', { group = self.group, callback = Diff.highlights })
  api.nvim_create_autocmd({ 'WinEnter', 'WinLeave' }, {
    group = self.group,
    callback = function(event)
      local win = api.nvim_get_current_win()
      if win == self.left_win or win == self.right_win then
        if event.event == 'WinEnter' then
          self.active_source_win = win
        end
        vim.wo[win].cursorline = event.event == 'WinEnter'
      end
    end,
  })
  api.nvim_create_autocmd('WinScrolled', {
    group = self.group,
    callback = function(event)
      if self.closed or api.nvim_get_current_tabpage() ~= self.tab then
        return
      end
      local origin, generation = api.nvim_get_current_win(), self.file_generation
      if origin ~= self.left_win and origin ~= self.right_win then
        local scrolled = tonumber(event.match)
        if scrolled == self.left_win or scrolled == self.right_win then
          origin = scrolled
        end
      end
      if not self.scroll_sync_pending and (origin == self.left_win or origin == self.right_win) then
        self.scroll_sync_pending = true
        -- Native scrollbind and user scroll handlers finish the input cycle first.
        vim.schedule(function()
          self.scroll_sync_pending = false
          if
            self.closed
            or self.applying_file
            or generation ~= self.file_generation
            or api.nvim_get_current_tabpage() ~= self.tab
          then
            return
          end
          local windows = { self.left_win, self.right_win }
          if (self.mode == 'combined' or self.mode == 'unified') and self.projection_paired then
            Diff.sync(self.projection_buffers, windows, origin)
          elseif self.mode == 'diff' and self.current_buffers and C.get().diff.engine == 'difftastic' then
            Diff.sync(self.current_buffers, windows, origin)
          end
          self:update_sticky()
        end)
      end
      self:update_sticky()
    end,
  })
  api.nvim_create_autocmd('DiagnosticChanged', {
    group = self.group,
    callback = function(event)
      local source = vim.b[event.buf].tatara
      if
        not source
        or source.session ~= self.id
        or source.side ~= 'RIGHT'
        or not self.detail
        or source.head ~= self:revision().head
      then
        return
      end
      local counts = vim.diagnostic.count(event.buf)
      local label = (
        (counts[vim.diagnostic.severity.ERROR] or 0) > 0 and (' E' .. counts[vim.diagnostic.severity.ERROR]) or ''
      )
        .. ((counts[vim.diagnostic.severity.WARN] or 0) > 0 and (' W' .. counts[vim.diagnostic.severity.WARN]) or '')
      if self.diagnostic_counts[source.path] == label then
        return
      end
      self.diagnostic_counts[source.path] = label
      local row = self.file_row_indices[source.path]
      if row and api.nvim_buf_is_valid(self.files_buf) then
        vim.bo[self.files_buf].modifiable = true
        api.nvim_buf_set_lines(self.files_buf, row - 1, row, false, { self.file_row_labels[row] .. label })
        vim.bo[self.files_buf].modified = false
        vim.bo[self.files_buf].modifiable = false
        require('tatara.presentation').file(self, row)
      end
    end,
  })
  api.nvim_create_autocmd({ 'FileType', 'LspAttach' }, {
    group = self.group,
    callback = function(event)
      vim.schedule(function()
        if self.closed or C.get().diff.engine ~= 'difftastic' then
          return
        end
        local source = api.nvim_buf_is_valid(event.buf) and vim.b[event.buf].tatara
        if not source or source.session ~= self.id then
          return
        end
        for _, win in pairs({ self.left_win, self.right_win }) do
          if valid(win) and api.nvim_win_get_buf(win) == event.buf then
            Diff.configure_folds(win)
          end
        end
      end)
    end,
  })
  api.nvim_create_autocmd('Progress', {
    group = self.group,
    callback = function(event)
      local data = event.data or {}
      if data.source ~= 'tatara' or data.status ~= 'cancel' then
        return
      end
      local id = tonumber(tostring(data.id):match('^tatara%.' .. vim.pesc(self.id) .. ':(%d+)$'))
      if id and self.progress_ids[id] then
        if id == self.file_request or vim.tbl_contains(self.file_requests, id) then
          self:cancel_files()
        else
          self:cancel(id)
        end
      end
    end,
  })
  self.rpc = RPC.new(opts.cwd or vim.uv.cwd(), function(value)
    if not self.closed then
      local message = t(value.message)
      self.status = message
      require('tatara.loading').refresh(self)
      if C.get().progress.native then
        local state = self.progress_ids[value.id]
        local function publish()
          api.nvim_echo({ { state.message } }, false, {
            kind = 'progress',
            source = 'tatara',
            title = 'Tatara',
            id = 'tatara.' .. self.id .. ':' .. value.id,
            status = 'running',
          })
        end
        if not state then
          state = { message = message }
          self.progress_ids[value.id] = state
          -- The statusline responds immediately. Native progress messages are for
          -- sustained work, avoiding a stack of completion toasts for cache hits.
          state.timer = vim.defer_fn(function()
            state.timer = nil
            if not self.closed and self.progress_ids[value.id] == state and self.rpc.pending[value.id] then
              state.announced = true
              publish()
            end
          end, 150)
        else
          state.message = message
          if state.announced then
            publish()
          end
        end
      end
      self:emit('Progress', value)
    end
  end)
  self:map(self.files_buf, 'n', 'open', function()
    self:activate()
  end)
  api.nvim_create_autocmd({ 'CursorMoved', 'WinEnter' }, {
    group = self.group,
    buffer = self.files_buf,
    callback = function(event)
      if
        C.get().layout.preview_on_focus
        and not self.applying_file
        and api.nvim_get_current_win() == self.files_win
      then
        local node = self.rows[api.nvim_win_get_cursor(self.files_win)[1]]
        if not node or (event.event == 'CursorMoved' and self.file_focus_path == node.path) then
          return
        end
        self.file_focus_path = node.path
        self:preview_file_selection()
      end
    end,
  })
  self:map(self.files_buf, 'n', 'find_files', function()
    self:find_files()
  end)
  self:map(self.files_buf, 'n', 'fold_close', function()
    self:fold(false)
  end)
  self:map(self.files_buf, 'n', 'fold_open', function()
    self:fold(true)
  end)
  self:common_maps(self.files_buf)
  require('tatara.chrome').attach(self)
  replace(self.files_buf, { t('Loading…') })
  self:layout()
  self:call(
    'initialize',
    { repository = opts.repository, host = opts.host, demo = opts.demo, source = opts.cwd },
    function(value)
      self.repository = value.repository
      if opts.list then
        self:list({ kind = opts.kind })
      else
        self:open_pr(opts.number, opts.kind)
      end
    end,
    false
  )
  return self
end

function Session:emit(name, data)
  api.nvim_exec_autocmds('User', { pattern = 'Tatara' .. name, modeline = false, data = data or {} })
  require('tatara.chrome').refresh(self, true)
end
function Session:select(items, opts, done)
  self.picker_generation = (self.picker_generation or 0) + 1
  local generation = self.picker_generation
  local head, merge_base, number =
    self:revision().head, self:revision().mergeBase, self.detail and self.detail.item.id.number
  C.select(items, opts, function(item, index)
    if
      self.closed
      or generation ~= self.picker_generation
      or self.opening
      or head ~= self:revision().head
      or merge_base ~= self:revision().mergeBase
      or number ~= (self.detail and self.detail.item.id.number)
    then
      return
    end
    done(item, index)
  end)
end
function Session:context()
  local source = self:source_at_cursor()
  local cursor = api.nvim_win_get_cursor(0)
  return {
    windows = { files = self.files_win, summary = self.summary_win, left = self.left_win, right = self.right_win },
    repository = self.repository,
    number = self.detail and self.detail.item.id.number,
    head = self.detail and self:revision().head,
    merge_base = self.detail and self:revision().mergeBase,
    tab = self.tab,
    path = source and source.path or self.path,
    side = source and source.side or 'RIGHT',
    line = source and source.line or cursor[1],
    column = source and source.offset and math.max(0, cursor[2] - source.offset) or cursor[2],
    reviewable = source ~= nil and source.reviewable ~= false,
    workspace = self.workspace,
    view = self.mode,
    selection = self.mode == 'list' and {
      query = self.forge_query or '',
      kind = self.list_kind,
      preview = self.preview_selected,
      count = #(self.items or {}),
      loading = self.list_request ~= nil and self.rpc.pending[self.list_request] ~= nil,
    } or nil,
  }
end
function Session:call(method, params, done, owned, on_error)
  if self.closed then
    return
  end
  params = vim.deepcopy(params or {})
  if owned ~= false and self.detail then
    if
      (params.head and params.head ~= self:revision().head)
      or (params.number and params.number ~= self.detail.item.id.number)
      or (params.mergeBase and params.mergeBase ~= self:revision().mergeBase)
    then
      if method == 'write.confirm' then
        self.writing = false
      end
      C.notify(t('This pull request changed. Refresh before submitting your review.'), vim.log.levels.ERROR)
      return
    end
    params.head = params.head or self:revision().head
    params.number = params.number or self.detail.item.id.number
    params.mergeBase = params.mergeBase or self:revision().mergeBase
  end
  local head = self.detail and self:revision().head
  local merge_base = self.detail and self:revision().mergeBase
  local number = self.detail and self.detail.item.id.number
  local request_id
  self.status = t(({
    open = 'Loading pull request',
    file = 'Preparing immutable files',
    pulls = 'Loading…',
    inspect = 'Loading details…',
    ['search.content'] = 'Finding…',
    ['search.files'] = 'Finding…',
    ['review.preview'] = 'Preview',
    ['draft.add'] = 'Saving draft…',
    ['write.confirm'] = 'Submitting…',
  })[method] or 'Loading…')
  request_id = self.rpc:request(method, params, function(value, err)
    if self.closed then
      return
    end
    self:finish_progress(request_id, err and 'failed' or 'success')
    if
      owned ~= false
      and (
        head ~= (self.detail and self:revision().head)
        or merge_base ~= (self.detail and self:revision().mergeBase)
        or number ~= (self.detail and self.detail.item.id.number)
      )
    then
      return
    end
    if err then
      if method == 'write.confirm' then
        self.writing = false
        if self.closing_after_write then
          self:close()
        end
      end
      if method == 'open' then
        self.opening = false
      end
      if method == 'initialize' then
        self:close()
      end
      local message = error_text(err)
      if not (on_error and on_error(message, err)) then
        C.notify(message, vim.log.levels.ERROR)
      end
      return
    end
    if done then
      done(value)
    end
  end)
  require('tatara.loading').refresh(self)
  return request_id
end
function Session:finish_progress(id, status)
  if id and self.progress_ids[id] then
    local state = self.progress_ids[id]
    self.progress_ids[id] = nil
    if state.timer and not state.timer:is_closing() then
      state.timer:stop()
      state.timer:close()
    end
    if state.announced then
      api.nvim_echo({ { status == 'success' and t('Ready') or t('Close') } }, false, {
        kind = 'progress',
        source = 'tatara',
        title = 'Tatara',
        id = 'tatara.' .. self.id .. ':' .. id,
        status = status,
      })
    end
  end
  require('tatara.loading').refresh(self)
  require('tatara.chrome').refresh(self, false)
end
function Session:cancel(id)
  if id and id == self.open_request then
    self.opening = false
  end
  self.rpc:cancel(id)
  self:finish_progress(id, 'cancel')
end
function Session:cancel_files()
  self.file_generation = self.file_generation + 1
  self:cancel(self.file_request)
  self.file_request = nil
  for _, id in ipairs(self.file_requests) do
    self:cancel(id)
  end
  self.file_requests = {}
  if self.cancel_prepare then
    self.cancel_prepare()
    self.cancel_prepare = nil
  end
  return self.file_generation
end
function Session:map(buf, mode, action, callback)
  local key = C.get().keymaps[action]
  if not key or key == false then
    return
  end
  local existing = api.nvim_buf_call(buf, function()
    return vim.fn.maparg(key, mode, false, true)
  end)
  if existing.buffer == 1 then
    return
  end
  vim.keymap.set(mode, key, callback, { buffer = buf, desc = 'Tatara: ' .. action, silent = true })
  self.owned_maps[#self.owned_maps + 1] = { buf = buf, mode = mode, key = key, desc = 'Tatara: ' .. action }
end
function Session:common_maps(buf)
  if buf == self.files_buf or buf == self.summary_buf then
    for action, command in pairs({
      page_down = '<C-f>',
      page_up = '<C-b>',
      half_page_down = '<C-d>',
      half_page_up = '<C-u>',
    }) do
      self:map(buf, 'n', action, function()
        if not valid(self.right_win) then
          return
        end
        local count = vim.v.count1
        api.nvim_win_call(self.right_win, function()
          vim.cmd('normal! ' .. count .. vim.keycode(command))
        end)
        local windows = { self.left_win, self.right_win }
        if (self.mode == 'combined' or self.mode == 'unified') and self.projection_paired then
          Diff.sync(self.projection_buffers, windows, self.right_win)
        elseif self.mode == 'diff' and self.current_buffers and C.get().diff.engine == 'difftastic' then
          Diff.sync(self.current_buffers, windows, self.right_win)
        end
        self:update_sticky()
      end)
    end
  end
  local actions = {
    reviewed_hunk = function()
      self:mark_hunk_reviewed()
    end,
    hide_reviewed = function()
      self:toggle_reviewed()
    end,
    filter_files = function()
      self:filter_files()
    end,
    next_hunk = function()
      self:jump_hunk(1)
    end,
    previous_hunk = function()
      self:jump_hunk(-1)
    end,
    next_file = function()
      self:jump_file(1)
    end,
    previous_file = function()
      self:jump_file(-1)
    end,
    suggest = function()
      self:suggest()
    end,
    file_comment = function()
      self:file_comment()
    end,
    typed_comment = function()
      self:typed_comment()
    end,
    export_review = function()
      self:export_review()
    end,
    saved_reviews = function()
      self:saved_reviews()
    end,
    previous_view = function()
      self:cycle_view(-1)
    end,
    next_view = function()
      self:cycle_view(1)
    end,
    theme = function()
      self:theme()
    end,
    notifications = function()
      self:notifications()
    end,
    pick = function()
      self:list({ quick = true })
    end,
    overview = function()
      self:overview()
    end,
    diff_view = function()
      self:diff_view()
    end,
    discussion = function()
      self:discussion()
    end,
    checks = function()
      self:checks()
    end,
    combined = function()
      self:combined()
    end,
    drafts = function()
      self:drafts()
    end,
    reviewed = function()
      self:mark_reviewed()
    end,
    browser = function()
      self:browser()
    end,
    filters = function()
      self:filters()
    end,
    help = function()
      self:help()
    end,
    next_comment = function()
      self:jump_comment(1)
    end,
    previous_comment = function()
      self:jump_comment(-1)
    end,
    wrap = function()
      self.wrap = self.wrap == false
      for _, win in pairs({ self.left_win, self.right_win }) do
        if valid(win) then
          vim.wo[win].wrap = self.wrap
        end
      end
      if self.current_buffers and valid(self.left_win) then
        Diff.reflow(self.current_buffers, { self.left_win, self.right_win })
      end
    end,
    next_pane = function()
      vim.cmd('wincmd w')
    end,
    previous_pane = function()
      vim.cmd('wincmd W')
    end,
  }
  for action, callback in pairs(actions) do
    self:map(buf, 'n', action, callback)
  end
  self:map(buf, 'x', 'suggest', function()
    self:suggest({ visual = true })
  end)
  self:map(buf, 'n', 'close', function()
    self:close()
  end)
  self:map(buf, 'n', 'files', function()
    self:show_files()
  end)
  self:map(buf, 'n', 'review', function()
    self:review()
  end)
  self:map(buf, 'n', 'comments', function()
    self:comments(true)
  end)
  self:map(buf, 'n', 'refresh', function()
    self:refresh()
  end)
  self:map(buf, 'n', 'grep', function()
    self:grep()
  end)
end
function Session:source_buffer(path, side, result)
  local buf
  local materialized = side == 'RIGHT' and result.workspace or result.baseWorkspace
  if not null(materialized) and not (side == 'RIGHT' and result.status == 'removed') then
    local filename = materialized.path
    buf = vim.fn.bufadd(filename)
    local modeline = vim.bo[buf].modeline
    vim.bo[buf].modeline = false
    vim.fn.bufload(buf)
    if not self.saved_options[buf] then
      self.saved_options[buf] = {
        readonly = vim.bo[buf].readonly,
        modifiable = vim.bo[buf].modifiable,
        modeline = modeline,
        value = vim.b[buf].tatara,
      }
    end
    assert(not vim.bo[buf].modified, 'The immutable review buffer has unsaved changes: ' .. filename)
  else
    buf = scratch(
      'tatara://' .. self.id .. '/' .. result.head .. '/' .. side .. '/' .. path,
      vim.filetype.match({ filename = path }) or ''
    )
    replace(buf, vim.split(side == 'LEFT' and result.before or result.after, '\n', { plain = true, trimempty = false }))
    -- Drop only the final empty element produced by a terminating newline.
    local text = side == 'LEFT' and result.before or result.after
    if text:sub(-1) == '\n' then
      vim.bo[buf].modifiable = true
      api.nvim_buf_set_lines(buf, -2, -1, false, {})
      vim.bo[buf].modifiable = false
    end
  end
  if not self.saved_options[buf] then
    self.saved_options[buf] =
      { readonly = vim.bo[buf].readonly, modifiable = vim.bo[buf].modifiable, value = vim.b[buf].tatara }
  end
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  vim.b[buf].tatara = { session = self.id, path = path, side = side, head = result.head, merge_base = result.mergeBase }
  self:common_maps(buf)
  self:map(buf, 'n', 'comment', function()
    self:comment()
  end)
  self:map(buf, 'x', 'comment', function()
    self:comment({ visual = true })
  end)
  self:map(buf, 'n', 'open', function()
    self:comments(true)
  end)
  return buf
end
function Session:open_file(path, target)
  if not self.detail then
    return
  end
  if self.opening then
    C.notify(t('Loading…'))
    return
  end
  if self.form then
    require('tatara.forms').close(self, false)
  end
  local origin = api.nvim_get_current_win()
  local generation = self:cancel_files()
  self.file_request = self:call('file', { path = path, checkout = self.opts.materialize ~= false }, function(result)
    if generation ~= self.file_generation then
      return
    end
    if result.binary then
      self:project({ result }, false)
      self:emit('FileOpened', self:context())
      return
    end
    local completed = false
    local function show(err)
      if completed then
        return
      end
      completed = true
      self.cancel_prepare = nil
      if self.closed or generation ~= self.file_generation or api.nvim_get_current_tabpage() ~= self.tab then
        return
      end
      if err then
        C.notify(tostring(err), vim.log.levels.ERROR)
        return
      end
      self.applying_file = true
      local ok, message = pcall(function()
        local right = self:source_buffer(path, 'RIGHT', result)
        local left = self:source_buffer(path, 'LEFT', result)
        if not valid(self.left_win) then
          self.left_win = api.nvim_open_win(left, false, { split = 'left', win = self.right_win })
        end
        if not target or target.record_jump ~= false then
          for _, win in pairs({ self.left_win, self.right_win }) do
            api.nvim_win_call(win, function()
              vim.cmd("normal! m'")
            end)
          end
        end
        for _, win in pairs({ self.left_win, self.right_win }) do
          for option, value in pairs(self.source_options) do
            vim.wo[win][option] = value
          end
          -- Structural signs need a stable gutter on both sides. Preserve explicit
          -- user choices (including no/number/multiple columns), reserving only the
          -- default automatic column in these owned review windows.
          if self.source_options.signcolumn == 'auto' then
            vim.wo[win].signcolumn = 'yes:1'
          end
        end
        api.nvim_win_set_buf(self.left_win, left)
        api.nvim_win_set_buf(self.right_win, right)
        for win, side in pairs({ [self.left_win] = 'LEFT', [self.right_win] = 'RIGHT' }) do
          api.nvim_win_call(win, function()
            local workspace = side == 'LEFT' and result.baseWorkspace or result.workspace
            if not null(workspace) then
              vim.cmd.lcd({ args = { workspace.root } })
            end
            if C.get().diff.engine == 'native' then
              vim.cmd.diffthis()
            else
              vim.cmd.diffoff()
            end
          end)
          if C.get().diff.engine == 'native' then
            vim.wo[win].foldmethod = 'diff'
          end
          local label = side == 'LEFT' and not null(result.previousPath) and result.previousPath or path
          vim.wo[win].winbar = ' ' .. label:gsub('%%', '%%%%') .. ' · ' .. side .. ' · ' .. result.head:sub(1, 8)
        end
        self:layout()
        self.path = path
        self.workspace = not null(result.workspace) and result.workspace.root or nil
        local initial = not null(result.initial) and result.initial or { line = 1, side = 'RIGHT' }
        local location = target or initial
        local win = location.side == 'LEFT' and self.left_win or self.right_win
        local focus = api.nvim_get_current_win() == origin
        if focus then
          api.nvim_set_current_win(win)
        end
        local buf = api.nvim_win_get_buf(win)
        local line = location.line or 1
        assert(
          line >= 1 and line <= api.nvim_buf_line_count(buf),
          'The requested source line is not present in this revision'
        )
        local column = location.column or 0
        if location.encoding == 'utf-16' then
          column = vim.str_byteindex(api.nvim_buf_get_lines(buf, line - 1, line, false)[1], 'utf-16', column, true)
        end
        assert(
          column >= 0 and column <= #api.nvim_buf_get_lines(buf, line - 1, line, false)[1],
          'The requested source column is invalid'
        )
        api.nvim_win_set_cursor(win, { line, column })
        api.nvim_win_call(win, function()
          vim.cmd('normal! zvzz')
        end)
        self.mode = 'diff'
        if C.get().diff.engine == 'difftastic' then
          Diff.apply(result, { LEFT = left, RIGHT = right }, { self.left_win, self.right_win })
          vim.schedule(function()
            if
              not self.closed
              and generation == self.file_generation
              and self.mode == 'diff'
              and valid(self.left_win)
              and valid(self.right_win)
              and api.nvim_win_get_buf(self.right_win) == right
            then
              for _, w in ipairs({ self.left_win, self.right_win }) do
                Diff.configure_folds(w)
              end
              Diff.reflow({ LEFT = left, RIGHT = right }, { self.left_win, self.right_win })
            end
          end)
        end
        for _, w in pairs({ self.left_win, self.right_win }) do
          vim.wo[w].wrap = self.wrap ~= false
        end
        self.search_target = target and target.ranges and vim.tbl_extend('force', { path = path }, target) or nil
        self:paint_annotations(result, { LEFT = left, RIGHT = right })
        if self.narrow and not (target and target.native) then
          self:project({ result }, false, location, focus)
        end
        self:emit('FileOpened', self:context())
        if target and target.source_action then
          vim.schedule(function()
            if
              not self.closed
              and generation == self.file_generation
              and valid(win)
              and api.nvim_get_current_win() == win
              and api.nvim_win_get_buf(win) == buf
            then
              api.nvim_feedkeys(vim.keycode(target.source_action), 'm', false)
            end
          end)
        end
      end)
      self.applying_file = false
      if not ok then
        C.notify(message, vim.log.levels.ERROR)
      end
    end
    local context = {
      repository = self.repository,
      number = self.detail.item.id.number,
      path = path,
      workspace = not null(result.workspace) and result.workspace.root or nil,
      source = not null(result.workspace) and result.workspace.source or nil,
      base_workspace = not null(result.baseWorkspace) and result.baseWorkspace.root or nil,
      head = result.head,
      merge_base = result.mergeBase,
    }
    self:emit('WorkspaceReady', context)
    local hook = C.get().prepare
    local key = tostring(context.workspace) .. ':' .. tostring(context.base_workspace) .. ':' .. tostring(hook)
    if hook and context.workspace and not self.prepared_workspaces[key] then
      local ok, cancel = pcall(hook, context, function(err)
        if not err and not self.closed and generation == self.file_generation then
          self.prepared_workspaces[key] = true
        end
        show(err)
      end)
      if not ok then
        show(cancel)
      elseif not completed and type(cancel) == 'function' then
        self.cancel_prepare = cancel
      end
    else
      show()
    end
  end)
end
function Session:paint_annotations(result, buffers)
  for _, buf in pairs(buffers) do
    api.nvim_buf_clear_namespace(buf, self.namespace, 0, -1)
  end
  require('tatara.conversations').paint(self, { result }, buffers, false)
  if self.search_target and self.search_target.path == result.path then
    local target = self.search_target
    local buf = buffers[target.side]
    local text = buf and api.nvim_buf_get_lines(buf, target.line - 1, target.line, false)[1]
    if text and target.ranges and #target.ranges > 0 then
      local base = (target.column or 0) - target.ranges[1][1]
      for _, range in ipairs(target.ranges) do
        local first = vim.str_byteindex(text, 'utf-16', base + range[1], true)
        local last = vim.str_byteindex(text, 'utf-16', base + range[2], true)
        if last > first then
          api.nvim_buf_set_extmark(
            buf,
            self.namespace,
            target.line - 1,
            first,
            { end_col = last, hl_group = 'Search', priority = 200 }
          )
        end
      end
    end
  end
  self.current_result, self.current_buffers = result, buffers
end
function Session:float(lines, title, editable, save, draft_key, placement)
  local cache_key = editable
      and ((self.detail and (self:revision().head .. ':' .. self.detail.item.id.number) or '') .. ':' .. (draft_key or title))
    or nil
  if cache_key and self.composer_drafts[cache_key] then
    lines = vim.split(self.composer_drafts[cache_key], '\n', { plain = true })
  end
  local buf = scratch('tatara://' .. self.id .. '/dialog/' .. tostring(vim.uv.hrtime()))
  replace(buf, lines)
  local close, closing
  local win, dispose = require('tatara.dialog').open(self, buf, title, placement, function()
    if close then
      close()
    end
  end)
  vim.bo[buf].filetype = 'markdown'
  if not editable then
    require('tatara.prose').render(buf, win)
  end
  if placement then
    vim.b[buf].tatara_dialog = { title = title, hints = placement.footer or '' }
    if placement.context then
      vim.wo[win].winbar = ' ' .. placement.context:gsub('%%', '%%%%')
    end
  end
  close = function(saved)
    if closing then
      return
    end
    if valid(win) and api.nvim_get_current_win() == win then
      vim.cmd.stopinsert()
    end
    if cache_key and saved then
      self.composer_drafts[cache_key] = nil
    elseif cache_key and api.nvim_buf_is_valid(buf) then
      local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      local count, bytes = 0, #text
      for key, body in pairs(self.composer_drafts) do
        count = count + 1
        if key ~= cache_key then
          bytes = bytes + #body
        end
      end
      if (not self.composer_drafts[cache_key] and count >= 128) or bytes > 8 * 1024 * 1024 then
        C.notify('Composer drafts exceed their limit; keep this buffer or save it elsewhere.', vim.log.levels.ERROR)
        return
      end
      self.composer_drafts[cache_key] = text
    end
    closing = true
    dispose()
    if valid(win) then
      api.nvim_win_close(win, true)
    end
    if placement and placement.on_close then
      placement.on_close()
    end
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, desc = 'Tatara: close dialog' })
  if not editable then
    vim.keymap.set('n', 'q', close, { buffer = buf, desc = 'Tatara: close dialog' })
  end
  if editable then
    vim.bo[buf].modifiable = true
    vim.bo[buf].buftype = 'acwrite'
    api.nvim_create_autocmd('BufWriteCmd', {
      buffer = buf,
      callback = function()
        local body = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
        save(body, close)
      end,
    })
    vim.keymap.set('n', '<C-s>', function()
      vim.cmd.stopinsert()
      vim.cmd.write()
    end, { buffer = buf, desc = 'Tatara: save draft or preview' })
    vim.cmd.startinsert()
  end
  return buf, win, close
end
function Session:preview(value, on_back)
  local preview = value.preview
  local owner = { head = preview.head, number = preview.number }
  local lines = {
    '# ' .. t('Preview'),
    '',
    self.repository,
    '#' .. self.detail.item.id.number .. ' · ' .. preview.head,
    '',
    preview.event or preview.operation or '',
    '',
    preview.body or '',
  }
  if not null(preview.reaction) then
    lines[#lines + 1] = preview.reaction
      .. (preview.removesReaction and (' · ' .. t('Remove')) or (' · ' .. t('Add')))
  end
  if not null(preview.fileComment) then
    vim.list_extend(
      lines,
      { '', t('File comment') .. ' · ' .. preview.fileComment.path, '', preview.fileComment.body }
    )
  end
  if preview.comment then
    vim.list_extend(lines, { '', '@' .. preview.comment.author, preview.comment.body })
    lines[#lines + 1] = t('Comment') .. ' #' .. preview.comment.id
    if not null(preview.comment.url) then
      lines[#lines + 1] = preview.comment.url
    end
    local anchor = preview.comment.anchor
    if not null(anchor) then
      lines[#lines + 1] = anchor.path
        .. ':'
        .. (not null(anchor.line) and anchor.line or '—')
        .. ' · '
        .. (not null(anchor.side) and anchor.side or '—')
    end
  end
  for _, comment in ipairs(preview.comments or {}) do
    local snapshot
    if self.current_result and self.current_result.path == comment.path then
      snapshot = self.current_result
    end
    for _, result in ipairs(self.projection_results or {}) do
      if result.path == comment.path and result.head == preview.head then
        snapshot = result
        break
      end
    end
    if snapshot and snapshot.head == preview.head and snapshot.diff then
      local context = {}
      for _, row in ipairs(snapshot.diff.rows) do
        local line = row[comment.side == 'LEFT' and 'left' or 'right']
        if
          not null(line)
          and line.number >= math.max(1, (comment.start_line or comment.line) - 2)
          and line.number <= comment.line + 2
        then
          local text = {}
          for _, span in ipairs(line.spans) do
            text[#text + 1] = span.text
          end
          context[#context + 1] = line.number .. '  ' .. table.concat(text)
          if #context >= 12 then
            break
          end
        end
      end
      if #context > 0 then
        vim.list_extend(lines, { '', '```' .. (snapshot.diff.language or ''):lower() })
        vim.list_extend(lines, context)
        lines[#lines + 1] = '```'
      end
    end
    vim.list_extend(lines, {
      '',
      comment.path
        .. ':'
        .. (comment.start_line and (comment.start_line .. '–') or '')
        .. comment.line
        .. ' · '
        .. comment.side,
      '',
      comment.body,
    })
  end
  vim.list_extend(
    lines,
    { '', t('This will be posted to GitHub.'), '<CR> · ' .. t('Confirm') .. '   Esc · ' .. t('Back') }
  )
  local buf, _, close = require('tatara.forms').preview(
    self,
    vim.split(table.concat(lines, '\n'), '\n', { plain = true }),
    t('Preview'),
    on_back
  )
  local consumed = false
  vim.keymap.set('n', '<CR>', function()
    if consumed or self.writing or self.opening then
      return
    end
    consumed = true
    self.writing = true
    self:call(
      'write.confirm',
      { preview = value.id, head = owner.head, number = owner.number, mergeBase = owner.mergeBase },
      function()
        self.writing = false
        close(true)
        if self.closing_after_write then
          self:close()
          return
        end
        if preview.event and not preview.single then
          self.draft = {}
        end
        self:emit('ReviewSubmitted', self:context())
        C.notify(t('Review submitted.'))
        self:refresh()
      end
    )
  end, { buffer = buf, desc = 'Tatara: confirm this exact write preview' })
end
function Session:comment(opts)
  if self.opening then
    C.notify(t('Loading…'))
    return
  end
  opts = opts or {}
  local buf = api.nvim_get_current_buf()
  local source = self:source_at_cursor(opts.end_line)
  if not source or source.session ~= self.id or source.reviewable == false then
    C.notify(t('Choose a source position.'), vim.log.levels.WARN)
    return
  end
  if vim.bo[buf].modified or source.head ~= self:revision().head or source.merge_base ~= self:revision().mergeBase then
    C.notify(t('This pull request changed. Refresh before submitting your review.'), vim.log.levels.ERROR)
    return
  end
  if self.inline_editor and valid(self.inline_editor.win) then
    self.inline_editor.close()
    if valid(self.inline_editor.win) then
      api.nvim_set_current_win(self.inline_editor.win)
      return
    end
    self.inline_editor = nil
  end
  local line = source.line or api.nvim_win_get_cursor(0)[1]
  local first = opts.start_line
  if opts.visual then
    first = vim.fn.line('v')
    vim.cmd('normal! \027')
  end
  if first then
    local projection = Diff.document(buf)
    if projection then
      local anchor = projection.locations[first]
      if not anchor or anchor.path ~= source.path or anchor.side ~= source.side then
        C.notify(t('Choose a source position.'), vim.log.levels.WARN)
        return
      end
      first = anchor.line
    end
  end
  if first then
    first, line = math.min(first, line), math.max(first, line)
  end
  local body = opts.body or ''
  if opts.suggestion then
    if source.side ~= 'RIGHT' then
      C.notify(t('Suggestions require lines on the new side.'), vim.log.levels.WARN)
      return
    end
    local result = self.current_result
    local document = Diff.document(buf)
    if document then
      for _, item in ipairs(document.results) do
        if item.path == source.path then
          result = item
          break
        end
      end
    end
    if not result or result.path ~= source.path or type(result.after) ~= 'string' then
      C.notify(t('Choose a source position.'), vim.log.levels.WARN)
      return
    end
    local lines = vim.split(result.after, '\n', { plain = true })
    if line > #lines then
      return
    end
    local selected = table.concat(vim.list_slice(lines, first or line, line), '\n')
    local fence = '```'
    for run in selected:gmatch('`+') do
      if #run >= #fence then
        fence = string.rep('`', #run + 1)
      end
    end
    body = fence .. 'suggestion\n' .. selected .. '\n' .. fence
  end
  local owner =
    { head = self:revision().head, mergeBase = self:revision().mergeBase, number = self.detail.item.id.number }
  local comment = { path = source.path, side = source.side, line = line, start_line = first ~= line and first or nil }
  self.review_selection_ns = self.review_selection_ns
    or api.nvim_create_namespace('tatara.review-selection.' .. self.id)
  local selected_row = opts.end_line or api.nvim_win_get_cursor(0)[1]
  api.nvim_buf_set_extmark(
    buf,
    self.review_selection_ns,
    selected_row - 1,
    0,
    { line_hl_group = 'Visual', priority = 210 }
  )
  local parent = api.nvim_get_current_win()
  local display_line = opts.end_line or api.nvim_win_get_cursor(parent)[1]
  local highlight_buf = buf
  local editor_buf, editor_win, editor_close
  local function submit(single)
    if not api.nvim_buf_is_valid(editor_buf) then
      return
    end
    comment.body = table.concat(api.nvim_buf_get_lines(editor_buf, 0, -1, false), '\n')
    if single then
      self:call(
        'review.preview',
        { single = true, comment = comment, head = owner.head, number = owner.number, mergeBase = owner.mergeBase },
        function(value)
          editor_close()
          self.inline_editor = nil
          self:preview(value)
        end
      )
    else
      self:call(
        'draft.add',
        { comment = comment, head = owner.head, number = owner.number, mergeBase = owner.mergeBase },
        function(items)
          self.draft = items
          editor_close(true)
          self.inline_editor = nil
          self:repaint()
          self:render_files()
          self:emit('DraftChanged', { count = #items })
        end
      )
    end
  end
  editor_buf, editor_win, editor_close = self:float(
    vim.split(body, '\n', { plain = true }),
    t('Write your review') .. ' · #' .. owner.number,
    true,
    function()
      submit(false)
    end,
    (opts.suggestion and 'suggestion:' or 'comment:')
      .. comment.path
      .. ':'
      .. comment.side
      .. ':'
      .. (comment.start_line or comment.line)
      .. ':'
      .. comment.line,
    {
      parent = parent,
      spanning = true,
      anchor = display_line,
      source = {
        path = source.path,
        side = source.side,
        line = source.line or display_line,
        head = source.head,
        merge_base = source.merge_base,
      },
      on_anchor_changed = function(target, row)
        if highlight_buf ~= target and api.nvim_buf_is_valid(highlight_buf) then
          api.nvim_buf_clear_namespace(highlight_buf, self.review_selection_ns, 0, -1)
        end
        highlight_buf = target
        api.nvim_buf_clear_namespace(target, self.review_selection_ns, 0, -1)
        api.nvim_buf_set_extmark(
          target,
          self.review_selection_ns,
          row - 1,
          0,
          { line_hl_group = 'Visual', priority = 210 }
        )
      end,
      on_close = function()
        if api.nvim_buf_is_valid(highlight_buf) then
          api.nvim_buf_clear_namespace(highlight_buf, self.review_selection_ns, 0, -1)
        end
      end,
      context = comment.side
        .. ' · '
        .. (comment.start_line and (comment.start_line .. '–') or '')
        .. comment.line
        .. ' · '
        .. comment.path,
      footer = ':write · '
        .. t('Add comment to review')
        .. '   <LocalLeader>p · '
        .. t('Post comment')
        .. '   Esc · '
        .. t('Back'),
    }
  )
  self.inline_editor = { buf = editor_buf, win = editor_win, close = editor_close, submit = submit }
  self:map(editor_buf, 'n', 'post_comment', function()
    submit(true)
  end)
  require('tatara.chrome').refresh(self, true)
end
function Session:post_comment()
  local editor = self.inline_editor
  if editor and api.nvim_buf_is_valid(editor.buf) and api.nvim_get_current_buf() == editor.buf then
    vim.cmd.stopinsert()
    editor.submit(true)
  else
    C.notify(t('Choose a source position.'), vim.log.levels.WARN)
  end
end
function Session:close()
  if self.closed then
    return
  end
  if api.nvim_tabpage_is_valid(self.tab) then
    for _, win in ipairs(api.nvim_tabpage_list_wins(self.tab)) do
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].modified then
        C.notify('Finish or close modified review buffers before closing this review.', vim.log.levels.WARN)
        return
      end
    end
  end
  if self.writing then
    if not api.nvim_tabpage_is_valid(self.tab) then
      self.closing_after_write = true
    else
      C.notify(t('Submitting…'))
    end
    return
  end
  self.closed = true
  for id in pairs(self.progress_ids) do
    self:finish_progress(id, 'cancel')
  end
  if self.cancel_prepare then
    self.cancel_prepare()
    self.cancel_prepare = nil
  end
  self.rpc:close()
  require('tatara.loading').close(self)
  require('tatara.chrome').close(self)
  for _, buf in pairs(self.projection_buffers or {}) do
    Diff.clear(buf)
    Diff.forget(buf)
  end
  for _, map in ipairs(self.owned_maps) do
    if api.nvim_buf_is_valid(map.buf) then
      local entry = api.nvim_buf_call(map.buf, function()
        return vim.fn.maparg(map.key, map.mode, false, true)
      end)
      if entry.desc == map.desc then
        pcall(vim.keymap.del, map.mode, map.key, { buffer = map.buf })
      end
    end
  end
  for buf, saved in pairs(self.saved_options) do
    if api.nvim_buf_is_valid(buf) then
      vim.bo[buf].readonly = saved.readonly
      vim.bo[buf].modifiable = saved.modifiable
      if saved.modeline ~= nil then
        vim.bo[buf].modeline = saved.modeline
      end
      Diff.clear(buf)
      api.nvim_buf_clear_namespace(buf, self.namespace, 0, -1)
      if self.conversation_ns then
        api.nvim_buf_clear_namespace(buf, self.conversation_ns, 0, -1)
      end
      vim.b[buf].tatara = saved.value
    end
  end
  if api.nvim_tabpage_is_valid(self.tab) and #api.nvim_list_tabpages() > 1 then
    api.nvim_set_current_tabpage(self.tab)
    vim.cmd.tabclose()
  end
  pcall(api.nvim_del_augroup_by_id, self.group)
  local prefix = 'tatara://' .. self.id .. '/'
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if
      api.nvim_buf_is_valid(buf)
      and api.nvim_buf_get_name(buf):sub(1, #prefix) == prefix
      and not vim.bo[buf].modified
      and #vim.fn.win_findbuf(buf) == 0
    then
      pcall(api.nvim_buf_delete, buf, {})
    end
  end
  self:emit('Closed', { id = self.id })
end
require('tatara.review_state')(Session)
require('tatara.workspace')(Session, scratch, replace, valid)
require('tatara.selection')(Session, scratch, replace, valid)
require('tatara.discussion')(Session)
require('tatara.filters')(Session)
return Session
