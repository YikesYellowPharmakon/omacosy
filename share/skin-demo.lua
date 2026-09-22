local buf = vim.api.nvim_get_current_buf()
local ns = vim.api.nvim_create_namespace("omacosy-skin")

local function mark(word, severity, message)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local col = line:find(word, 1, true)
    if col then
      return {
        lnum = i - 1,
        col = col - 1,
        end_lnum = i - 1,
        end_col = col - 1 + #word,
        message = message,
        severity = severity,
      }
    end
  end
end

local sev = vim.diagnostic.severity
local items = {
  mark("Palette", sev.ERROR, "错误"),
  mark("return", sev.WARN, "警告"),
  mark("THEME", sev.INFO, "信息"),
  mark("steps", sev.HINT, "提示"),
}
local diags = {}
for _, item in ipairs(items) do
  if item then
    table.insert(diags, item)
  end
end
vim.diagnostic.set(ns, buf, diags)
vim.fn.matchadd("Search", "omacosy")
vim.fn.matchadd("IncSearch", "rose")
vim.fn.search("def mix", "w")
