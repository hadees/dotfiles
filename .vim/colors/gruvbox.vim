" -----------------------------------------------------------------------------
" File: gruvbox.vim
" Description: Retro groove color scheme for Vim
" Author: morhetz <morhetz@gmail.com>
" Source: https://github.com/morhetz/gruvbox
" Last Modified: 12 Aug 2017
" -----------------------------------------------------------------------------

" Supporting code -------------------------------------------------------------
" Initialisation: {{{

if version > 580
  hi clear
  if exists("syntax_on")
    syntax reset
  endif
endif

let g:colors_name='gruvbox'

if !(has('termguicolors') && &termguicolors) && !has('gui_running') && &t_Co != 256
  finish
endif

" }}}
" Global Settings: {{{

if !exists('g:gruvbox_bold')
  let g:gruvbox_bold=1
endif
if !exists('g:gruvbox_italic')
  if has('gui_running') || $TERM_ITALICS == 'true'
    let g:gruvbox_italic=1
  else
    let g:gruvbox_italic=0
  endif
endif
if !exists('g:gruvbox_undercurl')
  let g:gruvbox_undercurl=1
endif
if !exists('g:gruvbox_underline')
  let g:gruvbox_underline=1
endif
if !exists('g:gruvbox_inverse')
  let g:gruvbox_inverse=1
endif

if !exists('g:gruvbox_guisp_fallback') || index(['fg', 'bg'], g:gruvbox_guisp_fallback) == -1
  let g:gruvbox_guisp_fallback='NONE'
endif

if !exists('g:gruvbox_improved_strings')
  let g:gruvbox_improved_strings=0
endif

if !exists('g:gruvbox_improved_warnings')
  let g:gruvbox_improved_warnings=0
endif

if !exists('g:gruvbox_termcolors')
  let g:gruvbox_termcolors=256
endif

if !exists('g:gruvbox_invert_indent_guides')
  let g:gruvbox_invert_indent_guides=0
endif

if exists('g:gruvbox_contrast')
  echo 'g:gruvbox_contrast is deprecated; use g:gruvbox_contrast_light and g:gruvbox_contrast_dark instead'
endif

if !exists('g:gruvbox_contrast_dark')
  let g:gruvbox_contrast_dark='medium'
endif

if !exists('g:gruvbox_contrast_light')
  let g:gruvbox_contrast_light='medium'
endif

let s:is_dark=(&background == 'dark')

" }}}
" Palette: {{{

let s:gb = {}

let s:gb.dark0_hard  = ['#1d2021', 234]
let s:gb.dark0       = ['#282828', 235]
let s:gb.dark0_soft  = ['#32302f', 236]
let s:gb.dark1       = ['#3c3836', 237]
let s:gb.dark2       = ['#504945', 239]
let s:gb.dark3       = ['#665c54', 241]
let s:gb.dark4       = ['#7c6f64', 243]
let s:gb.dark4_256   = ['#7c6f64', 243]

let s:gb.gray_245    = ['#928374', 245]
let s:gb.gray_244    = ['#928374', 244]

let s:gb.light0_hard = ['#f9f5d7', 230]
let s:gb.light0      = ['#fbf1c7', 229]
let s:gb.light0_soft = ['#f2e5bc', 228]
let s:gb.light1      = ['#ebdbb2', 223]
let s:gb.light2      = ['#d5c4a1', 250]
let s:gb.light3      = ['#bdae93', 248]
let s:gb.light4      = ['#a89984', 246]
let s:gb.light4_256  = ['#a89984', 246]

let s:gb.bright_red     = ['#fb4934', 167]
let s:gb.bright_green   = ['#b8bb26', 142]
let s:gb.bright_yellow  = ['#fabd2f', 214]
let s:gb.bright_blue    = ['#83a598', 109]
let s:gb.bright_purple  = ['#d3869b', 175]
let s:gb.bright_aqua    = ['#8ec07c', 108]
let s:gb.bright_orange  = ['#fe8019', 208]

let s:gb.neutral_red    = ['#cc241d', 124]
let s:gb.neutral_green  = ['#98971a', 106]
let s:gb.neutral_yellow = ['#d79921', 172]
let s:gb.neutral_blue   = ['#458588', 66]
let s:gb.neutral_purple = ['#b16286', 132]
let s:gb.neutral_aqua   = ['#689d6a', 72]
let s:gb.neutral_orange = ['#d65d0e', 166]

let s:gb.faded_red      = ['#9d0006', 88]
let s:gb.faded_green    = ['#79740e', 100]
let s:gb.faded_yellow   = ['#b57614', 136]
let s:gb.faded_blue     = ['#076678', 24]
let s:gb.faded_purple   = ['#8f3f71', 96]
let s:gb.faded_aqua     = ['#427b58', 66]
let s:gb.faded_orange   = ['#af3a03', 130]

" }}}
" Setup Emphasis: {{{

let s:bold = 'bold,'
if g:gruvbox_bold == 0
  let s:bold = ''
endif

let s:italic = 'italic,'
if g:gruvbox_italic == 0
  let s:italic = ''
endif

let s:underline = 'underline,'
if g:gruvbox_underline == 0
  let s:underline = ''
endif

let s:undercurl = 'undercurl,'
if g:gruvbox_undercurl == 0
  let s:undercurl = ''
endif

let s:inverse = 'inverse,'
if g:gruvbox_inverse == 0
  let s:inverse = ''
endif

" }}}
" Setup Colors: {{{

let s:vim_bg = ['bg', 'bg']
let s:vim_fg = ['fg', 'fg']
let s:none = ['NONE', 'NONE']

if s:is_dark
  let s:bg0  = s:gb.dark0
  if g:gruvbox_contrast_dark == 'soft'
    let s:bg0  = s:gb.dark0_soft
  elseif g:gruvbox_contrast_dark == 'hard'
    let s:bg0  = s:gb.dark0_hard
  endif

  let s:bg1  = s:gb.dark1
  let s:bg2  = s:gb.dark2
  let s:bg3  = s:gb.dark3
  let s:bg4  = s:gb.dark4

  let s:gray = s:gb.gray_245

  let s:fg0 = s:gb.light0
  let s:fg1 = s:gb.light1
  let s:fg2 = s:gb.light2
  let s:fg3 = s:gb.light3
  let s:fg4 = s:gb.light4

  let s:fg4_256 = s:gb.light4_256

  let s:red    = s:gb.bright_red
  let s:green  = s:gb.bright_green
  let s:yellow = s:gb.bright_yellow
  let s:blue   = s:gb.bright_blue
  let s:purple = s:gb.bright_purple
  let s:aqua   = s:gb.bright_aqua
  let s:orange = s:gb.bright_orange
else
  let s:bg0  = s:gb.light0
  if g:gruvbox_contrast_light == 'soft'
    let s:bg0  = s:gb.light0_soft
  elseif g:gruvbox_contrast_light == 'hard'
    let s:bg0  = s:gb.light0_hard
  endif

  let s:bg1  = s:gb.light1
  let s:bg2  = s:gb.light2
  let s:bg3  = s:gb.light3
  let s:bg4  = s:gb.light4

  let s:gray = s:gb.gray_244

  let s:fg0 = s:gb.dark0
  let s:fg1 = s:gb.dark1
  let s:fg2 = s:gb.dark2
  let s:fg3 = s:gb.dark3
  let s:fg4 = s:gb.dark4

  let s:fg4_256 = s:gb.dark4_256

  let s:red    = s:gb.faded_red
  let s:green  = s:gb.faded_green
  let s:yellow = s:gb.faded_yellow
  let s:blue   = s:gb.faded_blue
  let s:purple = s:gb.faded_purple
  let s:aqua   = s:gb.faded_aqua
  let s:orange = s:gb.faded_orange
endif

if g:gruvbox_termcolors == 16
  let s:bg0[1]    = 0
  let s:fg4[1]    = 7
  let s:gray[1]   = 8
  let s:red[1]    = 9
  let s:green[1]  = 10
  let s:yellow[1] = 11
  let s:blue[1]   = 12
  let s:purple[1] = 13
  let s:aqua[1]   = 14
  let s:fg1[1]    = 15
endif

let s:gb.bg0 = s:bg0
let s:gb.bg1 = s:bg1
let s:gb.bg2 = s:bg2
let s:gb.bg3 = s:bg3
let s:gb.bg4 = s:bg4

let s:gb.gray = s:gray

let s:gb.fg0 = s:fg0
let s:gb.fg1 = s:fg1
let s:gb.fg2 = s:fg2
let s:gb.fg3 = s:fg3
let s:gb.fg4 = s:fg4

let s:gb.fg4_256 = s:fg4_256

let s:gb.red    = s:red
let s:gb.green  = s:green
let s:gb.yellow = s:yellow
let s:gb.blue   = s:blue
let s:gb.purple = s:purple
let s:gb.aqua   = s:aqua
let s:gb.orange = s:orange

" }}}
" Setup Terminal Colors For Neovim: {{{

if has('nvim')
  let g:terminal_color_0 = s:bg0[0]
  let g:terminal_color_8 = s:gray[0]

  let g:terminal_color_1 = s:gb.neutral_red[0]
  let g:terminal_color_9 = s:red[0]

  let g:terminal_color_2 = s:gb.neutral_green[0]
  let g:terminal_color_10 = s:green[0]

  let g:terminal_color_3 = s:gb.neutral_yellow[0]
  let g:terminal_color_11 = s:yellow[0]

  let g:terminal_color_4 = s:gb.neutral_blue[0]
  let g:terminal_color_12 = s:blue[0]

  let g:terminal_color_5 = s:gb.neutral_purple[0]
  let g:terminal_color_13 = s:purple[0]

  let g:terminal_color_6 = s:gb.neutral_aqua[0]
  let g:terminal_color_14 = s:aqua[0]

  let g:terminal_color_7 = s:fg4[0]
  let g:terminal_color_15 = s:fg1[0]
endif

" }}}
" Overload Setting: {{{

let s:hls_cursor = s:orange
if exists('g:gruvbox_hls_cursor')
  let s:hls_cursor = get(s:gb, g:gruvbox_hls_cursor)
endif

let s:number_column = s:none
if exists('g:gruvbox_number_column')
  let s:number_column = get(s:gb, g:gruvbox_number_column)
endif

let s:sign_column = s:bg1

if exists('g:gitgutter_override_sign_column_highlight') &&
      \ g:gitgutter_override_sign_column_highlight == 1
  let s:sign_column = s:number_column
else
  let g:gitgutter_override_sign_column_highlight = 0

  if exists('g:gruvbox_sign_column')
    let s:sign_column = get(s:gb, g:gruvbox_sign_column)
  endif
endif

let s:color_column = s:bg1
if exists('g:gruvbox_color_column')
  let s:color_column = get(s:gb, g:gruvbox_color_column)
endif

let s:vert_split = s:bg0
if exists('g:gruvbox_vert_split')
  let s:vert_split = get(s:gb, g:gruvbox_vert_split)
endif

let s:invert_signs = ''
if exists('g:gruvbox_invert_signs')
  if g:gruvbox_invert_signs == 1
    let s:invert_signs = s:inverse
  endif
endif

let s:invert_selection = s:inverse
if exists('g:gruvbox_invert_selection')
  if g:gruvbox_invert_selection == 0
    let s:invert_selection = ''
  endif
endif

let s:invert_tabline = ''
if exists('g:gruvbox_invert_tabline')
  if g:gruvbox_invert_tabline == 1
    let s:invert_tabline = s:inverse
  endif
endif

let s:italicize_comments = s:italic
if exists('g:gruvbox_italicize_comments')
  if g:gruvbox_italicize_comments == 0
    let s:italicize_comments = ''
  endif
endif

let s:italicize_strings = ''
if exists('g:gruvbox_italicize_strings')
  if g:gruvbox_italicize_strings == 1
    let s:italicize_strings = s:italic
  endif
endif

" }}}
" Highlighting Function: {{{

function! s:HL(group, fg, ...)
  let fg = a:fg

  if a:0 >= 1
    let bg = a:1
  else
    let bg = s:none
  endif

  if a:0 >= 2 && strlen(a:2)
    let emstr = a:2
  else
    let emstr = 'NONE,'
  endif

  if a:0 >= 3
    if g:gruvbox_guisp_fallback != 'NONE'
      let fg = a:3
    endif

    if g:gruvbox_guisp_fallback == 'bg'
      let emstr .= 'inverse,'
    endif
  endif

  let histring = [ 'hi', a:group,
        \ 'guifg=' . fg[0], 'ctermfg=' . fg[1],
        \ 'guibg=' . bg[0], 'ctermbg=' . bg[1],
        \ 'gui=' . emstr[:-2], 'cterm=' . emstr[:-2]
        \ ]

  if a:0 >= 3
    call add(histring, 'guisp=' . a:3[0])
  endif

  execute join(histring, ' ')
endfunction

" }}}
" Gruvbox Hi Groups: {{{

call s:HL('GruvboxFg0', s:fg0)
call s:HL('GruvboxFg1', s:fg1)
call s:HL('GruvboxFg2', s:fg2)
call s:HL('GruvboxFg3', s:fg3)
call s:HL('GruvboxFg4', s:fg4)
call s:HL('GruvboxGray', s:gray)
call s:HL('GruvboxBg0', s:bg0)
call s:HL('GruvboxBg1', s:bg1)
call s:HL('GruvboxBg2', s:bg2)
call s:HL('GruvboxBg3', s:bg3)
call s:HL('GruvboxBg4', s:bg4)

call s:HL('GruvboxRed', s:red)
call s:HL('GruvboxRedBold', s:red, s:none, s:bold)
call s:HL('GruvboxGreen', s:green)
call s:HL('GruvboxGreenBold', s:green, s:none, s:bold)
call s:HL('GruvboxYellow', s:yellow)
call s:HL('GruvboxYellowBold', s:yellow, s:none, s:bold)
call s:HL('GruvboxBlue', s:blue)
call s:HL('GruvboxBlueBold', s:blue, s:none, s:bold)
call s:HL('GruvboxPurple', s:purple)
call s:HL('GruvboxPurpleBold', s:purple, s:none, s:bold)
call s:HL('GruvboxAqua', s:aqua)
call s:HL('GruvboxAquaBold', s:aqua, s:none, s:bold)
call s:HL('GruvboxOrange', s:orange)
call s:HL('GruvboxOrangeBold', s:orange, s:none, s:bold)

call s:HL('GruvboxRedSign', s:red, s:sign_column, s:invert_signs)
call s:HL('GruvboxGreenSign', s:green, s:sign_column, s:invert_signs)
call s:HL('GruvboxYellowSign', s:yellow, s:sign_column, s:invert_signs)
call s:HL('GruvboxBlueSign', s:blue, s:sign_column, s:invert_signs)
call s:HL('GruvboxPurpleSign', s:purple, s:sign_column, s:invert_signs)
call s:HL('GruvboxAquaSign', s:aqua, s:sign_column, s:invert_signs)
call s:HL('GruvboxOrangeSign', s:orange, s:sign_column, s:invert_signs)

" }}}

" Vanilla colorscheme ---------------------------------------------------------
" General UI: {{{

call s:HL('Normal', s:fg1, s:bg0)

if s:is_dark
  set background=dark
else
  set background=light
endif

if version >= 700
  call s:HL('CursorLine',   s:none, s:bg1)
  hi! link CursorColumn CursorLine

  call s:HL('TabLineFill', s:bg4, s:bg1, s:invert_tabline)
  call s:HL('TabLineSel', s:green, s:bg1, s:invert_tabline)
  hi! link TabLine TabLineFill

  call s:HL('MatchParen', s:none, s:bg3, s:bold)
endif

if version >= 703
  call s:HL('ColorColumn',  s:none, s:color_column)
  call s:HL('Conceal', s:blue, s:none)
  call s:HL('CursorLineNr', s:yellow, s:bg1)
endif

hi! link NonText GruvboxBg2
hi! link SpecialKey GruvboxBg2

call s:HL('Visual',    s:none,  s:bg3, s:invert_selection)
hi! link VisualNOS Visual

call s:HL('Search',    s:yellow, s:bg0, s:inverse)
call s:HL('IncSearch', s:hls_cursor, s:bg0, s:inverse)

call s:HL('Underlined', s:blue, s:none, s:underline)

call s:HL('StatusLine',   s:bg2, s:fg1, s:inverse)
call s:HL('StatusLineNC', s:bg1, s:fg4, s:inverse)

call s:HL('VertSplit', s:bg3, s:vert_split)

call s:HL('WildMenu', s:blue, s:bg2, s:bold)

hi! link Directory GruvboxGreenBold
hi! link Title GruvboxGreenBold

call s:HL('ErrorMsg',   s:bg0, s:red, s:bold)
hi! link MoreMsg GruvboxYellowBold
hi! link ModeMsg GruvboxYellowBold
hi! link Question GruvboxOrangeBold
hi! link WarningMsg GruvboxRedBold

" }}}
" Gutter: {{{

call s:HL('LineNr', s:bg4, s:number_column)
call s:HL('SignColumn', s:none, s:sign_column)
call s:HL('Folded', s:gray, s:bg1, s:italic)
call s:HL('FoldColumn', s:gray, s:bg1)

" }}}
" Cursor: {{{

call s:HL('Cursor', s:none, s:none, s:inverse)
hi! link vCursor Cursor
hi! link iCursor Cursor
hi! link lCursor Cursor

" }}}
" Syntax Highlighting: {{{

if g:gruvbox_improved_strings == 0
  hi! link Special GruvboxOrange
else
  call s:HL('Special', s:orange, s:bg1, s:italicize_strings)
endif

call s:HL('Comment', s:gray, s:none, s:italicize_comments)
call s:HL('Todo', s:vim_fg, s:vim_bg, s:bold . s:italic)
call s:HL('Error', s:red, s:vim_bg, s:bold . s:inverse)

hi! link Statement GruvboxRed
hi! link Conditional GruvboxRed
hi! link Repeat GruvboxRed
hi! link Label GruvboxRed
hi! link Exception GruvboxRed
hi! link Operator Normal
hi! link Keyword GruvboxRed

hi! link Identifier GruvboxBlue
hi! link Function GruvboxGreenBold

hi! link PreProc GruvboxAqua
hi! link Include GruvboxAqua
hi! link Define GruvboxAqua
hi! link Macro GruvboxAqua
hi! link PreCondit GruvboxAqua

hi! link Constant GruvboxPurple
hi! link Character GruvboxPurple
if g:gruvbox_improved_strings == 0
  call s:HL('String',  s:green, s:none, s:italicize_strings)
else
  call s:HL('String',  s:fg1, s:bg1, s:italicize_strings)
endif
hi! link Boolean GruvboxPurple
hi! link Number GruvboxPurple
hi! link Float GruvboxPurple

hi! link Type GruvboxYellow
hi! link StorageClass GruvboxOrange
hi! link Structure GruvboxAqua
hi! link Typedef GruvboxYellow

" }}}
" Completion Menu: {{{

if version >= 700
  call s:HL('Pmenu', s:fg1, s:bg2)
  call s:HL('PmenuSel', s:bg2, s:blue, s:bold)
  call s:HL('PmenuSbar', s:none, s:bg2)
  call s:HL('PmenuThumb', s:none, s:bg4)
endif

" }}}
" Diffs: {{{

call s:HL('DiffDelete', s:red, s:bg0, s:inverse)
call s:HL('DiffAdd',    s:green, s:bg0, s:inverse)
call s:HL('DiffChange', s:aqua, s:bg0, s:inverse)
call s:HL('DiffText',   s:yellow, s:bg0, s:inverse)

" }}}
" Spelling: {{{

if has("spell")
  if g:gruvbox_improved_warnings == 0
    call s:HL('SpellCap',   s:none, s:none, s:undercurl, s:red)
  else
    call s:HL('SpellCap',   s:green, s:none, s:bold . s:italic)
  endif
  call s:HL('SpellBad',   s:none, s:none, s:undercurl, s:blue)
  call s:HL('SpellLocal', s:none, s:none, s:undercurl, s:aqua)
  call s:HL('SpellRare',  s:none, s:none, s:undercurl, s:purple)
endif

" }}}

" Filetype specific -----------------------------------------------------------
" Diff: {{{

hi! link diffAdded GruvboxGreen
hi! link diffRemoved GruvboxRed
hi! link diffChanged GruvboxAqua
hi! link diffFile GruvboxOrange
hi! link diffNewFile GruvboxYellow
hi! link diffLine GruvboxBlue

" }}}
" Html: {{{

hi! link htmlTag GruvboxBlue
hi! link htmlEndTag GruvboxBlue
hi! link htmlTagName GruvboxAquaBold
hi! link htmlArg GruvboxAqua
hi! link htmlScriptTag GruvboxPurple
hi! link htmlTagN GruvboxFg1
hi! link htmlSpecialTagName GruvboxAquaBold
call s:HL('htmlLink', s:fg4, s:none, s:underline)
hi! link htmlSpecialChar GruvboxOrange
call s:HL('htmlBold', s:vim_fg, s:vim_bg, s:bold)
call s:HL('htmlBoldUnderline', s:vim_fg, s:vim_bg, s:bold . s:underline)
call s:HL('htmlBoldItalic', s:vim_fg, s:vim_bg, s:bold . s:italic)
call s:HL('htmlBoldUnderlineItalic', s:vim_fg, s:vim_bg, s:bold . s:underline . s:italic)
call s:HL('htmlUnderline', s:vim_fg, s:vim_bg, s:underline)
call s:HL('htmlUnderlineItalic', s:vim_fg, s:vim_bg, s:underline . s:italic)
call s:HL('htmlItalic', s:vim_fg, s:vim_bg, s:italic)

" }}}
" Markdown: {{{

call s:HL('markdownItalic', s:fg3, s:none, s:italic)
hi! link markdownH1 GruvboxGreenBold
hi! link markdownH2 GruvboxGreenBold
hi! link markdownH3 GruvboxYellowBold
hi! link markdownH4 GruvboxYellowBold
hi! link markdownH5 GruvboxYellow
hi! link markdownH6 GruvboxYellow
hi! link markdownCode GruvboxAqua
hi! link markdownCodeBlock GruvboxAqua
hi! link markdownCodeDelimiter GruvboxAqua
hi! link markdownBlockquote GruvboxGray
hi! link markdownListMarker GruvboxGray
hi! link markdownOrderedListMarker GruvboxGray
hi! link markdownRule GruvboxGray
hi! link markdownHeadingRule GruvboxGray
hi! link markdownUrlDelimiter GruvboxFg3
hi! link markdownLinkDelimiter GruvboxFg3
hi! link markdownLinkTextDelimiter GruvboxFg3
hi! link markdownHeadingDelimiter GruvboxOrange
hi! link markdownUrl GruvboxPurple
hi! link markdownUrlTitleDelimiter GruvboxGreen
call s:HL('markdownLinkText', s:gray, s:none, s:underline)
hi! link markdownIdDeclaration markdownLinkText

" }}}
" Json: {{{

hi! link jsonKeyword GruvboxGreen
hi! link jsonQuote GruvboxGreen
hi! link jsonBraces GruvboxFg1
hi! link jsonString GruvboxFg1

" }}}

" vim: set sw=2 ts=2 sts=2 et tw=80 ft=vim fdm=marker:
