-- Global store/state management.
local M = {}

M._store = {
  active_clients = {},
  b = setmetatable({}, {
    __index = function(t, bufnr)
      t[bufnr] = {
        ---@type any[][]
        --- array of { line, hint } tuples
        cached_hints = {},
        ---@type table<string, integer>
        --- client_id -> request_id
        requests = {},
      }

      return rawget(t, bufnr)
    end,
  }),
}

return M
