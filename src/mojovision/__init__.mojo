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
    MOD_ALT, MOD_CTRL, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_NONE,
    MOUSE_BUTTON_RIGHT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .clipboard import clipboard_copy, clipboard_paste
from .desktop import (
    APP_QUIT_ACTION,
    Desktop,
    EDITOR_FIND, EDITOR_GOTO, EDITOR_QUICK_OPEN, EDITOR_REPLACE, EDITOR_SAVE,
    EDITOR_SAVE_AS, EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT,
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
from .file_dialog import FileDialog
from .file_io import (
    FileInfo, basename, find_git_project, join_path, list_directory,
    parent_path, read_file, stat_file, write_file,
)
from .file_tree import FILE_TREE_WIDTH, FileTree, FileTreeEntry
from .project import (
    GitignoreMatcher, GitignorePattern, ProjectMatch,
    find_in_project, replace_in_project, walk_project_files,
)
from .quick_open import QuickOpen
from .geometry import Point, Rect
from .menu import Menu, MenuBar, MenuItem, MenuResult
from .prompt import Prompt
from .status import StatusBar, StatusItem
from .terminal import Terminal
from .view import Drawable, EventHandler, Fill, Frame, Label, centered
from .window import Window, WindowManager
