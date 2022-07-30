local MovingAverage = require "lsp-inlayhints.movingAverage"
local SlidingWindowAverage = require "lsp-inlayhints.sliding_window_average"
local config = require "lsp-inlayhints.config"

local M = {}

local function clamp(value, min, max)
  return math.min(math.max(value, min), max)
end

local FeatureDebounce = {}
-- FeatureDebounce.mt = {}

---@class DebounceInfo
---@field label string
---@field kind integer
---@field position lsp_position
local _debounceInfo = {}
setmetatable(_debounceInfo, {
  __index = function(t, bufnr)
    -- SlidingWindowAverage(6)
    t[bufnr] = {}
    return t[bufnr]
  end,
})

-- setmetatable(FeatureDebounce, {
--   __call = function(cls, ...)
--     return cls.new(...)
--   end,
-- })

function FeatureDebounce:new(name, default, min, max)
  ---@type table<string, SlidingWindowAverage>
  local _cache = {}

  local _min = min or 50
  local _max = max or math.pow(min, 2)

  local t = {}

  setmetatable(t, self)
  self.__index = self

  function t.get(bufnr)
    local key = bufnr
    local avg = _cache[key]
    return avg and (clamp(avg:value(), _min, _max)) or t.default()
  end

  local function _overall()
    if #_cache == 0 then
      return
    end

    local result = MovingAverage()
    for _, avg in pairs(_cache) do
      result.update(avg:value())
    end
    return result.value
  end

  function t.default()
    local value = _overall() or default
    return clamp(value, _min, _max)
  end

  function t.update(bufnr, value)
    local key = bufnr
    local avg = _cache[key]
    if not avg then
      avg = SlidingWindowAverage:new(6)
      _cache[key] = avg
    end

    local newValue = clamp(avg:update(value), _min, _max)

    if false and config.options.debug_mode then
      local msg = string.format("[DEBOUNCE: %s] for buffer %d is %dms", name, key, newValue)
      vim.notify(msg, vim.log.levels.TRACE)
    end

    return newValue
  end

  return t
end

---@type table<string, featureDebounce>
---@private
local _data = {}

M._for = function(name, config)
  config = config or {}
  local min = config.min or 50
  local max = config.max or math.pow(min, 2)

  local function _overallAverage()
    if #_data == 0 then
      return
    end

    local result = MovingAverage()
    for _, info in pairs(vim.tbl_values(_data)) do
      result.update(info.default())
    end

    return result.value
  end

  local info = _data[name]
  if not info then
    info = FeatureDebounce:new(name, _overallAverage() or (min * 1.5), min, max)
    _data[name] = info
  end

  return info
end

M.featureDebounce = FeatureDebounce

return M
