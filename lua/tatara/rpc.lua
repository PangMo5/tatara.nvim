-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local config = require('tatara.config')
local RPC = {}
RPC.__index = RPC

function RPC.new(cwd, progress)
  local self = setmetatable({ pending = {}, next_id = 0, buffer = '', closed = false }, RPC)
  local command = config.backend()
  command = type(command) == 'table' and vim.deepcopy(command) or { command }
  command[#command + 1] = 'serve'
  self.job = vim.fn.jobstart(command, {
    cwd = cwd,
    on_stdout = function(_, lines)
      if self.closed then
        return
      end
      self.buffer = self.buffer .. table.concat(lines, '\n')
      if #self.buffer > 16 * 1024 * 1024 then
        self:fail('Backend response exceeds 16 MiB')
        return
      end
      while true do
        local pos = self.buffer:find('\n', 1, true)
        if not pos then
          break
        end
        local line = self.buffer:sub(1, pos - 1)
        self.buffer = self.buffer:sub(pos + 1)
        if line ~= '' then
          local ok, message = pcall(vim.json.decode, line)
          if not ok then
            self:fail('Invalid backend response: ' .. message)
            return
          end
          if message.method == 'progress' then
            if progress and self.pending[message.params.id] then
              progress(message.params)
            end
          elseif message.id == vim.NIL then
            self:fail(message.error and message.error.message or 'Invalid backend response')
            return
          elseif message.id then
            local callback = self.pending[message.id]
            self.pending[message.id] = nil
            if callback then
              callback(message.result, message.error)
            end
          end
        end
      end
    end,
    on_stderr = function(_, lines)
      local message = table.concat(lines, '\n'):gsub('^%s+', ''):gsub('%s+$', '')
      if message ~= '' and not self.closed then
        config.notify(message:sub(1, 8192), vim.log.levels.ERROR)
      end
    end,
    on_exit = function(_, code)
      if not self.closed then
        self:fail('Tatara backend stopped (' .. code .. ')')
      end
    end,
  })
  assert(self.job > 0, 'Could not start the Tatara backend: ' .. table.concat(command, ' '))
  return self
end

function RPC:request(method, params, callback)
  assert(not self.closed, 'Tatara backend is closed')
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.pending[id] = callback
  vim.fn.chansend(
    self.job,
    vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params or {} }) .. '\n'
  )
  return id
end

function RPC:cancel(id)
  if not id or self.closed then
    return
  end
  self.pending[id] = nil
  vim.fn.chansend(
    self.job,
    vim.json.encode({ jsonrpc = '2.0', method = '$/cancelRequest', params = { id = id } }) .. '\n'
  )
end

function RPC:fail(message)
  if self.closed then
    return
  end
  self.closed = true
  local callbacks = self.pending
  self.pending = {}
  for _, callback in pairs(callbacks) do
    callback(nil, { message = message })
  end
  config.notify(message, vim.log.levels.ERROR)
end

function RPC:close()
  if self.closed then
    return
  end
  self.closed = true
  self.pending = {}
  vim.fn.chanclose(self.job, 'stdin')
end

return RPC
