
function s:noop(...)
endfunction

" Configuration settings
let g:mergetool_layout = get(g:, 'mergetool_layout', 'mr')
let g:mergetool_prefer_revision = get(g:, 'mergetool_prefer_revision', 'local')
let g:MergetoolSetLayoutCallback = get(g:, 'MergetoolSetLayoutCallback', function('s:noop'))

" {{{ Public exports

let g:mergetool_in_merge_mode = 0

let s:run_as_git_mergetool = 0
let s:current_layout = ''

function! mergetool#start() "{{{
  " If file does not have conflict markers, it's a wrong target for mergetool
  if !s:has_conflict_markers()
    echohl WarningMsg
    echo "File does not have correct conflict markers"
    echohl None
    return
  endif

  " It's required to use diff3 conflict style, so markers include common base revision
  if !s:has_conflict_markers_in_diff3_style()
    echohl WarningMsg
    echo "Conflict markers miss common base revision. Ensure you're using 'merge.conflictStyle=diff3' in your gitconfig"
    echohl None
    return
  endif

  " Remember original file properties
  let s:mergedfile_bufnr = bufnr('%')
  let s:mergedfile_name = expand('%')
  let s:mergedfile_contents = join(getline(0, "$"), "\n") . "\n"
  let s:mergedfile_fileformat = &fileformat
  let s:mergedfile_filetype = &filetype

  " Detect if we're run as 'git mergetool' by presence of BASE|LOCAL|REMOTE buf names
  let s:run_as_git_mergetool = bufnr('BASE') != -1 &&
        \ bufnr('LOCAL') != -1 &&
        \ bufnr('REMOTE') != -1

  " Open in new tab, do not break existing layout
  if !s:run_as_git_mergetool
    tab split
  endif

  let g:mergetool_in_merge_mode = 1

  call mergetool#prefer_revision(g:mergetool_prefer_revision)
  call mergetool#set_layout(g:mergetool_layout)
endfunction "}}}

" Stop mergetool effect depends on:
" - when run as 'git mergetool'
" - when run from Vim directly on file with conflict markers

" When run as 'git mergetool', to decide merge result Git would check:
" - whether file was changed, if 'mergetool.trustExitCode' == false
" - mergetool program exit code, otherwise
function! mergetool#stop() " {{{
  call s:ensure_in_mergemode()

  while 1
    let choice = input('Was the merge successful? (y)es, (n)o, (c)ancel: ')
    if choice ==? 'y' || choice ==? 'n' || choice ==? 'c'
      break
    endif
  endwhile
  redraw!

  if choice ==? 'c'
    return
  endif

  " Load buffer with merged file
  execute "buffer " . s:mergedfile_bufnr

  if s:run_as_git_mergetool
    " When run as 'git mergetool', and merge was unsuccessful
    " discard local changes and do not write buffer to disk
    " also exit with nonzero code

    if choice ==? 'n'
      edit!
      cquit
    else
      write
      qall!
    endif

  else
    " When run directly from Vim,
    " just restore merged file buffer to the original version
    " and close tab we've opened on start

    if choice ==? 'n'
      silent call s:restore_merged_file_contents()
    else
      write
    endif

    let g:mergetool_in_merge_mode = 0
    tabclose
  endif
endfunction " }}}


function! mergetool#toggle() " {{{
  if g:mergetool_in_merge_mode
    call mergetool#stop()
  else
    call mergetool#start()
  endif
endfunction " }}}

" Opens set of windows with merged file and various file revisions
" Supported layout options:
" - w, 'MERGED' revision as passed by Git, or working tree version of merged file
" - r, revision obtained by removing conflict markers and picking up 'theirs' side
" - R, 'REMOTE' revision as passed by Git, or revision for unmerged file obtained from index stage :3:<file>
" - l, revision obtained by removing conflict markers and picking up 'ours' side
" - L, 'LOCAL' revision as passed by Git, or revision for unmerged file obtained from index stage :2:<file>
" - b, revision obtained by removing conflict markers and picking up 'common' side
" - B, 'BASE' revision as passed by Git, or revision for unmerged file obtained from index stage :1:<file>
function! mergetool#set_layout(layout) " {{{
  call s:ensure_in_mergemode()

  if a:layout =~? '[^rlbm,]'
    throw "Unknown layout option: " . a:layout
  endif

  let splits = []

  let abbrevs = {
        \ 'b': 'base',
        \ 'B': 'BASE',
        \ 'r': 'remote',
        \ 'R': 'REMOTE',
        \ 'l': 'local',
        \ 'L': 'LOCAL' }
  let is_first_split = 1
  let split_dir = 'vert rightbelow'

  if s:goto_win_with_merged_file()
    let l:_winstate = winsaveview()
  endif

  " Before changing layout, turn off diff mode in all visible windows
  windo diffoff

  " For each char in layout, open split window and load revision
  for labbr in split(a:layout, '\zs')

    " ',' is to make next split horizontal
    if labbr ==? ','
      let split_dir='botright'
      continue
    endif

    " Create next split, and reset split direction to vertical
    execute split_dir . " split"
    let split_dir = 'vert rightbelow'

    " After first split is created, close all other windows
    if is_first_split
      wincmd o
      let is_first_split = 0
    endif

    if labbr ==? 'm'
      " For merged file itself, just load its buffer
      execute "buffer " . s:mergedfile_bufnr
    else
      silent call s:load_revision(abbrevs[labbr])
    endif

    call add(splits, {
          \ 'layout': a:layout,
          \ 'split': labbr,
          \ 'filetype': s:mergedfile_filetype,
          \ 'bufnr': bufnr(''),
          \ 'winnr': winnr() })
  endfor

  let s:current_layout = a:layout
  windo diffthis

  " Iterate over created splits and fire callback
  for l:split in splits
    execute "noautocmd " . l:split["winnr"] . "wincmd w"
    call g:MergetoolSetLayoutCallback(l:split)
  endfor

  if s:goto_win_with_merged_file() && exists('l:_winstate')
    call winrestview(l:_winstate)
  endif
endfunction " }}}

" Toggles between given and default layout
function mergetool#toggle_layout(layout) " {{{
  if s:current_layout !=# a:layout
    call mergetool#set_layout(a:layout)
  else
    call mergetool#set_layout(g:mergetool_layout)
  endif
endfunction " }}}

" Takes merged file with conflict markers, and removes them
" by picking up side of the conflicts: local, remote, base
function! mergetool#prefer_revision(revision) " {{{
  call s:ensure_in_mergemode()

  silent call s:goto_win_with_merged_file()
  silent call s:restore_merged_file_contents()
  if a:revision !=# 'unmodified'
    silent call s:remove_conflict_markers(a:revision)
  endif
endfunction " }}}

" }}}

" Private functions{{{

let s:markers = {
      \ 'ours': '^<<<<<<< ',
      \ 'theirs': '^>>>>>>> ',
      \ 'base': '^||||||| ',
      \ 'delimiter': '^=======\r\?$' }

" Loads file revision in current window
function! s:load_revision(revision)
  if a:revision ==# 'base' || a:revision ==# 'remote' || a:revision ==# 'local'

    " Open new buffer, put merged file contents wiht conflict markers,
    " remove markers and pick up right revision
    enew
    execute "setlocal fileformat=" . s:mergedfile_fileformat
    put = s:mergedfile_contents | 1delete _
    call s:remove_conflict_markers(a:revision)
    setlocal nomodifiable readonly buftype=nofile bufhidden=delete nobuflisted
    execute "setlocal filetype=" . s:mergedfile_filetype
    execute "file " . a:revision
  elseif a:revision ==# 'BASE' || a:revision ==# 'REMOTE' || a:revision ==# 'LOCAL'

    " First, if run as 'git mergetool', try find buffer by name: 'BASE|REMOTE|LOCAL'
    " Otherwise, load revision from Git index
    if s:run_as_git_mergetool
      execute "buffer " . a:revision
      setlocal nomodifiable readonly
    else
      enew
      call s:load_revision_from_index(a:revision)
      setlocal nomodifiable readonly buftype=nofile bufhidden=delete nobuflisted
      execute "setlocal filetype=" . s:mergedfile_filetype
      execute "file " . a:revision
    endif
  else
    throw "Not supported revision: " . a:revision
  endif
endfunction


" Loads revision of unmerged file from Git's index
" See https://git-scm.com/book/en/v2/Git-Tools-Advanced-Merging
" Reminder on unmerged revisions stored in index stages
" $ git show :1:hello.rb > hello.base.rb
" $ git show :2:hello.rb > hello.ours.rb
" $ git show :3:hello.rb > hello.theirs.rb
function! s:load_revision_from_index(revision)

  let index = {
        \ 'BASE': 1,
        \ 'LOCAL': 2,
        \ 'REMOTE': 3 }
  execute printf("read !git cat-file -p :%d:%s", index[a:revision], s:mergedfile_name)
  silent 1delete _
endfunction

" Removes conflict markers from current file, leaving one side of the conflict
function! s:remove_conflict_markers(pref_revision)
  " Reminder on git conflict markers

  " <<<<<<< ours
  " ours pref_revision
  " ||||||| base
  " base pref_revision
  " =======
  " theirs pref_revision
  " >>>>>>> theirs


  " Command removes range of lines from the file
  " g/{start_marker}/, find start of the range by given marker
  " .,/{end_marker}, finds end of the range by given marker
  let delete_range = 'g/%s/ .,/%s/ delete _'
  let delete_marker = 'g/%s/ delete _'

  if a:pref_revision ==# 'base'
    execute printf(delete_range, s:markers['ours'], s:markers['base'])
    execute printf(delete_range, s:markers['delimiter'], s:markers['theirs'])
  elseif a:pref_revision ==# 'local'
    execute printf(delete_marker, s:markers['ours'])
    execute printf(delete_range, s:markers['base'], s:markers['theirs'])
  elseif a:pref_revision ==# 'remote'
    execute printf(delete_range, s:markers['ours'], s:markers['delimiter'])
    execute printf(delete_marker, s:markers['theirs'])
  else
    throw "Not supported revision: " . a:pref_revision
  endif
endfunction

" Tells if file has conflict markers
function! s:has_conflict_markers()
  return search(s:markers['ours'], 'w') != 0 &&
        \ search(s:markers['theirs'], 'w') != 0 &&
        \ search(s:markers['delimiter'], 'w') != 0
endfunction

function s:has_conflict_markers_in_diff3_style()
  return search(s:markers['base'],'w') != 0
endfunction

" Discard all changes in buffer, and fill it with original merged file contents
function! s:restore_merged_file_contents()
  %delete _ | put =s:mergedfile_contents | 1delete _
endfunction

" Find window with merged file and focus it
" Tell if window was found
function! s:goto_win_with_merged_file()
  let l:winnr = bufwinnr(s:mergedfile_bufnr)
  execute "noautocmd " . bufwinnr(s:mergedfile_bufnr) . "wincmd w"
  return l:winnr != -1
endfunction

function! s:ensure_in_mergemode()
  if !g:mergetool_in_merge_mode
    throw "Not in a merge mode"
  endif
endfunction

" }}}
