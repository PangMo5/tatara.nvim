-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Exercise native Progress events with a controlled transport, not simulated timers.
local api, progress, transport = vim.api, nil, nil
package.loaded['tatara.rpc'] = {
  new = function(_, callback)
    progress = callback
    transport = { pending = {}, next = 0 }
    function transport:request(_, _, done)
      self.next = self.next + 1
      self.pending[self.next] = done
      return self.next
    end
    function transport:cancel(id)
      self.pending[id] = nil
    end
    function transport:close()
      self.pending = {}
    end
    function transport:complete(id)
      local done = assert(self.pending[id])
      self.pending[id] = nil
      done({})
    end
    return transport
  end,
}
local events = {}
api.nvim_create_autocmd('Progress', {
  callback = function(event)
    if event.data.source == 'tatara' then
      events[#events + 1] = event.data.status
    end
  end,
})
require('tatara').setup({
  backend = vim.v.progpath,
  reduce_motion = true,
  progress = { native = true },
  notify = function() end,
})
local function run()
  local s = require('tatara.session').new({ demo = true })
  local completed = 0
  local function request()
    return s:call('controlled-read', {}, function()
      completed = completed + 1
    end, false)
  end
  local fast = request()
  progress({ id = fast, message = 'Finding…' })
  transport:complete(fast)
  vim.wait(200, function()
    return false
  end)
  assert(#events == 0 and completed == 1, 'Fast completion created native progress/toast noise')
  local slow = request()
  progress({ id = slow, message = 'Finding…' })
  assert(
    vim.wait(1000, function()
      return #events == 1
    end, 10),
    'Sustained work has no native progress'
  )
  assert(events[1] == 'running')
  transport:complete(slow)
  assert(#events == 2 and events[2] == 'success' and completed == 2, 'Native progress did not finish')
  local canceled = request()
  progress({ id = canceled, message = 'Finding…' })
  s:cancel(canceled)
  vim.wait(200, function()
    return false
  end)
  assert(#events == 2, 'Canceled work announced stale progress after its deadline')
  s:close()
  print('Neovim progress passed: 3 lifecycles, fast completion, sustained native progress and canceled announcement.')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cq!')
else
  vim.cmd('qa!')
end
