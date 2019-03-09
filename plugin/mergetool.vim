
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
command! -nargs=0 MergetoolPreferLocal call mergetool#prefer_revision('local')
command! -nargs=0 MergetoolPreferRemote call mergetool#prefer_revision('remote')

nnoremap <silent> <plug>(MergetoolToggle) :<C-u>call mergetool#toggle()<CR>
