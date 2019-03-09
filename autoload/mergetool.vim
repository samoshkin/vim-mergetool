
let g:mergetool_layout = get(g:, 'mergetool_layout', 'wr')
let g:mergetool_prefer_revision = get(g:, 'mergetool_prefer_revision', 'local')

" {{{ Public exports

let s:in_merge_mode = 0

function! mergetool#start() "{{{
  " If file does not have conflict markers, it's a wrong target for mergetool
  if !s:has_conflict_markers()
    echohl WarningMsg
    echo 'File does not have conflict markers'
    echohl None
    return
  endif

  " Remember original file properties
  let s:mergedfile_bufnr = bufnr('%')
  let s:mergedfile_name = expand('%')
  let s:mergedfile_contents = system('cat ' . expand('%'))

  " Open in new tab, do not break existing layout
  if !s:is_run_as_git_mergetool()
    tab split
  endif

  let s:in_merge_mode = 1

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
  call s:goto_win_with_merged_file()

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


  if s:is_run_as_git_mergetool()
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

    let s:in_merge_mode = 0
    tabclose
  endif
endfunction " }}}


function! mergetool#toggle() " {{{
  if s:in_merge_mode
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

  if a:layout =~? '[^rlbw]'
    throw "Unknown layout option: " . a:layout
  endif

  let abbrevs = {
        \ 'b': 'base',
        \ 'B': 'BASE',
        \ 'r': 'remote',
        \ 'R': 'REMOTE',
        \ 'l': 'local',
        \ 'L': 'LOCAL' }
  let is_first_split = 1

  " For each char in layout, open split window and load revision
  for labbr in split(a:layout, '\zs')
    vert rightbelow split

    if is_first_split
      wincmd o
      let is_first_split = 0
    endif

    " For merged file itself, just load its buffer
    if labbr ==? 'w'
      execute "buffer " . s:mergedfile_bufnr
      continue
    endif

    silent call s:load_revision(abbrevs[labbr])
  endfor

  windo diffthis
  call s:goto_win_with_merged_file()
endfunction " }}}

" Takes merged file with conflict markers, and removes them
" by picking up side of the conflicts: local, remote, base
function! mergetool#prefer_revision(revision) " {{{
  call s:ensure_in_mergemode()

  silent call s:goto_win_with_merged_file()
  silent call s:restore_merged_file_contents()
  silent call s:remove_conflict_markers(a:revision)
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
    put = s:mergedfile_contents | 1delete
    call s:remove_conflict_markers(a:revision)
    setlocal nomodifiable readonly buftype=nofile bufhidden=delete nobuflisted
    execute "file " . a:revision
  elseif a:revision ==# 'BASE' || a:revision ==# 'REMOTE' || a:revision ==# 'LOCAL'

    " First, if run as 'git mergetool', try find buffer by name: 'BASE|REMOTE|LOCAL'
    " Otherwise, load revision from Git index
    try
      execute "buffer " . a:revision
      setlocal nomodifiable readonly
    catch
      enew
      call s:load_revision_from_index(a:revision)
      setlocal nomodifiable readonly buftype=nofile bufhidden=delete nobuflisted
      execute "file " . a:revision
    endtry
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
  silent 1delete
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
  " +1,/{end_marker}-1, finds end of the range by given marker and selects contents between markers
  let delete_pattern = 'g/%s/ +1,/%s/-1 delete'

  if a:pref_revision ==# 'base'
    execute printf(delete_pattern, s:markers['ours'], s:markers['base'])
    execute printf(delete_pattern, s:markers['delimiter'], s:markers['theirs'])
  elseif a:pref_revision ==# 'local'
    execute printf(delete_pattern, s:markers['base'], s:markers['theirs'])
  elseif a:pref_revision ==# 'remote'
    execute printf(delete_pattern, s:markers['ours'], s:markers['delimiter'])
  else
    throw "Not supported revision: " . a:pref_revision
  endif

  " Delete conflict markers itself
  execute printf('g/%s\|%s\|%s\|%s/d', s:markers['ours'], s:markers['theirs'], s:markers['base'], s:markers['delimiter'])
endfunction

" Tells if file has conflict markers
function! s:has_conflict_markers()
  return search(s:markers['ours']) != 0 &&
        \ search(s:markers['theirs']) != 0 &&
        \ search(s:markers['base']) != 0 &&
        \ search(s:markers['delimiter']) != 0
endfunction

" Tells if we're currently run as 'git mergetool'
" Detects existence of 'BASE|LOCAL|REMOTE' buffer names
function! s:is_run_as_git_mergetool()
  return bufnr('BASE') != -1 &&
        \ bufnr('LOCAL') != -1 &&
        \ bufnr('REMOTE') != -1
endfunction

" Discard all changes in buffer, and fill it with original merged file contents
function! s:restore_merged_file_contents()
  %delete | put =s:mergedfile_contents | 1delete
endfunction

" Find window with merged file and focus it
function! s:goto_win_with_merged_file()
  execute bufwinnr(s:mergedfile_bufnr) "wincmd w"
endfunction

function! s:ensure_in_mergemode()
  if !s:in_merge_mode
    throw "Not in a merge mode"
  endif
endfunction

" }}}
