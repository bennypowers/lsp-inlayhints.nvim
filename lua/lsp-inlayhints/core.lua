local M = {}
local utils = require "lsp-inlayhints.utils"
local config = require "lsp-inlayhints.config"
local adapter = require "lsp-inlayhints.adapter"
local store = require("lsp-inlayhints.store")._store

local AUGROUP = "_InlayHints"
local ns = vim.api.nvim_create_namespace "textDocument/inlayHints"
local enabled

-- TODO Set client capability
vim.lsp.handlers["workspace/inlayHint/refresh"] = function(_, _, ctx)
  local buffers = vim.lsp.get_buffers_by_client_id(ctx.client_id)
  for _, bufnr in pairs(buffers) do
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end

  return vim.NIL
end

local function set_store(bufnr, client)
  if not store.b[bufnr].attached then
    vim.api.nvim_buf_attach(bufnr, false, {
      on_detach = function()
        store.b[bufnr].cached_hints = {}
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end,
      on_lines = function(_, _, _, first_lnum, last_lnum)
        vim.api.nvim_buf_clear_namespace(bufnr, ns, first_lnum, last_lnum)
      end,
    })
  end

  store.b[bufnr].client = { name = client.name, id = client.id }
  store.b[bufnr].attached = true

  if not store.active_clients[client.name] then
    -- give it some time for the server to start;
    -- otherwise, the first requests afterrs may take longer than necessary
    vim.defer_fn(function()
      M.show(bufnr)
    end, 1000)
  end
  store.active_clients[client.name] = true
end

--- Setup inlayHints
---@param bufnr number
---@param client table A |vim.lsp.client| object
---@param force boolean Whether to call the server regardless of capability
function M.on_attach(bufnr, client, force)
  if not client then
    vim.notify_once("[LSP Inlayhints] Tried to attach to a nil client.", vim.log.levels.ERROR)
    return
  end

  if
    not (
      client.server_capabilities.inlayHintProvider
      or client.server_capabilities.clangdInlayHintsProvider
      or client.name == "tsserver"
      or force
    )
  then
    return
  end

  if config.options.debug_mode then
    vim.notify_once("[LSP Inlayhints] attached to " .. client.name, vim.log.levels.TRACE)
  end

  if config.options.debug_mode and store.b[bufnr].attached then
    local msg = vim.inspect { "already attached", bufnr = bufnr, store = store.b[bufnr] }
    vim.notify(msg, vim.log.levels.TRACE)
  end

  set_store(bufnr, client)
  M.setup_autocmd(bufnr)
end

function M.setup_autocmd(bufnr)
  -- WinScrolled covers |scroll-cursor|
  local events = { "BufEnter", "BufWritePost", "CursorHold", "InsertLeave", "WinScrolled" }

  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = false })
  local aucmd = vim.api.nvim_create_autocmd(events, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.show(bufnr)
    end,
  })

  local delayed_events = { "TextChangedI" }
  local aucmd2 = vim.api.nvim_create_autocmd(delayed_events, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.show(bufnr, true)
    end,
  })

  -- guard against multiple calls
  for _, v in pairs(store.b[bufnr].aucmd or {}) do
    pcall(vim.api.nvim_del_autocmd, v)
  end
  store.b[bufnr].aucmd = { aucmd, aucmd2 }

  if vim.fn.has "nvim-0.8" > 0 then
    local group2 = vim.api.nvim_create_augroup(AUGROUP .. "Detach", { clear = false })
    -- Needs nightly!
    -- https://github.com/neovim/neovim/commit/2ffafc7aa91fb1d9a71fff12051e40961a7b7f69
    vim.api.nvim_create_autocmd("LspDetach", {
      group = group2,
      buffer = bufnr,
      once = true,
      callback = function(args)
        if not store.b[bufnr] or args.data.client_id ~= store.b[bufnr].client_id then
          return
        end

        if config.options.debug_mode then
          local msg = string.format("[LSP InlayHints] detached from %d", bufnr)
          vim.notify(msg, vim.log.levels.TRACE)
        end

        for _, v in pairs(store.b[bufnr].aucmd) do
          pcall(vim.api.nvim_del_autocmd, v)
        end
        rawset(store.b, bufnr, nil)
      end,
    })
  end
end

--- Return visible lines of the buffer (1-based indexing)
local function get_visible_lines()
  return { first = vim.fn.line "w0", last = vim.fn.line "w$" }
end

local function col_of_row(row, offset_encoding)
  row = row - 1

  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, true)[1]
  if not line or #line == 0 then
    return 0
  end

  return vim.lsp.util._str_utfindex_enc(line, nil, offset_encoding)
end

--- Return visible range of the buffer
-- 'mark-indexed' (1-based lines, 0-based columns)
local function get_hint_ranges(offset_encoding)
  local line_count = vim.api.nvim_buf_line_count(0) -- 1-based indexing

  if line_count <= 200 then
    local col = col_of_row(line_count, offset_encoding)
    return {
      start = { 1, 0 },
      _end = { line_count, col },
    }
  end

  local extra = 30
  local visible = get_visible_lines()

  local start_line = math.max(1, visible.first - extra)
  local end_line = math.min(line_count, visible.last + extra)
  local end_col = col_of_row(end_line, offset_encoding)

  return {
    start = { start_line, 0 },
    _end = { end_line, end_col },
  }
end

local function make_params(start_pos, end_pos, bufnr)
  return {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = {
      -- convert to 0-index
      start = { line = start_pos[1] - 1, character = start_pos[2] },
      ["end"] = { line = end_pos[1] - 1, character = end_pos[2] },
    },
  }
end

---@param bufnr number
---@param range table mark-like indexing (1-based lines, 0-based columns)
---Returns 0-indexed params (per LSP spec)
local function get_params(range, bufnr)
  return make_params(range.start, range._end, bufnr)
end

local function parseHints(result, ctx)
  if type(result) ~= "table" then
    return {}
  end

  result = adapter.adapt(result, ctx)

  local map = {}
  for _, inlayHint in pairs(result) do
    local line = tonumber(inlayHint.position.line)
    if not map[line] then
      ---@diagnostic disable-next-line: need-check-nil
      map[line] = {}
    end

    table.insert(map[line], {
      label = inlayHint.label,
      kind = inlayHint.kind or 1,
      position = inlayHint.position,
    })

    table.sort(map[line], function(a, b)
      return a.position.character < b.position.character
    end)
  end

  return map
end

local function _key(bufnr)
  return vim.lsp.util.buf_versions[bufnr]
end

local function on_refresh(err, result, ctx, range)
  if err then
    M.clear(range.start[1] - 1, range._end[1])

    if config.options.debug_mode then
      local msg = err.message or vim.inspect(err)
      vim.notify_once("[inlay_hints] LSP error:" .. msg, vim.log.levels.ERROR)
      return
    end
  end

  local bufnr = ctx.bufnr
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end

  local parsed = parseHints(result, ctx)

  local helper = require "lsp-inlayhints.handler_helper"
  local hints = helper.render_hints(bufnr, parsed, ns, range)

  if #store.b[bufnr].cached_hints > 30 then
    store.b[bufnr].cached_hints = {}
  end

  store.b[bufnr].cached_hints[_key(bufnr)] = hints
end

local render_cached = function(bufnr)
  -- local hints = store.cached_hints:get((bufnr))
  local hints = store.b[bufnr].cached_hints[_key(bufnr)]
  if not hints then
    return
  end

  for _, v in pairs(hints) do
    local line, virt_text = unpack(v)
    M.clear(line, line + 1)

    vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
      virt_text_pos = config.options.inlay_hints.right_align and "right_align" or "eol",
      virt_text = {
        { virt_text, config.options.inlay_hints.highlight },
      },
      hl_mode = "combine",
    })
  end
end

function M.toggle()
  if enabled then
    M.clear()
  else
    M.show()
  end

  enabled = not enabled
end

--- Clear all hints in the current buffer
--- Lines are 0-indexed.
---@param line_start integer | nil, defaults to 0 (start of buffer)
---@param line_end integer | nil, defaults to -1 (end of buffer)
function M.clear(line_start, line_end)
  -- clear namespace which clears the virtual text as well
  vim.api.nvim_buf_clear_namespace(0, ns, line_start or 0, line_end or -1)
end

local scheduler = require("lsp-inlayhints.utils").scheduler:new()

-- Sends the request to get the inlay hints and show them
---@param bufnr number | nil
---@param is_insert boolean | nil
function M.show(bufnr, is_insert)
  if enabled == false then
    return
  end

  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  if not store.b[bufnr].client then
    return
  end

  render_cached(bufnr)

  local info = require("lsp-inlayhints.featureDebounce")._for("InlayHints", { min = 25 })
  local delay = is_insert and math.max(info.get(bufnr), 1250) or info.get(bufnr)
  scheduler:schedule(function()
    local client = vim.lsp.get_client_by_id(store.b[bufnr].client.id)
    local range = get_hint_ranges(client.offset_encoding)
    local params = get_params(range, bufnr)
    if not params then
      return
    end

    local uv = vim.loop
    local t1 = uv.hrtime()

    local method = adapter.method(bufnr)
    utils.request(client, bufnr, method, params, function(err, result, ctx)
      info.update(bufnr, (uv.hrtime() - t1) * 1e-6)
      on_refresh(err, result, ctx, range)
    end)
  end, delay)
end

return M
