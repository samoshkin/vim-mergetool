
" check whether this script is already loaded
if exists("g:loaded_mergetool")
  finish
endif
let g:loaded_mergetool = 1

let g:mergetool_in_merge_mode = 0

command! -nargs=0 MergetoolStart call mergetool#start()
command! -nargs=0 MergetoolStop call mergetool#stop()
command! -nargs=0 MergetoolToggle call mergetool#toggle()
command! -nargs=1 MergetoolSetLayout call mergetool#set_layout(<f-args>)
command! -nargs=1 MergetoolToggleLayout call mergetool#toggle_layout(<f-args>)
command! -nargs=0 MergetoolPreferLocal call mergetool#prefer_revision('local')
command! -nargs=0 MergetoolPreferRemote call mergetool#prefer_revision('remote')

nnoremap <silent> <Plug>(MergetoolToggle) :<C-u>call mergetool#toggle()<CR>

" {{{ Diff exchange

" Do either diffget or diffput, depending on given direction
" and whether the window has adjacent window in a given direction
" h|<left> + window on right = diffget from right win
" h|<left> + no window on right = diffput to left win
" l|<right> + window on left = diffget from left win
" l|<right> + no window on left = diffput to right win
" Same logic applies for vertical directions: 'j' and 'k'

let s:directions = {
      \ 'h': 'l',
      \ 'l': 'h',
      \ 'j': 'k',
      \ 'k': 'j' }

function s:DiffExchange(dir)
  let oppdir = s:directions[a:dir]

  let winoppdir = s:FindWindowOnDir(oppdir)
  if (winoppdir != -1)
    execute "diffget " . winbufnr(winoppdir)
  else
    let windir = s:FindWindowOnDir(a:dir)
    if (windir != -1)
      execute "diffput " . winbufnr(windir)
    else
      echohl WarningMsg
      echo 'Cannot exchange diff. Found only single window'
      echohl None
    endif
  endif
endfunction

" Finds window in given direction and returns it win number
" If no window found, returns -1
function s:FindWindowOnDir(dir)
  let oldwin = winnr()

  execute "noautocmd wincmd " . a:dir
  let curwin = winnr()
  if (oldwin != curwin)
    noautocmd wincmd p
    return curwin
  else
    return -1
  endif
endfunction

" Commands and <plug> mappings for diff exchange commands
command! -nargs=0 MergetoolDiffExchangeLeft call s:DiffExchange('h')
command! -nargs=0 MergetoolDiffExchangeRight call s:DiffExchange('l')
command! -nargs=0 MergetoolDiffExchangeDown call s:DiffExchange('j')
command! -nargs=0 MergetoolDiffExchangeUp call s:DiffExchange('k')

nnoremap <silent> <Plug>(MergetoolDiffExchangeLeft) :<C-u>call <SID>DiffExchange('h')<CR>
nnoremap <silent> <Plug>(MergetoolDiffExchangeRight) :<C-u>call <SID>DiffExchange('l')<CR>
nnoremap <silent> <Plug>(MergetoolDiffExchangeDown) :<C-u>call <SID>DiffExchange('j')<CR>
nnoremap <silent> <Plug>(MergetoolDiffExchangeUp) :<C-u>call <SID>DiffExchange('k')<CR>

" }}}
