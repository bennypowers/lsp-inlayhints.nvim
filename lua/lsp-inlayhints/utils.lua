local utils = {}

function utils.server_ready(client)
  return not not client.rpc.notify("$/window/progress", {})
end

function utils.request(client, bufnr, method, params, handler)
  -- TODO: cancellation ?
  -- if so, we should and save the ids and check for overlapping ranges
  -- for id, r in pairs(client.requests) do
  --   if r.method == method and r.bufnr == bufnr and r.type == "pending" then
  --     client.cancel_request(id)
  --   end
  -- end

  local success, id = client.request(method, params, handler, bufnr)
  return success, id
end

local function cleanup_timer(timer)
  if timer then
    if timer:has_ref() then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
    timer = nil
  end
end

-- Waits until duration has elapsed since the last call
utils.debounce = function(fn, duration)
  local timer = vim.loop.new_timer()
  local function inner(...)
    local argv = { ... }
    timer:start(
      duration,
      0,
      vim.schedule_wrap(function()
        fn(unpack(argv))
      end)
    )
  end

  local group = vim.api.nvim_create_augroup("InlayHints__CleanupLuvTimers", { clear = false })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    pattern = "*",
    callback = function()
      cleanup_timer(timer)
    end,
  })

  return timer, inner
end

local scheduler = {}

function scheduler:new(fn, delay)
  local t = {
    fn = fn,
    delay = delay,
    running = false,
    timer = vim.loop.new_timer(),
  }

  setmetatable(t, self)
  self.__index = self

  return t
end

function scheduler:schedule(fn, delay)
  delay = delay or self.delay

  self.timer:start(delay, 0, function()
    self:run(fn)
  end)
end

function scheduler:run(fn)
  if self.running then
    return false
  end

  fn = fn or self.fn
  self.running = true
  vim.schedule_wrap(fn)()
  self.running = false
end

function scheduler:clear()
  cleanup_timer(self.timer)
  self = nil
end

utils.scheduler = scheduler

local cancellationTokenSource = {}

function cancellationTokenSource:new()
  local t = {
    token = {},
  }

  function self:cancel()
    t.token.isCancellationRequested = true
  end

  setmetatable(t, self)
  self.__index = self

  return t
end

utils.cancellationTokenSource = cancellationTokenSource

return utils
