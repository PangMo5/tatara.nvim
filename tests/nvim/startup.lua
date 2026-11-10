-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local T, api = require('tatara'), vim.api
local transport, errors = nil, {}
package.loaded['tatara.rpc'] = {
  new = function()
    transport = { next_id = 0, pending = {} }
    function transport:request(method, params, done)
      self.next_id = self.next_id + 1
      self.pending[self.next_id] = { method = method, params = params, done = done }
      return self.next_id
    end
    function transport:cancel(id)
      if id then
        self.pending[id] = nil
      end
    end
    function transport:close()
      self.pending = {}
    end
    function transport:complete(method, value, err)
      local request = assert(self.pending[self.next_id], 'Expected request ' .. method)
      assert(request.method == method, 'Expected ' .. method .. ', got ' .. request.method)
      self.pending[self.next_id] = nil
      request.done(value, err)
      return request.params
    end
    return transport
  end,
}
T.setup({
  backend = vim.v.progpath,
  reduce_motion = true,
  language = 'en',
  notify = function(message, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = message
    end
  end,
})

local function files()
  local win = T.get_context().windows.files
  return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
end

local function run()
  local notice = 'No pull request for this branch.'
  T.open()
  transport:complete('initialize', { repository = 'github.com/owner/repo' })
  transport:complete('open', nil, { message = notice, data = { kind = 'noCurrentPullRequest', detail = '' } })
  assert(files()[1] == notice)
  transport:complete('pulls', {
    items = {
      {
        id = { number = 42 },
        title = 'Review this change',
        author = 'contributor',
        state = 'open',
        kind = 'pullRequest',
      },
    },
    nextPage = vim.NIL,
  })
  assert(#errors == 0)
  assert(T.get_context().view == 'list' and files()[1] == notice)
  assert(vim.fn.getline('.'):find('#42 Review this change', 1, true))
  assert(transport.pending[transport.next_id].method == 'inspect')
  vim.fn.maparg('<CR>', 'n', false, true).callback()
  assert(transport.pending[transport.next_id].params.number == 42)
  T.close()

  T.open({ number = 404 })
  transport:complete('initialize', { repository = 'github.com/owner/repo' })
  transport:complete('open', nil, {
    message = 'Could not load the data. Check the details and try again.',
    data = { kind = 'commandFailed', detail = 'HTTP 404' },
  })
  assert(#errors == 1 and errors[1]:find('HTTP 404', 1, true))
  assert(files()[2] == 'HTTP 404' and next(transport.pending) == nil)
  T.close()
  print('Neovim startup passed: no branch PR opens selection and explicit PR failures remain visible.')
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cq!')
else
  vim.cmd('qa!')
end
