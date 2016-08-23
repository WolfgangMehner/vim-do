" Exit when already loaded (or "compatible" mode set)
if exists("g:do_loaded") || &cp
    finish
endif

" Vars used by this script, don't change
let g:do_loaded = 1
let s:existing_update_time = &updatetime
let s:previous_command = ""

" Configuration vars
let s:do_check_interval = 500
let s:do_new_process_window_command = "new"
let s:do_refresh_key = "<C-L>"
let s:do_update_time = 500
let s:do_auto_show_process_window = 1

""
" Load Python script
"
" Search relative to this file.
let $CUR_DIRECTORY=expand("<sfile>:p:h")

if filereadable($CUR_DIRECTORY."/python/do.py")
    if has("python")
        pyfile $CUR_DIRECTORY/python/do.py
    elseif has("python3")
        py3file $CUR_DIRECTORY/python/do.py
    endif
else
    call confirm('do.vim: Unable to find autoload/python/do.py. Place it in either your home vim directory or in the Vim runtime directory.', 'OK')
endif

""
" Fetch a scoped value of an option
"
" Determine a value of an option based on user configuration or pre-configured
" defaults. A user can configure an option by defining it as a buffer variable
" or as a global (buffer vars override globals). Default value can be provided
" by defining a script variable for the whole file or a function local (local
" vars override script vars). When all else fails, falls back the supplied
" default value,  if one is supplied.
"
" @param string option Scope-less name of the option
" @param mixed a:1 An option default value for the option
"
function! do#get(option, ...)
    for l:scope in ['b', 'g', 'l', 's']
        if exists(l:scope . ':' . a:option)
            return eval(l:scope . ':' . a:option)
        endif
    endfor

    if a:0 > 0
        return a:1
    endif

    call do#error('Invalid or undefined option: ' . a:option)
endfunction

""
" Show user an error message
"
" Pre-format supplied message as an Error and display it to the user. All
" messages are saved to message-history and are accessible via `:messages`.
"
" @param string message A message to be displayed to the user
"
function! do#error(message)
    echohl Error | echomsg a:message | echohl None
endfunction

""
" Execute the last command again.
"
" See do#Execute().
"
function! do#ExecuteAgain()
    if empty(s:previous_command)
        call do#error("You cannot execute the previous command when no previous command exists!")
    else
        call do#Execute(s:previous_command)
    endif
endfunction

""
" Reload all do options set by `g:do_...`
"
" Do will cache option values for performance reasons, but calling this
" function will reload them.
"
function! do#ReloadOptions()
    python do_async.reload_options()
endfunction

""
" Execute a shell command asynchronously.
"
" If a command string is supplied, this will be executed. If no argument (or
" an empty string) is supplied, it will default to using the command set by
" the vim setting "makeprg", which defaults to `make`.
"
" Any special file modifiers will get expanded, such as "%". This allows you
" to run commands like "test %", where "%" will be expanded to the current
" file name.
"
" @param string command (optional) The command to run, defaults to &makeprg
"
function! do#Execute(command, ...)
    if a:0 > 0
        let l:quiet = a:1
    else
        let l:quiet = 0
    end
    let l:command = a:command
    if empty(l:command)
        let l:command = &makeprg
    endif
    let l:command = Strip(join(map(split(l:command, '\ze[<%#]'), 'expand(v:val)'), ''))
    if empty(l:command)
        call do#error("Supplied command is empty")
    else
        let s:previous_command = l:command
        python do_async.execute(vim.eval("l:command"), int(vim.eval("l:quiet")) == 1)
    endif
endfunction


""
" Execute a shell command asynchronously, from the current visually selected text.
"
" See do#Execute() for more information.
"
function! do#ExecuteSelection()
    let l:command = s:getVisualSelection()
    call do#Execute(l:command)
endfunction

""
" Keeps records on external processes started via do#ExecuteExternal .
"
let s:external_processes = {
            \ 'by_id'  : {},
            \ 'by_pid' : {},
            \ }

""
" Default callback for external processes
"
" This is the default callback for external processes. It always excepts all
" parameters and does nothing.
"
" @param string a:1 The ID of the external process
" @param number or string a:2 The exit code of the external process
"
function! s:EmptyCallback(...)
endfunction

""
" Start an external process
"
" Start an external process with the following options, which are given in a
" Dict with fields:
" - id (string): a user-defined ID
" - split_output (integer): whether the output is to be split into stdout and
"   stderr, the default is not to split the output
" - callback (Funcref): a function to be called after the process is finished:
"     function s:Callback(pid,exit_code)
"       " ...
"     endfunction
"     options.callback = Function("s:Callback")
"
" @param string command The command to run
" @param dict options The options as a dictionary
"
function! do#ExecuteExternal(command, options)
    let record = {
                \ 'id'           : get ( a:options, 'id', '' ),
                \ 'command'      : a:command,
                \ 'callback'     : get ( a:options, 'callback', function('s:EmptyCallback') ),
                \ 'split_output' : get ( a:options, 'split_output', 0 ),
                \ 'status'       : 'new',
                \ 'pid'          : -1,
                \ 'exit_code'    : -1,
                \ }
    if record.id != ''
        let s:external_processes.by_id[record.id] = record
    endif

    let l:command = a:command
    let l:pid     = -1
    let l:split   = record.split_output
    if empty(l:command)
        "TODO: log
        return 0
    endif
    let l:command = Strip(l:command)
    if empty(l:command)
        "TODO: log
        return 0
    else
        let l:pid = pyeval ( 'do_async.execute(vim.eval("l:command"), external = True, split_output = vim.eval("l:split") == 1 )' )
        let record.status = 'running'
        let record.pid    = l:pid
        let s:external_processes.by_pid[record.pid] = record
    endif
endfunction

""
" Get a previously started external process
"
" Returns the record of the last external process with the given ID. The
" record is a Dict with fields:
" - id (string): the user-defined ID
" - command (string): the command
" - split_output (integer): whether the output is split
" - status (string): "new", "running", "finished", or "failed"
" - pid (number): only valid while the status is "running"
" - exit_code (number): only valid if the status is "finished"
"
" If a record with this ID does not exist, a record with the field 'status'
" set to "failed" is returned.
"
" @param string id The ID of the process
"
function! do#GetExternal(id)
    if ! has_key ( s:external_processes.by_id, a:id )
        return { 'status' : 'failed', }
    endif
    return s:external_processes.by_id[a:id]
endfunction

""
" Internal use: An external process is finished
"
" This function is called by Python after an external process finished. It
" should not be called by a user.
"
" @param number pid The PID of the process, for identification
" @param number exit_code The exit code
"
function! do#HookProcessFinished(pid,exit_code)
    if has_key ( s:external_processes.by_pid, a:pid )
        let record = s:external_processes.by_pid[a:pid]
        let record.status    = 'finished'
        let record.exit_code = a:exit_code
        call remove ( s:external_processes.by_pid, a:pid )

        call call ( record.callback, [ record.id, record.exit_code ] )

        if record.split_output
            " :TODO:14.07.2016 19:03:WM: only get the output when requested,
            " this runs during an autocmd and takes to much time
            let l = pyeval ( 'do_async.get_by_pid('.record.pid.').output().all_std()' )
            let record.output_std = join ( l, "" )
            let l = pyeval ( 'do_async.get_by_pid('.record.pid.').output().all_err()' )
            let record.output_err = join ( l, "" )
        else
            " :TODO:14.07.2016 19:03:WM: only get the output when requested,
            " this runs during an autocmd and takes to much time
            let l = pyeval ( 'do_async.get_by_pid('.record.pid.').output().all()' )
            let record.output = join ( l, "" )
        endif
    endif
endfunction

""
" Enable the file logger for debugging purposes.
"
" @param string file_path The path to the file to write log information
"
function! do#EnableLogger(file_path)
    python do_async.enable_logger(vim.eval("a:file_path"))
endfunction

""
" Show or hide the command window.
"
" The command window details currently running and finished processes.
"
function! do#ToggleCommandWindow()
    python do_async.toggle_command_window()
endfunction

""
" A callback for when the command window is closed.
"
" Executed automatically via an autocommand.
"
function! do#MarkCommandWindowAsClosed()
    python do_async.mark_command_window_as_closed()
endfunction

""
" A callback for when the process window is closed.
"
" Executed automatically via an autocommand.
"
function! do#MarkProcessWindowAsClosed()
    python do_async.mark_process_window_as_closed()
endfunction

""
" Trigger selection of a process in the command window.
"
function! do#ShowProcessFromCommandWindow()
    python do_async.show_process_from_command_window()
endfunction

""
" Do nothing.
"
" Used in do#AssignAutocommands()
"
function! do#nop()
endfunction

""
" Assign auto commands that are used after a command has started execution.
"
" This combination of auto commands should cover most cases of the user being
" idle or using vim. The updatetime is set to that defined by the option
" g:do_update_time, which is typically more regular than the default.
"
" Autocommands are added in a group, for easy removal.
"
function! do#AssignAutocommands()
    execute "nnoremap <silent> " . do#get("do_refresh_key") . " :call do#nop()<CR>"
    execute "inoremap <silent> " . do#get("do_refresh_key") . ' <C-O>:call do#nop()<CR>'
    augroup vim_do
        au CursorHold * python do_async.check()
        au CursorHoldI * python do_async.check()
        au CursorMoved * python do_async.check()
        au CursorMovedI * python do_async.check()
        au FocusGained * python do_async.check()
        au FocusLost * python do_async.check()
    augroup END
    let &updatetime=do#get("do_update_time")
endfunction

""
" Remove all autocommands set by do#AssignAutocommands().
"
" Also reset the updatetime to what it was before assigning the autocommands.
"
function! do#UnassignAutocommands()
    au! vim_do
    let &updatetime=s:existing_update_time
endfunction

" PRIVATE FUNCTIONS
" -----------------

" Strip whitespace from input strings.
"
" @param string input_string The string which requires whitespace stripping
"
function! Strip(input_string)
    return substitute(a:input_string, '^\s*\(.\{-}\)\s*$', '\1', '')
endfunction

" Thanks to http://stackoverflow.com/a/6271254/1087866
function! s:getVisualSelection()
  " Why is this not a built-in Vim script function?!
  let [lnum1, col1] = getpos("'<")[1:2]
  let [lnum2, col2] = getpos("'>")[1:2]
  let lines = getline(lnum1, lnum2)
  let lines[-1] = lines[-1][: col2 - (&selection == 'inclusive' ? 1 : 2)]
  let lines[0] = lines[0][col1 - 1:]
  return join(lines, "\n")
endfunction

" Initialize do
python do_async = Do()
autocmd VimLeavePre * python do_async.stop()

" vim: expandtab: tabstop=4: shiftwidth=4
