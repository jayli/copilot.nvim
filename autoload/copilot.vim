" Copilot plugin for NeoVim
" Author by @bachi
let s:copilot_toolkit = has('nvim') ? v:lua.require("co-copilot") : v:null
let b:tabnine_typing_type = ""
let s:copilot_hint_snippet = []
" 当前敲入的字符所属的 ctx，主要用来判断光标前进还是后退
let b:typing_ctx = {}
let g:copilot_global_prompt = ''
let g:copilot_global_suffix = ''
let g:copilot_global_context = {}
let g:copilot_global_response_pos = {}
let g:copilot_req_queue = []
let g:copilot_suggest_timer = 0
let g:copilot_just_after_insert = 0
" 当前行前后各不超过 500 行
let s:lines_limit = g:copilot_lines_limit

function! copilot#cmp_visible()
  if s:installed_cmp_plugin() != "cmp" | return v:false | endif
lua << EOF
  local cmp = require('cmp')
  vim.b.copilot_cmp_visible = cmp.visible()
EOF
return b:copilot_cmp_visible
endfunction

function! copilot#cmp_select_next_item()
  if s:installed_cmp_plugin() != "cmp" | return v:false | endif
lua << EOF
  local cmp = require('cmp')
  local types = require('cmp.types')
  cmp.select_next_item({ behavior = types.cmp.SelectBehavior.Select })
EOF
endfunction

function! copilot#cmp_complete()
  if s:installed_cmp_plugin() != "cmp" | return v:false | endif
lua << EOF
local cmp = require('cmp')
cmp.complete()
EOF
endfunction

function! copilot#init()
  if !has('nvim')
    return v:false
  endif
  call v:lua.require("co-copilot").init()
  " py3 import copilot.copilot
  let b:typing_ctx = s:context()
  if !s:ready() | return | endif
  call timer_start(900, { -> s:bind_event_once()})
endfunction

function! s:check_single_enter()
  let l:enter = ''
  " 获取当前光标所在的行号
  let l:current_line_number = line(".")
  if l:current_line_number == 1 | return "" | endif
  " 获取当前行的内容
  let l:current_line_content = getline(l:current_line_number)
  let l:above_line_content = getline(l:current_line_number - 1)
  " 比较当前行内容和上一行的行内容
  if l:current_line_content =~# '^\s*$' && l:above_line_content !~# '^\s*$'
    " 如果当前行为空且上次的行不是空，则可能是因为按了回车
    let l:enter = 'single'
  elseif l:current_line_content =~# '^\s*$' && l:above_line_content =~# '^\s*$'
    let l:enter = 'double'
  endif
  " 更新上次的行内容
  let s:last_line_content = l:current_line_content
  return l:enter
endfunction

function! copilot#get_prompt()
  let curr_line = line('.')
  if line('.') > 1
    let start_line = 1
    if curr_line > s:lines_limit
      let start_line = curr_line - s:lines_limit
    endif
    let lines = getline(start_line, curr_line - 1)
    let line_str = join(lines, "\\n") . "\\n"
  else
    let line_str = ""
  endif
  let curr_line = getline('.')
  if empty(trim(curr_line))
    let curr_prefix = repeat(" ", col('.'))
  else
    let curr_prefix = strpart(curr_line, 0, col('.'))
  endif
  let prefix = line_str . curr_prefix
  return prefix
endfunction

function! copilot#get_suffix()
  let curr_line = line('.')
  let all_lines_count = line("$") " len(getline(1, '$'))
  let curr_suffix = strpart(getline('.'), col('.'))
  if curr_line < all_lines_count
    let start_line = curr_line + 1
    let end_line = all_lines_count
    if all_lines_count - start_line > s:lines_limit
      let end_line = start_line + s:lines_limit - 1
    endif
    let lines = getline(start_line, end_line)
    let suffix = curr_suffix . "\\n" . join(lines, "\\n")
  else
    let suffix = curr_suffix
  endif
  return suffix
endfunction

function! s:bind_event_once()
  if get(g:, 'copilot_binding_done')
    return
  endif
  let g:copilot_binding_done = 1

  if empty(maparg("\<Tab>", "i"))
    inoremap <silent><expr>  <Tab>  copilot#insert()
    return
  endif
  if empty(s:installed_cmp_plugin())
    if exists("g:copilot_trigger") && !empty("g:copilot_trigger")
      exec "inoremap <silent><expr>  " . g:copilot_trigger . "  copilot#tab_action()"
    else
      echom "Tab 键有冲突，请给 copilot 绑定其他补全键，比如 vim.g.copilot_trigger = '<c-m>'"
    endif
  else
    call timer_start(500, {
          \   -> s:lazy_bind_tab_action()
          \ })
  endif
  if s:installed_cmp_plugin() == "easycomplete"
    augroup copilot_cmp_done
      autocmd User easycomplete_pum_done call copilot#complete_done()
    augroup END
  elseif s:installed_cmp_plugin() == "cmp" || s:installed_cmp_plugin() == "coc"
    augroup copilot_cmp_done
      autocmd CompleteDone * call copilot#complete_done()
    augroup END
  endif
endfunction

function! s:lazy_bind_tab_action()
  iunmap <Tab>
  inoremap <silent><expr>  <Tab>  copilot#tab_action()
endfunction

function! copilot#complete_done()
  if !s:ready()
    return
  endif
endfunction

function! s:lazy_fire(delay)
  if g:copilot_just_after_insert == 1 " 如果是 Tab 后插入的结果要过滤掉
    call timer_stop(g:copilot_suggest_timer)
    let g:copilot_suggest_timer = 0
    let g:copilot_just_after_insert = 0
    call s:flush()
    return
  elseif g:copilot_suggest_timer > 0
    call timer_stop(g:copilot_suggest_timer)
    let g:copilot_suggest_timer = 0
  endif
  let g:copilot_suggest_timer = timer_start(a:delay, { -> s:fire() })
endfunction

function! s:stop_lazy_fire()
  if g:copilot_suggest_timer > 0
    call timer_stop(g:copilot_suggest_timer)
    let g:copilot_suggest_timer = 0
  endif
endfunction

function! copilot#tab_action()
  let cmp_plugin = s:installed_cmp_plugin()
  if s:copilot_snippet_ready()
    silent! noa call copilot#insert()
    return ""
  endif
  if cmp_plugin == "easycomplete"
    return easycomplete#CleverTab()
  elseif cmp_plugin == "coc"
    " TODO coc 也处理了snip的tab跳转的逻辑，这里也需要处理一下
    return coc#pum#visible() ? coc#pum#next(1) :
        \ copilot#check_back_space() ? "\<Tab>" :
        \ coc#refresh()
  elseif cmp_plugin == "cmp"
    if copilot#cmp_visible()
      call timer_start(1, { -> copilot#cmp_select_next_item() })
      return ""
    else
      call timer_start(1, { -> copilot#cmp_complete() })
      return ""
    endif
    return "\<Tab>"
  elseif cmp_plugin == "ultisnips" && UltiSnips#CanJumpForwards()
    " snip 内部位置的跳转
    call eval('feedkeys("\'. g:UltiSnipsJumpForwardTrigger .'")')
    return ""
  elseif cmp_plugin == "ultisnips" && index(keys(UltiSnips#SnippetsInCurrentScope()), s:get_typing_word()) >= 0
    " 如果当前词可以展开
    call feedkeys("\<C-R>=UltiSnips#ExpandSnippetOrJump()\<cr>")
    return ""
  endif
  return "\<Tab>"
endfunction

function! copilot#check_back_space() abort
  let col = col('.') - 1
  return !col || getline('.')[col - 1]  =~# '\s'
endfunction

" 兼容 cmp/coc/easycomplete/UltiSnips
" TODO UltiSnips 也会绑定 tab 键，也需要兼容掉
function! s:installed_cmp_plugin()
  if exists("*easycomplete#Enable") && exists("g:easycomplete_enable") && g:easycomplete_enable == 1
    return "easycomplete"
  elseif exists("g:did_coc_loaded")
    return "coc"
  elseif exists("g:loaded_cmp") && g:loaded_cmp == v:true
    return "cmp"
  elseif s:ultisnips_support()
    return "ultisnips"
  endif
  return ""
endfunction

function! s:ultisnips_support()
  if !has("python3")
    return v:false
  endif
  if exists("g:UltiSnipsExpandTrigger")
    return v:true
  else
    return v:false
  endif
endfunction

function! copilot#insert()
  if !s:copilot_snippet_ready()
    return "\<Tab>"
  endif
  call timer_start(90, { -> s:insert() })
  return ""
endfunction

function! copilot#cursor_moved_i()
  if !s:ready() | return | endif
  call s:flush()
endfunction

function! copilot#text_changed_i()
  if !s:ready() | return | endif
  if !exists('b:copilot_backing')
    let b:copilot_backing = 0
  endif
  if s:backchecking()
    let b:copilot_backing = 1
  else
    let b:copilot_backing = 0
  endif
  " call s:console('text_changed_i', s:isbacking() ? "<-" : "->")

  if s:isbacking()
    call s:flush()
    call s:stop_lazy_fire()
    return
  endif
  let l:enter = s:check_single_enter()

  if l:enter == "double" "连续回车
    call s:flush()
    call s:stop_lazy_fire()
    return
  endif

  if l:enter == "single" " 单回车
    call s:lazy_fire(700)
  elseif l:enter == ""  " 没有回车，正常输入
    call s:lazy_fire(700)
  endif
endfunction

function! copilot#cursor_hold_i()
endfunction

" 主要判断哪些情况不要触发
function! s:ready()
  if !exists("g:copilot_apikey") || empty(g:copilot_apikey)
    return v:false
  endif
  if &filetype == "none" || &buftype == "nofile" || &buftype == "terminal"
    return v:false
  endif
  return v:true
endfunction

function! copilot#insert_leave()
  if !s:ready() | return | endif
  call s:flush()
endfunction

function! copilot#cursor_hold()
  if !s:ready() | return | endif
  call s:flush()
endfunction

function! copilot#insert_enter()
  if !s:ready() | return | endif
  call s:flush()
  let g:copilot_just_after_insert = 1
  call timer_start(90, { -> s:reset_copilot_insert_flag() })
endfunction

function! s:reset_copilot_insert_flag()
  let g:copilot_just_after_insert = 0
endfunction


function! copilot#complete_changed()
  if !s:ready() | return | endif
  call s:flush()
endfunction

function! s:isbacking()
  if !exists('b:copilot_backing')
    let b:copilot_backing = 0
  endif
  return b:copilot_backing
endfunction

function! s:trim_start(str)
  return substitute(a:str, "^\\s\\+\\(.\\{\-}\\)$","\\1","g")
endfunction

function! s:trim_end(str)
  return substitute(a:str, "^\\(.\\{\-}\\)\\s\\+$","\\1","g")
endfunction

function! s:backchecking()
  let curr_ctx = s:context()
  if !exists('b:typing_ctx')
    let b:typing_ctx = s:context()
  endif
  let old_ctx = deepcopy(b:typing_ctx)
  let b:typing_ctx = curr_ctx
  if empty(curr_ctx) || empty(old_ctx) | return v:false | endif
  if get(curr_ctx, 'lnum') == get(old_ctx,'lnum')
        \ && strlen(get(old_ctx,'typed',"")) >= 2
    if curr_ctx['typed'] ==# old_ctx['typed'][:-2]
      " 单行后退非到达首字母的后退
      return v:true
    endif
    if s:trim_end(curr_ctx['typed']) ==# s:trim_end(old_ctx['typed']) &&
          \ strlen(curr_ctx['typed']) < strlen(old_ctx['typed'])
      " 单行回退只删除空格或者删除tab
      return v:true
    endif
    if curr_ctx['typed'] ==# old_ctx['typed'] && strlen(curr_ctx['line']) == strlen(old_ctx['line']) - 1
      " 单行在 Normal 模式下按下 s 键
      return v:true
    endif
  elseif get(curr_ctx,'lnum') == get(old_ctx,'lnum')
        \ && strlen(old_ctx['typed']) == 1 && strlen(curr_ctx['typed']) == 0
    " 单行后退到达首字母的后退
    return v:true
  elseif old_ctx['lnum'] == curr_ctx['lnum'] + 1 && old_ctx['col'] == 1
    " 隔行后退
    return v:true
  else
    return v:false
  endif
  return v:false
endfunction

function! s:context() abort
  let l:ret = {
        \ 'bufnr':bufnr('%'),
        \ 'curpos':getcurpos(),
        \ 'changedtick':b:changedtick
        \ }
  let l:ret['lnum'] = l:ret['curpos'][1] " 行号
  let l:ret['col'] = l:ret['curpos'][2] " 列号
  let l:ret['filetype'] = &filetype " filetype
  let l:ret['filepath'] = expand('%:p') " filepath
  let line = getline(l:ret['lnum']) " 当前行内容
  let l:ret['line'] = line
  let l:ret['typed'] = strpart(line, 0, l:ret['col']-1) " 光标前敲入的内容
  let l:ret['char'] = strpart(line, l:ret['col']-2, 1) " 当前单个字符
  let l:ret['typing'] = s:get_typing_word() " 当前敲入的单词
  let l:ret['startcol'] = l:ret['col'] - strlen(l:ret['typing']) " 单词起始位置
  return l:ret
endfunction

function! copilot#cache_response_pos(lnum, col)
  let g:copilot_global_response_pos["lnum"] = a:lnum
  let g:copilot_global_response_pos["col"] = a:col
endfunction

function! copilot#lang()
  return &filetype
endfunction

function! s:same_pos()
  let c = s:context()
  if get(g:copilot_global_response_pos, "lnum") == c["lnum"] &&
        \ get(g:copilot_global_response_pos, "col") == c["col"]
    return v:true
  else
    return v:false
  endif
endfunction

function! copilot#context()
  return s:context()
endfunction

function! s:get_typing_word()
  let start = col('.') - 1
  let line = getline('.')
  let width = 0
  if index(["php"], &filetype) >= 0
    let regx = '[$a-zA-Z0-9_#]'
  else
    let regx = '[a-zA-Z0-9_#]'
  endif
  while start > 0 && line[start - 1] =~ regx
    let start = start - 1
    let width = width + 1
  endwhile
  let word = strpart(line, start, width)
  return word
endfunction

function! s:show_hint(snippet_array)
  call s:copilot_toolkit.show_hint(a:snippet_array)
endfunction

function! s:loading_start()
  call s:copilot_toolkit.loading_start()
endfunction

function! copilot#loading_start()
  call s:loading_start()
endfunction

function! s:loading_stop()
  call s:copilot_toolkit.loading_stop()
endfunction

function! copilot#loading_stop()
  call s:loading_stop()
endfunction

function! s:fire()
  if pumvisible()
    return
  endif
  " 不是空格除外的最后一个字符
  if !s:is_last_char()
    return
  endif
  " 不是魔术指令
  if getline('.')[0:col('.')] =~ "\\s\\{-}TabNine::\\(config\\|sem\\)$"
    return
  endif
  " 保险起见，触发时机的范围也尽可能的缩小，连 loading 都尽可能不要显示
  let cmp_plugin = s:installed_cmp_plugin()
  if cmp_plugin == "easycomplete" && s:easycomplete_pum_visible()
    return
  endif
  if cmp_plugin == "coc" && coc#pum#visible()
    return
  endif
  if cmp_plugin == "cmp" && copilot#cmp_visible()
    return
  endif

  call s:flush()
  call s:suggest_flag_set()
  let g:copilot_global_prompt = copilot#get_prompt()
  let g:copilot_global_suffix = copilot#get_suffix()
  let g:copilot_global_context = copilot#context()
  " py3 Util.do_complete()
  try
    call DoCopilotComplete()
  catch /117/
    " silent! noa UpdateRemotePlugins
    " call DoCopilotComplete()
  endtry
endfunction

function! s:not_insert_mode()
  return mode() == 'i' ? v:false : v:true
endfunction

function! s:easycomplete_pum_visible()
  if s:installed_cmp_plugin() != "easycomplete"
    return v:false
  endif
  if !exists("*easycomplete#pum#visible")
    return v:false
  endif
  return (has('nvim') && easycomplete#pum#visible()) || (!has('nvim') && pumvisible())
endfunction

function! copilot#callback(res_str)
  if s:not_insert_mode()
    call s:flush()
    return
  endif
  if pumvisible()
    call s:flush()
    return
  endif
  " callback 时候的条件过滤，尽量不干扰当前正在进行的输入
  " 特别是在complete可见的情况下，直接将结果丢弃
  if s:installed_cmp_plugin() == "easycomplete" && s:easycomplete_pum_visible()
    call s:flush()
    return
  endif
  if s:installed_cmp_plugin() == "cmp" && copilot#cmp_visible()
    call s:flush()
    return
  endif
  if s:installed_cmp_plugin() == "coc" && coc#pum#visible()
    call s:flush()
    return
  endif
  if a:res_str == "{timeout}"
    " 超时
    call s:flush()
    return
  elseif a:res_str == "{429}"
    " 限流
    call s:flush()
    return
  elseif a:res_str == "{error}"
    " 权限校验失败
    call s:flush()
    return
  elseif a:res_str == "{cancelled}"
    " 被取消
    call s:flush()
    return
  endif
  " 如果请求copilot服务器时光标所在位置和snippet返回时光标位置不相同，则丢弃
  if !s:same_pos()
    call s:flush()
    return
  endif
  let l:snippet = s:get_snippets(a:res_str)
  let l:snippet_array = s:parse_snippets2array(l:snippet)
  call s:show_hint(l:snippet_array)
  let s:copilot_hint_snippet = deepcopy(l:snippet_array)
endfunction

function! s:copilot_snippet_ready()
  return exists("s:copilot_hint_snippet") && !empty(s:copilot_hint_snippet)
endfunction

function! copilot#copilot_snippet_ready()
  return s:copilot_snippet_ready()
endfunction

function! s:remove_blank_spaces(res_str)
  " echom '>>>'
  " echom a:res_str
  " echom strlen(a:res_str)
  " echom '====='
  let l:ret = a:res_str
  " 如果是空行，把开头的\n去掉
  if empty(trim(getline('.')))
    let l:ret = substitute(l:ret, '^\\n', '', '')
  endif
  let l:ret = substitute(l:ret, '\\n\\n$', '\\n', '')
  " 如果光标不在首行，去掉开头的空格
  if col('.') >= 3
    let l:ret = s:trim_start(l:ret)
  endif
  let l:ret = s:trim_end(l:ret)
  " echom l:ret
  " echom strlen(l:ret)
  " echom '<<<'
  return l:ret
  if !empty(trim(getline('.')))
    return a:res_str
  endif
  let space_counts = col('.')
  let o_res_str = deepcopy(a:res_str)
  let removed_space_count = 0
  for i in range(space_counts)
    if o_res_str[i] == " "
      let removed_space_count += 1
    else
      break
    endif
  endfor
  return o_res_str[removed_space_count:]
endfunction

" 返回一个字符串，包含"\n"
function! s:get_snippets(res_str)
  return s:remove_blank_spaces(a:res_str)
endfunction

" 返回一个标准数组，提示和显示都用这一份数据
function! s:parse_snippets2array(code_block)
  if a:code_block[0:1] == "\\n"
    let prefix = [""]
  else
    let prefix = []
  endif
  if a:code_block[-2:] == "\\n"
    let suffix = [""]
  else
    let suffix = []
  endif
  let l:lines = split(a:code_block, "\\\\n")
  return prefix + l:lines + suffix
endfunction

function! s:flush()
  call s:loading_stop()
  try
    call CancelCopilotComplete()
  catch
    " silent! noa UpdateRemotePlugins
    " call CancelCopilotComplete()
  endtry

  if exists("s:copilot_hint_snippet") && empty(s:copilot_hint_snippet)
    return
  endif
  call s:copilot_toolkit.delete_hint()
  call s:suggest_flag_clear()
  let s:copilot_hint_snippet = []
  let g:copilot_global_prompt = ""
  let g:copilot_global_suffix = ""
  let g:copilot_global_context = {}
  let g:copilot_global_response_pos = {}
  let g:copilot_just_after_insert = 0
endfunction

function! s:nr()
  call appendbufline(bufnr(""), line("."), "")
  call cursor(line(".") + 1, 1)
endfunction

function! s:insert()
  let l:copilot_hint_snippet = s:copilot_hint_snippet
  call s:flush()
  try
    let l:lines = l:copilot_hint_snippet
    if len(l:lines) == 1 " 单行插入
      if getline('.') == ""
        call execute("normal! \<Esc>")
        call setbufline(bufnr(""), line("."), l:lines[0])
        call cursor(line('.'), len(l:lines[0]))
        call s:remain_insert_mode()
      else
        call feedkeys(l:lines[0], 'i')
      endif
    elseif len(l:lines) > 1 " 多行插入
      call execute("normal! \<Esc>")
      let curr_line_nr = line('.')
      let curr_line_str = getline(".")
      call setbufline(bufnr(""), line("."), curr_line_str . l:lines[0])
      for line in l:lines[1:]
        call s:nr()
        call setbufline(bufnr(""), line("."), line)
      endfor

      let end_line_nr = curr_line_nr + len(l:lines) - 1
      call cursor(end_line_nr, len(getline(end_line_nr)))
      call s:remain_insert_mode()
      redraw
    endif
    let g:copilot_just_after_insert = 1
  catch
    echom v:exception
  endtry
endfunction

function! s:remain_insert_mode()
  if mode() == "i"
    call feedkeys("\<Esc>A", 'in')
  else
    call execute("normal! A")
  endif

  if exists("*easycomplete#zizz")
    call easycomplete#zizz()
  endif
endfunction

function! s:suggest_flag_set()
  let b:tabnine_typing_type = "suggest"
  call timer_start(800, { -> s:suggest_flag_clear()})
endfunction

function! s:suggest_flag_clear()
  let b:tabnine_typing_type = ""
endfunction

function! s:is_last_char()
  let current_col = col('.')
  let current_line = getline('.')
  if current_col - 1 == len(current_line)
    return v:true
  endif
  let rest_of_line = current_line[current_col - 1:]
  if rest_of_line =~ "^\\s\\+$"
    return v:true
  else
    return v:false
  endif
endfunction

function! s:is_gui()
  return (has("termguicolors") && &termguicolors == 1) ? v:true : v:false
endfunction

function! copilot#get_bgcolor(name)
  return s:get_hi_color(a:name, "bg")
endfunction

function! copilot#get_fgcolor(name)
  return s:get_hi_color(a:name, "fg")
endfunction

function! copilot#regist_rplugin()
  if !exists("*remote#host#PluginsForHost") | finish | endif
  let plugins = remote#host#PluginsForHost("python3")
  let l:installed = 0
  for item in plugins
    if item["path"] =~ "copilot\\.nvim"
      let l:installed = 1
      break
    endif
  endfor
  if l:installed == 0
    silent! noa UpdateRemotePlugins
    echom ">> 'copilot.nvim/rplugin/copilot.py' installed, Please restart your neovim."
  endif
endfunction

" Get color from a scheme group
function! s:get_hi_color(hi_name, sufix)
  let sufix = empty(a:sufix) ? "bg" : a:sufix
  let hi_string = s:hi_args(a:hi_name)
  let my_color = "NONE"
  if empty(hi_string) | return my_color | endif
  if s:is_gui()
    " Gui color name
    let my_color = matchstr(hi_string,"\\(\\sgui" . sufix . "=\\)\\@<=#\\{-}\\w\\+")
    if empty(my_color)
      let links_group = matchstr(hi_string, "\\(links\\sto\\s\\+\\)\\@<=\\w\\+")
      if !empty(links_group)
        let my_color = s:get_hi_color(links_group, a:sufix)
      endif
    endif
  else
    let my_color = matchstr(hi_string,"\\(\\scterm" .sufix. "=\\)\\@<=\\w\\+")
  endif

  if my_color == ""
    return "NONE"
  endif

  return my_color
endfunction

function! s:hi_args(name)
  try
    let val = 'hi ' . substitute(split(execute('hi ' . a:name), '\n')[0], '\<xxx\>', '', '')
  catch /411/
    return ""
  endtry
  return val
endfunction

function! s:console(...)
  try
    return call('easycomplete#log#log', a:000)
  catch
    echom v:exception
  endtry
endfunction
