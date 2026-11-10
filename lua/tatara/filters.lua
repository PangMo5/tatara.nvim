-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local api = vim.api
local C = require('tatara.config')
local t = C.text
return function(Session)
  function Session:filters()
    self:call('filters', { kind = self.list_kind or 'pullRequest' }, function(data)
      local form
      form = require('tatara.forms').open(
        self,
        'filters',
        t('Filters and presets'),
        self.forge_query or '',
        'query',
        function(query)
          self.forge_query = query:match('^%s*(.-)%s*$')
          require('tatara.forms').close(self, false)
          self:list()
        end
      )
      form.data = data
      local function query()
        return table.concat(api.nvim_buf_get_lines(form.buf, 0, -1, false), ' ')
      end
      local function set_query(value)
        if self.form ~= form then
          return
        end
        api.nvim_buf_set_lines(form.buf, 0, -1, false, { value })
        vim.bo[form.buf].modified = true
      end
      local function render()
        if self.form ~= form then
          return
        end
        for _, name in ipairs({ 'presets', 'labels' }) do
          local items = form.data[name]
          if not form[name .. '_buf'] then
            local buf = api.nvim_create_buf(false, true)
            api.nvim_buf_set_name(buf, 'tatara://' .. self.id .. '/filter-' .. name)
            form[name .. '_buf'] = buf
          end
          local buf = form[name .. '_buf']
          local lines = {}
          for _, item in ipairs(items) do
            lines[#lines + 1] = name == 'presets' and (t(item.name) .. '  ' .. item.query) or ('  ' .. item)
          end
          if #lines == 0 then
            lines = { t(name == 'labels' and 'No labels.' or 'No matches.') }
          end
          vim.bo[buf].modifiable = true
          api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          vim.bo[buf].modifiable = false
          if not form.windows[name] or not api.nvim_win_is_valid(form.windows[name]) then
            form.windows[name] = api.nvim_open_win(buf, false, {
              split = name == 'presets' and 'below' or 'right',
              win = name == 'presets' and self.right_win or form.windows.presets,
            })
          end
          api.nvim_win_set_buf(form.windows[name], buf)
          local win = form.windows[name]
          vim.wo[win].number = false
          vim.wo[win].relativenumber = false
          vim.wo[win].wrap = false
          local hints = 'Enter · '
            .. t(name == 'presets' and 'Apply' or 'Labels')
            .. (name == 'presets' and ('  d · ' .. t('Delete preset')) or '')
          require('tatara.chrome').panel(self, win, t(name == 'presets' and 'Presets' or 'Labels'), hints)
          vim.keymap.set('n', '<CR>', function()
            local item = items[api.nvim_win_get_cursor(0)[1]]
            if not item then
              return
            end
            if name == 'presets' then
              form.selected = item
              set_query(item.query)
            else
              self:call('filter.label', { label = item, query = query() }, set_query, false)
            end
          end, { buffer = buf, desc = 'Tatara: select filter option' })
          if name == 'presets' then
            vim.keymap.set('n', 'd', function()
              local item = items[api.nvim_win_get_cursor(0)[1]]
              if not item or item.id:match('^builtin:') then
                return
              end
              self:call('filter.delete', { id = item.id }, function()
                self:call('filters', { kind = self.list_kind or 'pullRequest' }, function(value)
                  form.data = value
                  render()
                end, false)
              end, false)
            end, { buffer = buf, desc = 'Tatara: delete local preset' })
          end
        end
        api.nvim_win_set_height(self.right_win, 3)
      end
      -- Create the lower-left list first; labels are a real sibling split.
      form.render = render
      render()
      vim.b[form.buf].tatara_dialog = {
        title = t('GitHub search query'),
        hints = ':write · ' .. t('Apply') .. '   <LocalLeader>s · ' .. t('Save preset') .. '   <C-w> · ' .. t(
          'Move'
        ) .. '   Esc · ' .. t('Back'),
      }
      vim.keymap.set('n', '<LocalLeader>s', function()
        vim.ui.input({
          prompt = t('Preset name') .. ': ',
          default = form.selected and not form.selected.id:match('^builtin:') and form.selected.name or '',
        }, function(name)
          if not name or self.form ~= form then
            return
          end
          local id = form.selected and not form.selected.id:match('^builtin:') and form.selected.id
            or self.id .. ':' .. vim.uv.hrtime()
          self:call('filter.save', { preset = { id = id, name = name, query = query() } }, function()
            self:call('filters', { kind = self.list_kind or 'pullRequest' }, function(value)
              if self.form == form then
                form.data = value
                render()
              end
            end, false)
          end, false)
        end)
      end, { buffer = form.buf, desc = 'Tatara: save local filter preset' })
      require('tatara.chrome').refresh(self, true)
    end, false)
  end
end
