-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local C = require('tatara.config')
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('tatara.picker.matches')
function M.content(session, mode)
  local pick = rawget(_G, 'MiniPick')
  if not pick then
    return false
  end
  local pending, preview, chosen, epoch = nil, nil, nil, 0
  local owner, number = session:revision().head, session.detail.item.id.number
  mode = mode or 'plain'
  local function name()
    return C.text('Search file contents')
      .. ' · '
      .. C.text(({ plain = 'Plain text', regex = 'Regular expression', fuzzy = 'Fuzzy' })[mode])
  end
  local function active(version)
    return not session.closed
      and epoch == version
      and owner == session:revision().head
      and number == session.detail.item.id.number
      and pick.get_picker_opts() ~= nil
  end
  local source = { name = name(), items = { { text = '' } } }
  source.match = function()
    epoch = epoch + 1
    local version = epoch
    session:cancel(pending)
    pending = session:call(
      'search.content',
      { query = table.concat(pick.get_picker_query() or {}), mode = mode, paths = session:search_paths() },
      function(items)
        if not active(version) then
          return
        end
        items = vim.tbl_filter(function(item)
          return session:file_visible(item.location.path)
        end, items)
        for _, item in ipairs(items) do
          item.text = item.location.path
            .. ':'
            .. item.location.line
            .. ' · '
            .. item.location.side
            .. ' │ '
            .. item.excerpt
        end
        pick.set_picker_items(items, { do_match = false })
        local indices = {}
        for i = 1, #items do
          indices[i] = i
        end
        pick.set_picker_match_inds(indices)
      end,
      true,
      function()
        if active(version) then
          pick.set_picker_items({}, { do_match = false })
          pick.set_picker_match_inds({})
        end
      end
    )
  end
  source.show = function(buf, items)
    local lines = {}
    for _, item in ipairs(items) do
      lines[#lines + 1] = item.text
    end
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for row, item in ipairs(items) do
      if item.location then
        local prefix = item.location.path .. ':' .. item.location.line .. ' · ' .. item.location.side .. ' │ '
        for _, range in ipairs(item.ranges or {}) do
          local first = #prefix + vim.str_byteindex(item.excerpt, 'utf-16', range[1], true)
          local last = #prefix + vim.str_byteindex(item.excerpt, 'utf-16', range[2], true)
          api.nvim_buf_set_extmark(buf, ns, row - 1, first, { end_col = last, hl_group = 'MiniPickMatchRanges' })
        end
      end
    end
  end
  source.preview = function(buf, item)
    if not item.location then
      return
    end
    local version = epoch
    session:cancel(preview)
    preview = session:call('search.preview', { path = item.location.path, line = item.location.line }, function(value)
      if not active(version) or not api.nvim_buf_is_valid(buf) then
        return
      end
      api.nvim_buf_set_lines(buf, 0, -1, false, value.lines)
      vim.bo[buf].filetype = vim.filetype.match({ filename = item.location.path }) or ''
      local state = pick.get_picker_state()
      if state then
        api.nvim_win_set_cursor(
          state.windows.main,
          { math.min(#value.lines, item.location.line - value.startLine + 1), 0 }
        )
      end
    end)
  end
  source.choose = function(item)
    if item.location then
      chosen = item
    end
  end
  pick.start({
    source = source,
    mappings = {
      tatara_mode = {
        char = '<M-m>',
        func = function()
          mode = ({ plain = 'regex', regex = 'fuzzy', fuzzy = 'plain' })[mode]
          pick.set_picker_opts({ source = { name = name() } })
          source.match()
        end,
      },
    },
  })
  epoch = epoch + 1
  session:cancel(pending)
  session:cancel(preview)
  if chosen and not session.closed and owner == session:revision().head and number == session.detail.item.id.number then
    session:open_file(chosen.location.path, {
      side = chosen.location.side,
      line = chosen.location.line,
      column = chosen.column,
      encoding = 'utf-16',
      ranges = chosen.ranges,
    })
  end
  return true
end
function M.pulls(session, items)
  local pick = rawget(_G, 'MiniPick')
  if not pick or C.get().select then
    session:list({ quick = false })
    return
  end
  local values = {}
  for _, item in ipairs(items) do
    values[#values + 1] = { text = '#' .. item.id.number .. ' ' .. item.title .. ' @' .. item.author, item = item }
  end
  local chosen, pending, version = nil, nil, session.list_generation
  pick.start({
    source = {
      name = C.text('Select a pull request'),
      items = values,
      preview = function(buf, value)
        session:cancel(pending)
        pending = session:call('inspect', { number = value.item.id.number, kind = value.item.kind }, function(detail)
          if session.closed or version ~= session.list_generation or not api.nvim_buf_is_valid(buf) then
            return
          end
          local lines = session:summary_lines(detail.item, detail)
          vim.list_extend(lines, { '', detail.item.body or '' })
          api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(table.concat(lines, '\n'), '\n', { plain = true }))
          local state = pick.get_picker_state()
          if state then
            require('tatara.prose').render(buf, state.windows.main)
          end
        end, false)
      end,
      choose = function(value)
        chosen = value.item
      end,
    },
  })
  session:cancel(pending)
  if chosen and not session.closed and version == session.list_generation then
    session:open_item(chosen.id.number, chosen.kind)
  end
end
function M.files(session)
  local owner_head, owner_number = session:revision().head, session.detail.item.id.number
  local function owned()
    return not session.closed
      and owner_head == session:revision().head
      and owner_number == session.detail.item.id.number
  end
  local paths, indices = {}, {}
  for i, file in ipairs(session:visible_files()) do
    paths[i], indices[file.path] = file.path, i
  end
  local function request(query, done, failed)
    return session:call('search.files', { query = query, paths = session:search_paths() }, function(items)
      done(vim.tbl_filter(function(item)
        return session:file_visible(item.path)
      end, items))
    end, true, failed)
  end
  if C.get().picker then
    C.get().picker({
      kind = 'tatara.files',
      items = paths,
      query = function(query, done)
        local id = request(query, done)
        return function()
          session:cancel(id)
        end
      end,
    }, function(path)
      if path and owned() then
        session:open_file(path)
      end
    end)
    return
  end
  local pick = not C.get().select and rawget(_G, 'MiniPick')
  if pick then
    local generation, pending, preview, hits = 0, nil, nil, {}
    local chosen
    local head, number = session:revision().head, session.detail.item.id.number
    local function active(epoch)
      local opts = pick.get_picker_opts()
      return opts
        and opts.source.name == C.text('Find files')
        and epoch == generation
        and not session.closed
        and session:revision().head == head
        and session.detail.item.id.number == number
    end
    pick.start({
      source = {
        name = C.text('Find files'),
        items = paths,
        match = function()
          generation = generation + 1
          local epoch = generation
          session:cancel(pending)
          pending = request(table.concat(pick.get_picker_query() or {}), function(items)
            if not active(epoch) then
              return
            end
            local matches = {}
            hits = {}
            for _, item in ipairs(items) do
              matches[#matches + 1] = indices[item.path]
              hits[item.path] = item.ranges
            end
            pick.set_picker_match_inds(matches)
          end, function()
            if active(epoch) then
              hits = {}
              pick.set_picker_match_inds({})
            end
          end)
        end,
        show = function(buf, items)
          api.nvim_buf_set_lines(buf, 0, -1, false, items)
          api.nvim_buf_clear_namespace(buf, ns, 0, -1)
          for row, path in ipairs(items) do
            for _, range in ipairs(hits[path] or {}) do
              local start = vim.str_byteindex(path, 'utf-16', range[1], true)
              local finish = vim.str_byteindex(path, 'utf-16', range[2], true)
              api.nvim_buf_set_extmark(buf, ns, row - 1, start, { end_col = finish, hl_group = 'MiniPickMatchRanges' })
            end
          end
        end,
        preview = function(buf, path)
          local epoch = generation
          session:cancel(preview)
          preview = session:call('search.preview', { path = path }, function(value)
            if not active(epoch) or not api.nvim_buf_is_valid(buf) then
              return
            end
            api.nvim_buf_set_lines(buf, 0, -1, false, value.lines)
            vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ''
          end)
        end,
        choose = function(path)
          chosen = path
        end,
      },
    })
    generation = generation + 1
    session:cancel(pending)
    session:cancel(preview)
    if
      chosen
      and not session.closed
      and session:revision().head == head
      and session.detail.item.id.number == number
    then
      session:open_file(chosen)
    end
    return
  end
  -- The standard provider is always available; custom providers can implement
  -- the asynchronous query contract without a mandatory picker dependency.
  vim.ui.input({ prompt = C.text('Find files') .. ': ' }, function(query)
    if query == nil or not owned() then
      return
    end
    request(query, function(items)
      session:select(items, {
        prompt = C.text('Find files'),
        kind = 'tatara.files',
        format_item = function(item)
          return item.path
        end,
      }, function(item)
        if item and not session.closed then
          session:open_file(item.path)
        end
      end)
    end)
  end)
end
return M
