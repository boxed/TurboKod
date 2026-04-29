"""Mojovision: a Mojo-idiomatic port of Turbo Vision.

Public surface — re-export the most common types so users can write
``from mojovision import Application, Frame, ...``.
"""

from .app import Application
from .canvas import Canvas
from .cell import Cell, blank_cell, cell_width
from .colors import (
    Attr,
    BLACK, BLUE, CYAN, DARK_GRAY, GREEN, LIGHT_BLUE, LIGHT_CYAN, LIGHT_GRAY,
    LIGHT_GREEN, LIGHT_MAGENTA, LIGHT_RED, LIGHT_YELLOW, MAGENTA, RED, WHITE,
    YELLOW,
    STYLE_BOLD, STYLE_DIM, STYLE_ITALIC, STYLE_NONE, STYLE_REVERSE,
    STYLE_STRIKE, STYLE_UNDERLINE,
    default_attr,
)
from .events import (
    Event,
    EVENT_KEY, EVENT_MOUSE, EVENT_NONE, EVENT_PASTE, EVENT_QUIT, EVENT_RESIZE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6,
    KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12,
    KEY_HOME, KEY_INSERT, KEY_LEFT, KEY_NONE, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_RIGHT, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_NONE,
    MOUSE_BUTTON_RIGHT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .clipboard import clipboard_copy, clipboard_paste
from .desktop import (
    APP_QUIT_ACTION,
    DEBUG_ADD_WATCH, DEBUG_CONDITIONAL_BP,
    DEBUG_START_OR_CONTINUE, DEBUG_STEP_IN, DEBUG_STEP_OUT, DEBUG_STEP_OVER,
    DEBUG_STOP, DEBUG_TOGGLE_BREAKPOINT, DEBUG_TOGGLE_RAISED,
    Desktop,
    EDITOR_COPY, EDITOR_CUT, EDITOR_FIND, EDITOR_GOTO, EDITOR_GOTO_SYMBOL,
    EDITOR_NEW, EDITOR_PASTE, EDITOR_QUICK_OPEN, EDITOR_REDO, EDITOR_REPLACE,
    EDITOR_SAVE, EDITOR_SAVE_AS, EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT,
    EDITOR_UNDO,
    Hotkey, PROJECT_CLOSE_ACTION, PROJECT_FIND, PROJECT_REPLACE,
    PROJECT_TREE_ACTION,
    WINDOW_CLOSE, WINDOW_FOCUS_PREFIX, WINDOW_MAXIMIZE_ALL, WINDOW_RESTORE_ALL,
    ctrl_key, format_hotkey,
)
from .editor import Editor, TextBuffer
from .highlight import (
    DefinitionRequest, Highlight, extension_of, highlight_for_extension,
    highlight_comment_attr, highlight_decorator_attr, highlight_keyword_attr,
    highlight_number_attr, highlight_string_attr, word_at,
)
from .json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_null,
    json_object, json_str, parse_json,
)
from .lsp import (
    LSP_NOTIFICATION, LSP_REQUEST, LSP_RESPONSE,
    LspClient, LspIncoming, LspProcess, classify_message,
    lsp_initialize_params,
)
from .language_config import (
    LanguageSpec, ServerCandidate, built_in_servers,
    find_language_by_id, find_language_for_extension,
)
from .lsp_dispatch import DefinitionResolved, LspManager, SymbolItem
from .dap import (
    DAP_EVENT, DAP_REQUEST, DAP_RESPONSE,
    DapClient, DapIncoming, classify_dap_message, dap_initialize_arguments,
)
from .dap_dispatch import (
    DapEvaluations, DapManager, DapOutput, DapScope, DapStackFrame,
    DapStopped, DapThread, DapVariable,
)
from .debug_pane import DebugPane, PaneRow
from .debugger_config import (
    DAP_REQUEST_ATTACH, DAP_REQUEST_LAUNCH,
    AdapterCandidate, DebuggerSpec,
    built_in_debuggers, find_debugger_for_language, launch_arguments_for,
)
from .dir_browser import DirBrowser
from .file_dialog import FileDialog
from .save_as_dialog import SaveAsDialog
from .file_io import (
    FileInfo, basename, find_git_project, join_path, list_directory,
    parent_path, read_file, stat_file, write_file,
)
from .file_tree import FILE_TREE_WIDTH, FileTree, FileTreeEntry
from .project import (
    GitignoreMatcher, GitignorePattern, ProjectMatch,
    find_in_project, replace_in_project, walk_project_files,
)
from .project_find import ProjectFind
from .quick_open import QuickOpen
from .symbol_pick import SymbolPick, symbol_kind_label
from .geometry import Point, Rect
from .menu import Menu, MenuBar, MenuItem, MenuResult
from .painter import Painter
from .prompt import Prompt
from .status import StatusBar, StatusItem
from .terminal import Terminal
from .view import Drawable, EventHandler, Fill, Frame, Label, centered
from .window import Window, WindowManager
