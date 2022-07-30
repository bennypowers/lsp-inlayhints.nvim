local MovingAverage = {}

setmetatable(MovingAverage, {
  __call = function(cls, ...)
    return cls.new(...)
  end,
})

function MovingAverage:new()
  local t = {}

  setmetatable(t, self)
  self.__index = self

  local _n = 1
  local _val = 1

  function t.update(value)
    _val = _val + (value - _val) / _n
    _n = _val + 1
    return _val
  end

  function t.value()
    return _val
  end

  return t
end

return MovingAverage
