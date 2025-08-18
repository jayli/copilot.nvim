local M = {}
local loading_ns = vim.api.nvim_create_namespace('loading_ns')
local loading_timer = vim.loop.new_timer()
local loading_chars = {'⠇','⠋','⠙','⠸','⢰','⣠','⣄','⡆'}
local original_statusline = nil 
local cursor = 1

-- 提取 statusline 中第一个元素的高亮组
local function get_first_highlight_group(statusline)
  -- 正则匹配第一个 %#xxx# 高亮组定义
  local hl_start = statusline:match("%%#(.-)#")
  if hl_start then
    return hl_start
  end
  -- 如果没有显式指定高亮组，则使用默认的 StatusLine
  return "StatusLine"
end

-- 插入带样式的字符到 statusline 开头
function M.prepend_char_to_statusline(char)
  prefix_hl_group = get_first_highlight_group(original_statusline)
  -- 在开头插入带高亮的字符
  local new_statusline = "%#" .. prefix_hl_group .. "#" .. char .. "" .. string.sub(original_statusline, 2, #original_statusline)
  -- 设置新的 statusline
  -- vim.o.statusline = new_statusline
  local current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_option(current_win, "statusline", new_statusline)
  -- 可选：强制刷新一次状态栏
  -- vim.cmd("redrawstatus")
end

function set_loading_interval(interval, callback)
  loading_timer:start(interval, interval, function ()
    callback()
  end)
end

function clear_loading_interval()
  loading_timer:stop()
end

function M.start()
  M.statusline_start_loading()
  -- M.marker_start_loading()
end

function M.marker_start_loading()
  set_loading_interval(90, function()
    vim.schedule(function()
      if cursor == 1 then
        if not vim.fn.mode() == 'i' then
          M.stop()
        end
      end
      vim.api.nvim_buf_set_extmark(0, loading_ns, vim.fn.line('.') - 1, vim.fn.col('.') - 1, {
          id = 2,
          virt_text_pos = "eol",
          virt_text = {{tostring(M.get_loading_str()) .. "", "SuggestionFirstLine"}},
          virt_lines = nil
        })
    end)
  end)
end

function M.marker_stop_loading()
  if type(loading_timer) == "userdata" then
    clear_loading_interval()
    vim.api.nvim_buf_del_extmark(0, loading_ns, 2)
  end
end

function M.stop()
  M.statusline_stop_loading()
  -- M.marker_stop_loading()
end

function M.get_loading_str()
  if cursor < #loading_chars then
    cursor = cursor + 1
  elseif cursor == #loading_chars then
    cursor = 1
  end
  return loading_chars[cursor]
end

-- 启动 loading：在状态栏最前插入 loading 动画
function M.statusline_start_loading()
  -- 保存原始状态栏
  original_statusline = vim.o.statusline

  -- 构造新的状态栏：加入 loading 前缀
  -- 创建定时器，强制刷新状态栏以更新动画
  set_loading_interval(90, function()
    vim.schedule(function()
      if cursor == 1 then
        if not vim.fn.mode() == 'i' then
          M.stop_loading()
        end
      end
      -- local new_statusline = M.get_loading_str() .. original_statusline
      M.prepend_char_to_statusline(M.get_loading_str())
      -- vim.o.statusline = new_statusline
      -- vim.cmd("redrawstatus")
    end)
  end)
end


-- 停止 loading：恢复原始状态栏
function M.statusline_stop_loading()
  if not loading_timer then return end
  if type(loading_timer) == "userdata" then
    clear_loading_interval()
    if original_statusline then
      vim.o.statusline = original_statusline
    end
    vim.cmd("redrawstatus")
  end
end
return M
