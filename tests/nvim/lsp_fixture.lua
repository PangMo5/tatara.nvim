-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

local input, output = vim.uv.new_pipe(false), vim.uv.new_pipe(false)
input:open(0)
output:open(1)
local buffer = ''
local finished = false
local function send(message)
  local text = vim.json.encode(message)
  output:write('Content-Length: ' .. #text .. '\r\n\r\n' .. text)
end
input:read_start(function(err, chunk)
  assert(not err, err)
  if not chunk then
    finished = true
    return
  end
  buffer = buffer .. chunk
  while true do
    local header = buffer:find('\r\n\r\n', 1, true)
    if not header then
      return
    end
    local length = tonumber(buffer:sub(1, header):match('Content%-Length:%s*(%d+)'))
    if #buffer < header + 3 + length then
      return
    end
    local message = vim.json.decode(buffer:sub(header + 4, header + 3 + length))
    buffer = buffer:sub(header + 4 + length)
    if message.method == 'initialize' then
      send({
        jsonrpc = '2.0',
        id = message.id,
        result = {
          capabilities = {
            textDocumentSync = { openClose = true, change = 1 },
            hoverProvider = true,
            positionEncoding = 'utf-16',
          },
        },
      })
    elseif message.method == 'textDocument/didOpen' then
      send({
        jsonrpc = '2.0',
        method = 'textDocument/publishDiagnostics',
        params = {
          uri = message.params.textDocument.uri,
          version = 0,
          diagnostics = {
            {
              range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } },
              severity = 2,
              message = 'User LSP diagnostic',
              source = 'user-fixture',
            },
          },
        },
      })
    elseif message.method == 'textDocument/hover' then
      send({ jsonrpc = '2.0', id = message.id, result = { contents = 'User LSP hover' } })
    elseif message.method == 'shutdown' then
      send({ jsonrpc = '2.0', id = message.id, result = vim.NIL })
    elseif message.method == 'exit' then
      finished = true
    elseif message.id then
      send({ jsonrpc = '2.0', id = message.id, result = vim.NIL })
    end
  end
end)
vim.wait(60000, function()
  return finished
end, 10)
input:read_stop()
input:close()
output:close()
