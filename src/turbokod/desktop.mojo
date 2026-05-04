"""Desktop: combines menu bar, window manager, status bar, hatched background,
modal prompt, and a project file tree — wired together so the host app only
has to deal with app-policy actions (quit / open file / focus a window).

Idiomatic usage::

    while app.running:
        desktop.paint(app.back, app.screen())
        var ev = app.next_event(50)
        if ev:
            var action = desktop.handle_event(ev.value(), app.screen())
            if action:
                ... dispatch app-specific actions (quit, file:open, ...)

The Desktop intercepts the standard editor / project actions itself — see the
``EDITOR_*`` / ``PROJECT_*`` action constants below. The app menu just lists
items with those action strings and the dispatch is automatic. Anything the
Desktop doesn't recognize is returned for the caller to handle.

Project state (the directory containing the most recently opened file's
nearest ``.git`` ancestor) lives here too. The first call to
``detect_project_from(path)`` after startup wins; subsequent file opens
don't re-detect. Closing the project (via the right-aligned project menu)
clears the state and makes the next file open eligible to set it again.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .colors import (
    Attr, BLACK, BLUE, LIGHT_GRAY, LIGHT_RED, RED, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6,
    KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12,
    KEY_HOME, KEY_INSERT, KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_RIGHT, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT,
)
from .clipboard import clipboard_copy, clipboard_paste
from .config import (
    OnSaveAction,
    TurbokodConfig, load_config, record_recent_project, save_config,
)
from .diff import unified_diff
from .file_io import (
    basename, find_git_project, join_path, parent_path, stat_file,
)
from .git_blame import compute_blame
from .git_changes import (
    diff_buffer_against_head, fetch_head_text, project_is_git_repo,
)
from .lsp import LspProcess
from .posix import close_fd, realpath, untrack_child, waitpid_blocking
from .file_tree import FileTree
from .geometry import Point, Rect
from .highlight import DefinitionRequest, GrammarRegistry, extension_of, word_at
from .install_runner import InstallResult, InstallRunner
from .local_changes import LocalChanges
from .grammar_install import (
    DownloadableGrammar, built_in_downloadable_grammars,
    find_downloadable_grammar_by_language,
    find_downloadable_grammar_for_extension,
    grammar_install_command, user_grammar_installed,
)
from .doc_config import (
    DocSpec, built_in_docsets, docs_install_command,
    find_docset_by_language, find_docset_for_extension,
)
from .doc_pick import DocPick
from .doc_store import DocEntry, DocStore, html_to_text
from .language_config import (
    LanguageSpec, built_in_servers, find_language_for_extension,
)
from .lsp_dispatch import DefinitionResolved, LspManager
from .dap_dispatch import DapManager, DapStackFrame, DapVariable
from .debug_pane import (
    DebugPane, PANE_MODE_DEBUG, PANE_MODE_RUN, PANE_ROW_WATCH,
    PANE_STATE_MAXIMIZED, PANE_STATE_MINIMIZED,
)
from .debugger_config import (
    DebuggerSpec, built_in_debuggers, find_debugger_for_language,
)
from .menu import Menu, MenuBar, MenuItem
from .posix import monotonic_ms, which
from .project import replace_in_project
from .project_find import ProjectFind
from .project_targets import (
    ProjectTargets, RunTarget, load_project_targets,
    detect_project_language,
    resolve_python_interpreter, resolved_cwd, resolved_program,
    save_project_targets,
    write_all_targets,
)
from .confirm_dialog import ConfirmDialog
from .prompt import Prompt
from .quick_open import QuickOpen
from .run_manager import RunSession, drain_run_output, poll_run_exit
from .save_as_dialog import SaveAsDialog
from .string_utils import parse_int_prefix, starts_with
from .session_store import (
    Session, SessionWindow, _resolve_session_path, _session_relative,
    encode_session, load_session, save_session,
)
from .status import StatusBar, StatusTab
from .tab_bar import TabBar, TabBarItem
from .settings import Settings
from .targets_dialog import TargetsDialog
from .symbol_pick import SymbolPick
from .window import MIN_WIN_H, MIN_WIN_W, Window, WindowManager


# --- Public action strings --------------------------------------------------
# The Desktop intercepts these; menu items wired to them work without any
# additional code on the application side.

comptime EDITOR_NEW           = String("file:new")
comptime EDITOR_SAVE          = String("file:save")
comptime EDITOR_SAVE_AS       = String("file:save_as")
comptime EDITOR_QUICK_OPEN    = String("file:quick_open")
# "Open Recent" — same picker as Quick Open, but populated from a list
# of recently focused file-backed editor windows (most-recent first),
# excluding whichever file is focused right now.
comptime EDITOR_OPEN_RECENT   = String("file:open_recent")
comptime EDITOR_FIND          = String("edit:find")
comptime EDITOR_FIND_NEXT     = String("edit:find_next")
comptime EDITOR_FIND_PREV     = String("edit:find_prev")
# Internal pending-action tag for the "install LSP server?" prompt. Not a
# public action — it never enters ``dispatch_action`` because the prompt
# is triggered programmatically from ``_maybe_lsp_open``.
comptime _PA_LSP_INSTALL      = String("lsp:install")
# "Look up in docs" — Ctrl+K opens the picker for the focused editor's
# language, prompting to install the offline DevDocs database the first
# time it's used per language.
comptime EDITOR_LOOKUP_DOCS   = String("docs:lookup")
# Internal pending-action tag for the "Download docs?" prompt.
comptime _PA_DOC_INSTALL      = String("docs:install")
# Internal pending-action tag for the "Install <lang> grammar?" prompt.
# Triggered programmatically from ``_maybe_lsp_open`` when a file's
# extension has no bundled TextMate grammar but is in the downloadable-
# grammar registry.
comptime _PA_GRAMMAR_INSTALL  = String("grammar:install")
# "Open settings view" — surfaces the fullscreen Settings widget the
# host wires into the hamburger menu. Routed through dispatch_action
# so the host doesn't need to manually toggle ``settings.open()``.
comptime APP_SETTINGS         = String("app:settings")
comptime EDITOR_REPLACE       = String("edit:replace")
comptime EDITOR_GOTO          = String("edit:goto")
comptime EDITOR_GOTO_SYMBOL   = String("edit:goto_symbol")
comptime EDITOR_TOGGLE_COMMENT = String("edit:comment")
comptime EDITOR_TOGGLE_CASE   = String("edit:case")
comptime EDITOR_TOGGLE_LINE_NUMBERS = String("view:line_numbers")
comptime EDITOR_TOGGLE_SOFT_WRAP    = String("view:soft_wrap")
# View-menu toggle for the per-window tab strip rendered above the
# status bar. Like the other view toggles, the flag lives on
# ``TurbokodConfig`` so it survives across sessions.
comptime EDITOR_TOGGLE_TAB_BAR      = String("view:tab_bar")
# View-menu toggle for the per-line "+/~" change-bar gutter. The flag
# lives on ``TurbokodConfig`` so it survives across sessions; the
# column itself only paints when a ``.git`` is reachable from the
# project root, so flipping it on outside a repo is a silent no-op.
comptime EDITOR_TOGGLE_GIT_CHANGES  = String("view:git_changes")
# Git actions. ``EDITOR_TOGGLE_BLAME`` runs ``git blame --porcelain`` for
# the focused editor's file the first time it's switched on, then re-uses
# the cached attribution for subsequent toggles in the same session.
comptime EDITOR_TOGGLE_BLAME        = String("git:blame")
# ``GIT_LOCAL_CHANGES`` runs ``git diff HEAD`` for the active project and
# opens the unified diff as a read-only window. Untracked files are not
# included — only modifications against the last commit.
comptime GIT_LOCAL_CHANGES          = String("git:local_changes")
comptime EDITOR_CUT           = String("edit:cut")
comptime EDITOR_COPY          = String("edit:copy")
comptime EDITOR_PASTE         = String("edit:paste")
comptime EDITOR_UNDO          = String("edit:undo")
comptime EDITOR_REDO          = String("edit:redo")
# "Compare selection with clipboard" — opens a read-only diff view between
# the current selection (or the whole buffer when nothing is selected) and
# the system clipboard's contents.
comptime EDITOR_COMPARE_CLIPBOARD = String("edit:compare_clipboard")
comptime PROJECT_FIND         = String("edit:project_find")
comptime PROJECT_REPLACE      = String("edit:project_replace")
comptime PROJECT_CLOSE_ACTION = String("project:close")
comptime PROJECT_TREE_ACTION  = String("project:tree:toggle")
comptime PROJECT_CONFIG_TARGETS = String("project:configure_targets")
# "Open recent project..." — same QuickOpen-style picker as Open Recent
# files, but populated from ``self.config.recent_projects`` and routed
# through ``open_project`` on submit instead of ``open_file``.
comptime PROJECT_OPEN_RECENT  = String("project:open_recent")
# Debugger actions. ``DEBUG_START_OR_CONTINUE`` is a single F5-style
# binding: starts the session if none is active, continues if stopped.
comptime DEBUG_START_OR_CONTINUE = String("debug:start_or_continue")
comptime DEBUG_TOGGLE_BREAKPOINT = String("debug:toggle_bp")
comptime DEBUG_CONDITIONAL_BP    = String("debug:conditional_bp")
comptime DEBUG_STEP_OVER         = String("debug:step_over")
comptime DEBUG_STEP_IN           = String("debug:step_in")
comptime DEBUG_STEP_OUT          = String("debug:step_out")
comptime DEBUG_STOP              = String("debug:stop")
comptime DEBUG_ADD_WATCH         = String("debug:add_watch")
comptime DEBUG_TOGGLE_RAISED     = String("debug:toggle_raised_exceptions")
comptime DEBUG_FOCUS_PANE        = String("debug:focus_pane")
# Project-target run/debug actions. ``TARGET_RUN`` (Cmd+R) launches
# the active target's ``run_command`` as a captured subprocess;
# ``TARGET_DEBUG`` (Cmd+D) launches the same target under DAP. Each
# action stops the *other* mode for that target before starting, so
# the user can flip between run and debug freely without leaking
# child processes.
comptime TARGET_RUN              = String("target:run")
comptime TARGET_DEBUG            = String("target:debug")
# ``TARGET_TEST`` (Cmd+T) launches a language-appropriate test runner
# in the project root. Unlike Run / Debug it doesn't need an active
# target — the language guess is enough to pick a sensible default
# (``python -m pytest`` for Python projects).
comptime TARGET_TEST             = String("target:test")
# Status-bar tab click. ``TARGET_SELECT_PREFIX + <index>`` switches
# the active tab to that index. The dispatch parser walks the
# prefix the same way it does ``WINDOW_FOCUS_PREFIX``.
comptime TARGET_SELECT_PREFIX    = String("target:select:")
comptime FILE_TREE_FOCUS         = String("file_tree:focus")
# Dynamic Window menu actions. Focus actions encode the index inline so the
# items can be rebuilt every frame without any separate lookup table.
comptime WINDOW_FOCUS_PREFIX  = String("window:focus:")
comptime WINDOW_MAXIMIZE_ALL  = String("window:maximize_all")
comptime WINDOW_RESTORE_ALL   = String("window:restore_all")
comptime WINDOW_CLOSE         = String("window:close")
comptime WINDOW_ROTATE_NEXT   = String("window:rotate_next")
comptime WINDOW_ROTATE_PREV   = String("window:rotate_prev")
comptime _WINDOW_MENU_LABEL   = String("Window")

# When ESC fires at the top level (no menu open, no prompt active), the
# Desktop returns this so the app can decide whether to quit, ignore, etc.
comptime APP_QUIT_ACTION      = String("quit")

comptime _SHOW_TREE_LABEL = String("Show file tree")
comptime _HIDE_TREE_LABEL = String("Hide file tree")

# Internal pending-action values for two-step prompts (find → replace).
comptime _PA_REPLACE_FIND        = String("__pa_replace_find")
comptime _PA_REPLACE_DO          = String("__pa_replace_do")
comptime _PA_PROJECT_REPLACE_FIND = String("__pa_project_replace_find")
comptime _PA_PROJECT_REPLACE_DO  = String("__pa_project_replace_do")
comptime _PA_BP_CONDITION        = String("__pa_bp_condition")
comptime _PA_ADD_WATCH           = String("__pa_add_watch")


fn ctrl_key(letter: String) -> UInt32:
    """Return the control-character codepoint for ``Ctrl+letter``.

    Most terminals report ``Ctrl+letter`` as a single control byte (e.g.,
    ``Ctrl+Q`` → ``0x11``) rather than the printable letter with the
    ``MOD_CTRL`` flag. This helper does the conversion so hotkey
    registrations read naturally: ``ctrl_key("q")`` → ``0x11``.
    """
    var b = letter.as_bytes()
    if len(b) == 0:
        return UInt32(0)
    var c = Int(b[0])
    if 0x41 <= c and c <= 0x5A:
        return UInt32(c - 0x40)
    if 0x61 <= c and c <= 0x7A:
        return UInt32(c - 0x60)
    return UInt32(0)


@fieldwise_init
struct Hotkey(ImplicitlyCopyable, Movable):
    """Binding from a (key, modifier) pair to an action string.

    Hotkeys are matched on ``event.key == key and event.mods == mods``;
    the action is then sent through ``Desktop.dispatch_action``.
    """
    var key: UInt32
    var mods: UInt8
    var action: String


fn format_hotkey(key: UInt32, mods: UInt8) -> String:
    """Render a ``(key, mods)`` pair as a human-readable label.

    Used for the right-aligned shortcut text on menu items. The
    control-character form (``mods == MOD_NONE`` and ``0x01..0x1A``) is
    rendered as ``Ctrl+<letter>``, which is what most terminals send for
    the bare ``Ctrl+letter`` combination — the shortcut shown to the user
    matches what they have to press, even though the underlying event
    looks superficially un-modified.
    """
    var k = Int(key)
    if mods == MOD_NONE and 0x01 <= k and k <= 0x1A:
        return String("Ctrl+") + chr(k + 0x40)
    var prefix = String("")
    if (mods & MOD_CTRL) != 0:
        prefix = prefix + String("Ctrl+")
    if (mods & MOD_META) != 0:
        prefix = prefix + String("Cmd+")
    if (mods & MOD_ALT) != 0:
        prefix = prefix + String("Alt+")
    if (mods & MOD_SHIFT) != 0:
        prefix = prefix + String("Shift+")
    if 0x21 <= k and k <= 0x7E:
        var c = k
        if 0x61 <= c and c <= 0x7A:
            c = c - 0x20  # display uppercase for letters
        return prefix + chr(c)
    if k == Int(KEY_F1):  return prefix + String("F1")
    if k == Int(KEY_F2):  return prefix + String("F2")
    if k == Int(KEY_F3):  return prefix + String("F3")
    if k == Int(KEY_F4):  return prefix + String("F4")
    if k == Int(KEY_F5):  return prefix + String("F5")
    if k == Int(KEY_F6):  return prefix + String("F6")
    if k == Int(KEY_F7):  return prefix + String("F7")
    if k == Int(KEY_F8):  return prefix + String("F8")
    if k == Int(KEY_F9):  return prefix + String("F9")
    if k == Int(KEY_F10): return prefix + String("F10")
    if k == Int(KEY_F11): return prefix + String("F11")
    if k == Int(KEY_F12): return prefix + String("F12")
    if k == Int(KEY_UP):       return prefix + String("Up")
    if k == Int(KEY_DOWN):     return prefix + String("Down")
    if k == Int(KEY_LEFT):     return prefix + String("Left")
    if k == Int(KEY_RIGHT):    return prefix + String("Right")
    if k == Int(KEY_HOME):     return prefix + String("Home")
    if k == Int(KEY_END):      return prefix + String("End")
    if k == Int(KEY_PAGEUP):   return prefix + String("PgUp")
    if k == Int(KEY_PAGEDOWN): return prefix + String("PgDn")
    if k == Int(KEY_TAB):       return prefix + String("Tab")
    if k == Int(KEY_ENTER):     return prefix + String("Enter")
    if k == Int(KEY_BACKSPACE): return prefix + String("BkSp")
    if k == Int(KEY_DELETE):    return prefix + String("Del")
    if k == Int(KEY_INSERT):    return prefix + String("Ins")
    if k == Int(KEY_ESC):       return prefix + String("Esc")
    if k == Int(KEY_SPACE):     return prefix + String("Space")
    return prefix + String("?")


struct Desktop(Movable):
    var menu_bar: MenuBar
    var windows: WindowManager
    var status_bar: StatusBar
    var tab_bar: TabBar
    var file_tree: FileTree
    var prompt: Prompt
    var confirm_dialog: ConfirmDialog
    var quick_open: QuickOpen
    var save_as_dialog: SaveAsDialog
    var symbol_pick: SymbolPick
    var project_find: ProjectFind
    var local_changes: LocalChanges
    var targets_dialog: TargetsDialog
    # Fullscreen Settings view (hamburger ▸ Settings). Independent of
    # the modal stack — paints over the workspace but leaves the menu
    # bar and status bar untouched. Edits to ``settings.actions`` are
    # mirrored back into ``self.config.on_save_actions`` and persisted
    # whenever ``settings.dirty`` is True.
    var settings: Settings
    var bg_pattern: String
    var bg_attr: Attr
    var project: Optional[String]
    var _project_menu_idx: Int       # index into menu_bar.menus, or -1
    var _window_menu_idx: Int        # framework-managed Window menu, or -1
    var _pending_action: String      # what to do on next prompt submit
    var _pending_arg: String         # accumulator for two-step prompts
    var _last_search: String         # last Find needle, repeated by Ctrl+G
    var _open_count: Int             # cascade counter for Desktop.open_file
    var _untitled_count: Int         # bumped per ``new_file`` for unique titles
    var _hotkeys: List[Hotkey]       # global key bindings, scanned in order
    var _esc_armed: Bool             # next keystroke is Alt+<letter> (mnemonic)
    # Spawned LSP managers, one per language id, kept in parallel
    # arrays so we can index either by language id or insertion order.
    # Populated lazily by ``_ensure_lsp_for_extension`` — no LSP cost
    # for languages the user never touches. ``lsp_specs`` is the
    # registry the host can extend (today: built-in catalog only); the
    # mapping from extension → spec is independent of which binary we
    # actually end up spawning, so adding a new IDE-bundled server is
    # just a registry edit.
    var lsp_specs: List[LanguageSpec]
    var lsp_managers: List[LspManager]
    var lsp_languages: List[String]
    # DevDocs-style offline documentation. ``doc_specs`` is the registry;
    # ``doc_stores`` / ``doc_languages`` are parallel lists of loaded
    # docsets keyed by language id. Populated lazily — opening a picker
    # is what triggers the install prompt and (on success) the load.
    var doc_specs: List[DocSpec]
    var doc_stores: List[DocStore]
    var doc_languages: List[String]
    var doc_pick: DocPick
    # Language id of the docs install currently in flight. Mirrors
    # ``_install_lang`` but for the docs path so the two install kinds
    # don't fight over the same field. ``install_runner`` is shared:
    # one of LSP-install / docs-install can be in flight at a time.
    var _doc_install_lang: String
    # One nag per language per session for docs (mirrors ``_lsp_install_prompted``).
    var _doc_install_prompted: List[String]
    # Most recently opened docset's language id. Used as the fallback
    # when Ctrl+K fires without a focused editor (or without a
    # recognized file extension) — repeat lookups stay on the same
    # docset across windows so the user can park their cursor in any
    # window and keep searching the same docs.
    var _last_doc_lang: String
    # Process-wide loaded-grammar cache. Editors share this rather
    # than each owning their own per-file copy; closing a buffer
    # and opening another one in the same language reuses the
    # already-compiled grammar instead of re-parsing the JSON and
    # re-allocating libonig handles. ``Desktop.paint`` flushes
    # every editor's highlights against this registry before
    # drawing.
    var grammar_registry: GrammarRegistry
    # Language ids we've already prompted-to-install for in this session.
    # The prompt is one-shot per language: once the user says yes or no,
    # opening another file of the same language doesn't re-nag.
    var _lsp_install_prompted: List[String]
    # Extension of a deferred install prompt: a file was opened while
    # another modal was active, so the prompt couldn't fire then. Drained
    # at the top of ``paint`` whenever no modal is in the way. Empty
    # string = nothing pending.
    var _pending_lsp_prompt_ext: String
    # Background ``sh -c <hint>`` runner for the LSP install prompt. One
    # in-flight install at a time; subsequent prompts fall back to the
    # clipboard-only path while ``install_runner`` is busy.
    var install_runner: InstallRunner
    # Language id of the install currently in flight. We remember it so
    # that on success we can re-attempt to start the LSP for any open
    # editor windows of that language without the user having to close
    # and re-open the file.
    var _install_lang: String
    # Grammar-download bookkeeping (mirrors the LSP install fields above).
    # ``_grammar_install_prompted`` is the one-nag-per-language cap;
    # ``_pending_grammar_prompt_ext`` carries a deferred prompt past a
    # blocking modal; ``_grammar_install_lang`` is the language id whose
    # grammar curl is currently in flight, so the install-complete hook
    # can clear the highlight cache on every open editor of that
    # extension and the colors light up immediately.
    var _grammar_install_prompted: List[String]
    var _pending_grammar_prompt_ext: String
    var _grammar_install_lang: String
    # Debugger state. One ``DapManager`` per Desktop (single concurrent
    # session) — multi-session debugging would need a list keyed by
    # something (language? session id?), and we don't have a use case
    # for that yet. ``dap_specs`` is the registry the host can read /
    # extend; selection happens in ``dispatch_action`` when the user
    # hits F5 or the Debug menu item.
    var dap: DapManager
    var dap_specs: List[DebuggerSpec]
    var debug_pane: DebugPane
    # Latched current-execution location. Painted as ``▶`` in the gutter
    # of whichever editor has a matching ``file_path``. Cleared on
    # ``continued`` / ``terminated`` events.
    var _dap_exec_path: String
    var _dap_exec_line: Int
    # Frame chosen as "current" for variables fetch — top of stack until
    # the user clicks elsewhere. Stored so the scope/variables responses
    # know which frame they belong to even after the pane has been
    # repainted with a different selection.
    var _dap_current_frame_id: Int
    # Label of the scope whose variables are in flight. Used to render
    # ``Locals:`` / ``Globals:`` in the pane when the response lands.
    var _dap_pending_scope_label: String
    # When ``request_variables`` lands, the response goes to one of two
    # destinations: either the initial scope load (replace top of pane)
    # or a tree expansion (splice into existing rows). These fields
    # track which one the next ``has_variables`` should fold into.
    var _dap_var_target_kind: UInt8     # 0=scope_initial, 1=expand
    var _dap_var_target_row: Int
    var _dap_var_target_depth: Int
    # Cached inspect inputs so we can rebuild the pane when only one
    # of (stack, locals, watches) changes.
    var _dap_stack_cache: List[DapStackFrame]
    var _dap_watch_exprs: List[String]
    var _dap_watch_values: List[String]   # parallel to exprs (last result)
    # Persistent global preferences (View-menu toggles for now). Loaded
    # from ``~/.config/turbokod/config.json`` on construction; rewritten
    # there whenever the user toggles a setting. Synced into every
    # editor window every paint so the bool is always the source of
    # truth, regardless of who created the editor.
    var config: TurbokodConfig
    # Per-project run/debug targets, loaded from
    # ``<project>/.turbokod/targets.json`` when ``_set_project`` runs.
    # Empty (no targets) when no project is open. The active index
    # carries through to the status bar's tab strip and to the
    # ``TARGET_RUN`` / ``TARGET_DEBUG`` dispatch.
    var targets: ProjectTargets
    # Single-slot run-session for the active target. ``run_session.matches``
    # tells us whether something is in flight for *this* target, so
    # the tab strip can paint a ``●`` indicator and ``TARGET_RUN``
    # can know whether to terminate before respawning.
    var run_session: RunSession
    # Sticky flag set when a run finishes so the output pane stays
    # visible after the process exits — the user needs to see what
    # happened. Cleared when a new run/debug starts, the project
    # closes, or the user dismisses the pane (ESC while focused).
    var _run_output_held: Bool
    # Per-project window session, persisted in
    # ``<project>/.turbokod/session.json``. ``_pending_restore`` is
    # raised when a project is opened (or auto-detected) so the next
    # ``paint`` performs the restore — needs ``screen`` for window
    # placement, which only ``paint`` has handy. ``_last_session_json``
    # caches the most recently written encoding so we only touch disk
    # when window state actually changes. ``_pending_restore_refit``
    # carries the saved session through to the next resize so the
    # initial restore (often against the host terminal's pre-resize
    # default size) gets re-applied at the now-correct workspace —
    # otherwise rects clipped at startup stay clipped forever even
    # after the host pushes its real dimensions.
    var _pending_restore: Bool
    var _last_session_json: String
    var _pending_restore_refit: Optional[Session]
    # Recently focused file-backed editor paths, most-recent first.
    # Updated each ``paint`` from the focused window's ``file_path``;
    # the front entry is whichever file currently has focus, so the
    # "Open Recent" picker skips index 0 to avoid offering the user
    # the file they're already on. Capped at ``_RECENT_FILES_MAX``.
    var _recent_files: List[String]

    fn __init__(out self):
        self.menu_bar = MenuBar()
        self.windows = WindowManager()
        self.status_bar = StatusBar()
        self.tab_bar = TabBar()
        self.file_tree = FileTree()
        self.prompt = Prompt()
        self.confirm_dialog = ConfirmDialog()
        self.quick_open = QuickOpen()
        self.save_as_dialog = SaveAsDialog()
        self.symbol_pick = SymbolPick()
        self.project_find = ProjectFind()
        self.local_changes = LocalChanges()
        self.targets_dialog = TargetsDialog()
        self.settings = Settings()
        self.bg_pattern = String("▒")
        self.bg_attr = Attr(LIGHT_GRAY, BLUE)
        self.project = Optional[String]()
        self._project_menu_idx = -1
        self._window_menu_idx = -1
        self._pending_action = String("")
        self._pending_arg = String("")
        self._last_search = String("")
        self._open_count = 0
        self._untitled_count = 0
        self._hotkeys = List[Hotkey]()
        self._esc_armed = False
        self.lsp_specs = built_in_servers()
        self.lsp_managers = List[LspManager]()
        self.lsp_languages = List[String]()
        self.doc_specs = built_in_docsets()
        self.doc_stores = List[DocStore]()
        self.doc_languages = List[String]()
        self.doc_pick = DocPick()
        self._doc_install_lang = String("")
        self._doc_install_prompted = List[String]()
        self._last_doc_lang = String("")
        self.grammar_registry = GrammarRegistry()
        self._lsp_install_prompted = List[String]()
        self._pending_lsp_prompt_ext = String("")
        self.install_runner = InstallRunner()
        self._install_lang = String("")
        self._grammar_install_prompted = List[String]()
        self._pending_grammar_prompt_ext = String("")
        self._grammar_install_lang = String("")
        self.dap = DapManager()
        self.dap_specs = built_in_debuggers()
        self.debug_pane = DebugPane()
        self._dap_exec_path = String("")
        self._dap_exec_line = -1
        self._dap_current_frame_id = -1
        self._dap_pending_scope_label = String("")
        self._dap_var_target_kind = UInt8(0)
        self._dap_var_target_row = -1
        self._dap_var_target_depth = 0
        self._dap_stack_cache = List[DapStackFrame]()
        self._dap_watch_exprs = List[String]()
        self._dap_watch_values = List[String]()
        self.config = load_config()
        self.targets = ProjectTargets()
        self.run_session = RunSession()
        self._run_output_held = False
        self._pending_restore = False
        self._last_session_json = String("")
        self._pending_restore_refit = Optional[Session]()
        self._recent_files = List[String]()
        # Add the framework's dynamic Window menu up-front so it renders in
        # the natural position (left-aligned, after whatever the host adds).
        # ``_rebuild_window_menu`` repopulates its items every paint.
        self.menu_bar.add(Menu(_WINDOW_MENU_LABEL, List[MenuItem]()))
        self._window_menu_idx = len(self.menu_bar.menus) - 1
        # Default hotkeys. ``Ctrl+letter`` arrives as a control character on
        # almost every terminal, so the bindings are stored as the raw
        # control codepoint with ``MOD_NONE``. ``Ctrl+Shift+letter`` requires
        # a terminal that reports modifiers for letter keys (CSI u or
        # modifyOtherKeys=2 — limited support today); the bindings are still
        # registered so they work as soon as parser support lands.
        self._hotkeys.append(Hotkey(ctrl_key("q"), MOD_NONE, APP_QUIT_ACTION))
        self._hotkeys.append(Hotkey(ctrl_key("w"), MOD_NONE, WINDOW_CLOSE))
        self._hotkeys.append(Hotkey(ctrl_key("n"), MOD_NONE, EDITOR_NEW))
        self._hotkeys.append(Hotkey(ctrl_key("o"), MOD_NONE, EDITOR_QUICK_OPEN))
        self._hotkeys.append(Hotkey(ctrl_key("e"), MOD_NONE, EDITOR_OPEN_RECENT))
        self._hotkeys.append(Hotkey(ctrl_key("s"), MOD_NONE, EDITOR_SAVE))
        self._hotkeys.append(Hotkey(ctrl_key("f"), MOD_NONE, EDITOR_FIND))
        # Ctrl/Cmd+H for replace (matches VS Code). Ctrl+R is the
        # run-target shortcut below, so the old Ctrl+R-for-replace
        # binding had to move; H is the de-facto cross-editor default.
        self._hotkeys.append(Hotkey(ctrl_key("h"), MOD_NONE, EDITOR_REPLACE))
        self._hotkeys.append(Hotkey(ctrl_key("g"), MOD_NONE, EDITOR_FIND_NEXT))
        self._hotkeys.append(Hotkey(ctrl_key("l"), MOD_NONE, EDITOR_GOTO))
        self._hotkeys.append(Hotkey(ctrl_key("t"), MOD_NONE, EDITOR_GOTO_SYMBOL))
        self._hotkeys.append(Hotkey(ctrl_key("k"), MOD_NONE, EDITOR_LOOKUP_DOCS))
        # Clipboard + undo/redo. Registering Ctrl+X/C/V at the desktop layer
        # serves two purposes: the menu items get auto-populated shortcut
        # text via ``_shortcut_for_action``, and the dispatch path is
        # uniform whether the user clicks a menu or hits the key. Ctrl+Z /
        # Ctrl+Y use the de-facto-standard binding.
        self._hotkeys.append(Hotkey(ctrl_key("x"), MOD_NONE, EDITOR_CUT))
        self._hotkeys.append(Hotkey(ctrl_key("c"), MOD_NONE, EDITOR_COPY))
        self._hotkeys.append(Hotkey(ctrl_key("v"), MOD_NONE, EDITOR_PASTE))
        self._hotkeys.append(Hotkey(ctrl_key("z"), MOD_NONE, EDITOR_UNDO))
        self._hotkeys.append(Hotkey(ctrl_key("y"), MOD_NONE, EDITOR_REDO))
        self._hotkeys.append(Hotkey(
            UInt32(ord("f")), MOD_CTRL | MOD_SHIFT, PROJECT_FIND,
        ))
        self._hotkeys.append(Hotkey(
            UInt32(ord("r")), MOD_CTRL | MOD_SHIFT, PROJECT_REPLACE,
        ))
        # Find Previous: Ctrl/Cmd+Shift+G is the de-facto cross-platform
        # binding (matches VS Code, JetBrains, browsers, …). On macOS the
        # bundled native app reports Cmd+Shift+G as ``MOD_CTRL|MOD_SHIFT``
        # over the same channel as Ctrl-shortcuts.
        self._hotkeys.append(Hotkey(
            UInt32(ord("g")), MOD_CTRL | MOD_SHIFT, EDITOR_FIND_PREV,
        ))
        # Window switching: Ctrl+1 .. Ctrl+9 focus the first nine windows by
        # the same number shown in the top-right of each window's chrome.
        # Each binding's action carries the target index, so the dynamic
        # Window menu's items get matching ``Ctrl+N`` shortcut text via
        # ``_refresh_shortcuts`` without any extra wiring.
        for n in range(9):
            self._hotkeys.append(Hotkey(
                UInt32(ord("1") + n),
                MOD_CTRL,
                WINDOW_FOCUS_PREFIX + String(n),
            ))
        # Side-panel focus: Ctrl+0 → file tree, Ctrl+9 → debug pane.
        # These match the ``0`` / ``9`` glyphs each panel paints in
        # its top-right corner. Registered after the Ctrl+1..9 loop
        # so the Ctrl+9 binding here wins over the (rare) 9th window
        # — the lookup walks newest-first, and a debug pane is far
        # more commonly reached than a 9th open window.
        self._hotkeys.append(Hotkey(
            UInt32(ord("0")), MOD_CTRL, FILE_TREE_FOCUS,
        ))
        self._hotkeys.append(Hotkey(
            UInt32(ord("9")), MOD_CTRL, DEBUG_FOCUS_PANE,
        ))
        # Debugger bindings: F5 / F9 / F10 / F11 / Shift+F11 / Shift+F5 —
        # the de facto standard set across VS Code, JetBrains, and most
        # other IDEs. Registered after the Ctrl-letter set so any user
        # override registered later still wins (the lookup walks
        # newest-first).
        self._hotkeys.append(Hotkey(
            KEY_F5, MOD_NONE, DEBUG_START_OR_CONTINUE,
        ))
        self._hotkeys.append(Hotkey(KEY_F5, MOD_SHIFT, DEBUG_STOP))
        self._hotkeys.append(Hotkey(
            KEY_F9, MOD_NONE, DEBUG_TOGGLE_BREAKPOINT,
        ))
        self._hotkeys.append(Hotkey(
            KEY_F9, MOD_SHIFT, DEBUG_CONDITIONAL_BP,
        ))
        self._hotkeys.append(Hotkey(KEY_F10, MOD_NONE, DEBUG_STEP_OVER))
        self._hotkeys.append(Hotkey(KEY_F11, MOD_NONE, DEBUG_STEP_IN))
        self._hotkeys.append(Hotkey(KEY_F11, MOD_SHIFT, DEBUG_STEP_OUT))
        # F8: toggle debug pane focus. Workaround until pane-mouse
        # works; arrow keys then scroll the stack list while the
        # pane is focused.
        self._hotkeys.append(Hotkey(KEY_F8, MOD_NONE, DEBUG_FOCUS_PANE))
        # Cmd+R / Cmd+D — run / debug the active project target.
        # On macOS terminals Cmd+letter is folded to MOD_CTRL by the
        # terminal parser (see ``events.MOD_META``), so a single
        # binding on ``ctrl_key`` covers both ⌘ and Ctrl. Registered
        # last so they win the newest-first hotkey lookup against the
        # earlier Ctrl-letter defaults.
        self._hotkeys.append(Hotkey(ctrl_key("r"), MOD_NONE, TARGET_RUN))
        self._hotkeys.append(Hotkey(ctrl_key("d"), MOD_NONE, TARGET_DEBUG))
        self._hotkeys.append(Hotkey(ctrl_key("t"), MOD_NONE, TARGET_TEST))
        # Cmd+` / Cmd+Shift+` — cycle through windows forward / backward
        # in stable insertion order. Cmd+letter folds onto Ctrl+letter
        # via MOD_META, but backtick isn't a letter, so it keeps its
        # MOD_CTRL flag here. Shift+` produces ``~`` on US layouts; we
        # bind both glyphs so the reverse rotation works regardless of
        # whether the terminal reports the shifted or unshifted codepoint.
        self._hotkeys.append(Hotkey(
            UInt32(ord("`")), MOD_CTRL, WINDOW_ROTATE_NEXT,
        ))
        self._hotkeys.append(Hotkey(
            UInt32(ord("`")), MOD_CTRL | MOD_SHIFT, WINDOW_ROTATE_PREV,
        ))
        self._hotkeys.append(Hotkey(
            UInt32(ord("~")), MOD_CTRL | MOD_SHIFT, WINDOW_ROTATE_PREV,
        ))

    fn _bottom_chrome_height(self, screen: Rect) -> Int:
        """Rows the bottom chrome (status bar + optional tab bar) eats
        from the workspace. The status bar is always one row; the
        tab bar adds another when the View toggle is on, but only
        if the screen is tall enough to host both rows above the
        menu bar."""
        if self.config.tab_bar and screen.b.y - 2 >= 1:
            return 2
        return 1

    fn workspace_rect(self, screen: Rect) -> Rect:
        """Floating-window area: between menu bar, status bar, and any docked
        widgets. The file tree, when visible, eats space on the right; the
        debug pane, when active, eats space at the bottom."""
        var right = screen.b.x
        if self.file_tree.visible:
            right -= self.file_tree.width
            if right < 0:
                right = 0
        var bottom = screen.b.y - self._bottom_chrome_height(screen)
        if self.debug_pane.visible:
            bottom -= self._debug_pane_height(screen)
            if bottom < 1:
                bottom = 1
        return Rect(0, 1, right, bottom)

    fn debug_pane_rect(self, screen: Rect) -> Rect:
        """Where the bottom-docked debug pane lives — above the status
        bar (and the tab bar, when visible) which together always
        sit at the screen's bottom edge."""
        if not self.debug_pane.visible:
            return Rect.empty()
        var chrome = self._bottom_chrome_height(screen)
        var top = screen.b.y - chrome - self._debug_pane_height(screen)
        if top < 1:
            top = 1
        return Rect(0, top, screen.b.x, screen.b.y - chrome)

    fn _debug_pane_height(self, screen: Rect) -> Int:
        """Effective rendered height for the debug pane, considering
        its window state. NORMAL → ``preferred_height`` (user's drag
        target). MINIMIZED → 1 (header row only). MAXIMIZED → fill the
        whole bottom area, leaving just the menu bar above and the
        status / tab strip below."""
        if self.debug_pane.state == PANE_STATE_MINIMIZED:
            return 1
        if self.debug_pane.state == PANE_STATE_MAXIMIZED:
            var avail = screen.b.y - self._bottom_chrome_height(screen) - 1
            if avail < 4:
                avail = 4
            return avail
        return self.debug_pane.preferred_height

    fn tab_bar_rect(self, screen: Rect) -> Rect:
        """Single-row strip directly above the status bar holding one
        tab per open window. Empty when the View toggle is off."""
        if not self.config.tab_bar:
            return Rect.empty()
        var y = screen.b.y - 2
        if y < 1:
            return Rect.empty()
        return Rect(0, y, screen.b.x, y + 1)

    fn pointer_shape_at(self, pos: Point, screen: Rect) -> String:
        """Mouse-pointer icon the host should display at ``pos``.

        ``"text"`` over a text-input region (editor body, prompt input,
        dialog filename / search inputs) — anywhere a click lands or an
        I-beam helps the user line up a caret. ``"default"`` everywhere
        else: chrome, list rows, buttons. Hosts that don't speak the
        OSC just ignore whatever shape we ask for, so this is purely a
        UX hint."""
        # Menu bar — both the bar itself and any open dropdown sit on
        # top of every other layer, so resolve them first.
        if pos.y == 0:
            return String("default")
        if self.menu_bar.is_open() \
                and self.menu_bar._dropdown_rect(screen.b.x).contains(pos):
            return String("default")
        # Modals win — they cover whatever's underneath. Resolve in the
        # same order ``handle_event`` consults them so the shape matches
        # which widget would actually claim the next click.
        if self.prompt.active:
            if self._prompt_input_rect(screen).contains(pos):
                return String("text")
            return String("default")
        if self.confirm_dialog.active:
            return String("default")
        if self.save_as_dialog.active:
            if self.save_as_dialog.is_input_at(pos, screen):
                return String("text")
            return String("default")
        if self.quick_open.active:
            if self.quick_open.is_input_at(pos, screen):
                return String("text")
            return String("default")
        if self.symbol_pick.active:
            if self.symbol_pick.is_input_at(pos, screen):
                return String("text")
            return String("default")
        if self.doc_pick.active:
            if self.doc_pick.is_input_at(pos, screen):
                return String("text")
            return String("default")
        if self.project_find.active:
            if self.project_find.is_input_at(pos, screen):
                return String("text")
            return String("default")
        if self.local_changes.active:
            return String("default")
        if self.targets_dialog.active:
            if self.targets_dialog.is_input_at(pos, screen):
                return String("text")
            return String("default")
        # Resize edges of the docked side panels — checked before the
        # window pass so the cursor flips the moment the user crosses
        # the border, even when an editor's interior would otherwise
        # claim the cell. An in-flight drag also pins the cursor in
        # the resize shape so it doesn't flicker as the pointer moves
        # across the workspace.
        if self.debug_pane.is_resizing() \
                or self.debug_pane.is_on_resize_edge(
                    pos, self.debug_pane_rect(screen)
                ):
            return String("ns-resize")
        if self.file_tree.is_resizing() \
                or self.file_tree.is_on_resize_edge(pos, screen):
            return String("ew-resize")
        # Topmost editor window's interior.
        var workspace = self.workspace_rect(screen)
        if workspace.contains(pos):
            var k = len(self.windows.z_order) - 1
            while k >= 0:
                var i = self.windows.z_order[k]
                var win = self.windows.windows[i]
                if win.rect.contains(pos):
                    if win.is_editor and win.interior().contains(pos):
                        return String("text")
                    return String("default")
                k -= 1
        return String("default")

    fn _prompt_input_rect(self, screen: Rect) -> Rect:
        """Mirror of the layout in ``Prompt.paint``: the input row is the
        middle line of the centered 3-row box. Kept here so we can hit-
        test without forcing ``Prompt`` to retain layout state."""
        var width = 60
        if width > screen.b.x - 4:
            width = screen.b.x - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - 3) // 2
        return Rect(x + 1, y + 1, x + width - 1, y + 2)

    fn _apply_view_config(mut self):
        """Push ``self.config`` into every editor window. Called every
        paint so the global preference is the source of truth no matter
        who created the editor (Desktop API, host calling
        ``Window.editor_window`` directly, etc.). Cheap — two boolean
        writes per editor.

        Read-only editors (the docs viewer) are special-cased: line
        numbers are forced off regardless of the global toggle, since
        a rendered docs page isn't a numbered source file."""
        # Sync the View-menu checkmarks with the current config so the
        # dropdown always reflects the live state (Desktop owns the
        # config, the host owns the menu items, and this is the one
        # place both are reachable).
        self.menu_bar.set_item_checked(
            EDITOR_TOGGLE_LINE_NUMBERS, self.config.line_numbers,
        )
        self.menu_bar.set_item_checked(
            EDITOR_TOGGLE_SOFT_WRAP, self.config.soft_wrap,
        )
        self.menu_bar.set_item_checked(
            EDITOR_TOGGLE_GIT_CHANGES, self.config.git_changes,
        )
        self.menu_bar.set_item_checked(
            EDITOR_TOGGLE_TAB_BAR, self.config.tab_bar,
        )
        # Resolve "is this a git repo" once. The check is cheap (a stat
        # walk up to ``/``), but doing it once per editor per frame
        # adds up; ``self.project`` is the only relevant root because
        # editors without a project still share the desktop's git
        # context.
        var have_git = False
        var root = String("")
        if self.project:
            root = self.project.value()
            have_git = project_is_git_repo(root)
        for i in range(len(self.windows.windows)):
            if not self.windows.windows[i].is_editor:
                continue
            if self.windows.windows[i].editor.read_only:
                self.windows.windows[i].editor.line_numbers = False
            else:
                self.windows.windows[i].editor.line_numbers = self.config.line_numbers
            self.windows.windows[i].editor.soft_wrap = self.config.soft_wrap
            if self.config.soft_wrap:
                # Soft-wrap forces a left-aligned visible area; keep the
                # invariant even if the host poked ``scroll_x`` directly.
                self.windows.windows[i].editor.scroll_x = 0
            # Git-changes column. Read-only editors (the docs viewer)
            # always skip it. When the toggle's on and we haven't
            # cached lines yet, spawn ``git diff HEAD -- <file>`` once
            # — subsequent paints reuse the cache. ``invalidate_git_changes``
            # on save / reload gets the next paint to refresh.
            if self.windows.windows[i].editor.read_only:
                self.windows.windows[i].editor.git_changes_visible = False
            else:
                self.windows.windows[i].editor.git_changes_visible = \
                    self.config.git_changes and have_git
                if self.config.git_changes and have_git:
                    var fp = self.windows.windows[i].editor.file_path
                    # Step 1: fetch HEAD content once per file. Bracket
                    # the spawn with the loaded flag so untracked / new
                    # files don't re-spawn ``git show`` every paint.
                    if len(fp.as_bytes()) > 0 \
                            and not self.windows.windows[i].editor._git_head_loaded:
                        var head = fetch_head_text(root, fp)
                        if head:
                            self.windows.windows[i].editor.set_git_head_text(
                                head.value(), True,
                            )
                        else:
                            self.windows.windows[i].editor.set_git_head_text(
                                String(""), False,
                            )
                    # Step 2: re-diff the buffer against the cached
                    # baseline whenever the buffer has changed. The
                    # diff is in-process (Myers), no spawn — fine to
                    # do per paint while the user types.
                    if self.windows.windows[i].editor._git_head_present \
                            and self.windows.windows[i].editor._git_changes_dirty:
                        var buf_lines = \
                            self.windows.windows[i].editor.buffer.lines.copy()
                        var head_text = \
                            self.windows.windows[i].editor._git_head_text
                        var lines = diff_buffer_against_head(
                            head_text, buf_lines,
                        )
                        self.windows.windows[i].editor.set_git_changes(lines^)

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        # Drive any per-frame timers before drawing — the project-find
        # widget runs its 200 ms debounce off this clock.
        self.project_find.tick(monotonic_ms())
        # Update the recents list from whichever editor is focused this
        # frame. Cheap (one path compare against ``_recent_files[0]``)
        # on idle frames; promotes a path to the front exactly once
        # whenever focus actually moves.
        self._track_recent_focus()
        # Restore the saved per-project window session before any
        # other per-frame work so newly-restored editors see the same
        # treatment (highlight flush, view-config sync, fit-into) as
        # ones that were already open. The flag is one-shot: armed in
        # ``_set_project`` and cleared here even on failure.
        if self._pending_restore:
            self._pending_restore = False
            self._restore_session(screen)
        # If a file-open earlier deferred the install prompt because some
        # other modal was up, retry now. ``_maybe_prompt_lsp_install``
        # re-defers on a fresh `pending_*` field if a modal is *still*
        # in the way, so this is safe to call unconditionally.
        if len(self._pending_lsp_prompt_ext.as_bytes()) > 0:
            var deferred_ext = self._pending_lsp_prompt_ext
            self._pending_lsp_prompt_ext = String("")
            self._maybe_prompt_lsp_install(deferred_ext)
        # Same one-shot drain for the grammar-download prompt. Independent
        # from the LSP one — opening an Elm file when no Elm LSP install
        # spec exists still wants the grammar prompt to fire.
        if len(self._pending_grammar_prompt_ext.as_bytes()) > 0:
            var deferred_ext = self._pending_grammar_prompt_ext
            self._pending_grammar_prompt_ext = String("")
            self._maybe_prompt_grammar_install(deferred_ext)
        # Sync the persisted view config into every editor before
        # measurement / paint so newly-added windows pick up the user's
        # saved preferences on their first frame.
        self._apply_view_config()
        # Flush deferred highlight refreshes for every editor that
        # was edited since the last frame. ``flush_highlights`` is
        # a no-op when the dirty flag is clear, so this is cheap on
        # idle frames; on edited frames it does the actual TextMate
        # tokenization against the shared ``grammar_registry``.
        for i in range(len(self.windows.windows)):
            if self.windows.windows[i].is_editor:
                self.windows.windows[i].editor.flush_highlights(
                    self.grammar_registry,
                )
        # Refit windows to the current workspace before painting. Cheap
        # (idempotent for already-fitting windows) and covers both file
        # tree toggles and terminal resizes uniformly.
        self.windows.fit_into(self.workspace_rect(screen))
        # Rebuild the Window menu from current state so it always reflects
        # what's actually open. (Cheap; one short item list.)
        self._rebuild_window_menu()
        # Stamp the right-aligned shortcut text onto each menu item so it
        # picks up user-registered hotkey overrides automatically.
        self._refresh_shortcuts()
        # Refresh the target-tab strip every frame so tab indicators
        # (running, debugging, active) stay in sync with the actual
        # session state — single source of truth for the painter.
        self._refresh_target_tabs()
        canvas.fill(self.workspace_rect(screen), self.bg_pattern, self.bg_attr)
        self.windows.paint(canvas)
        self.file_tree.paint(canvas, screen)
        self.debug_pane.paint(canvas, self.debug_pane_rect(screen))
        self.menu_bar.paint(canvas, screen)
        self._paint_tab_bar(canvas, screen)
        self.status_bar.paint(canvas, screen)
        # Non-modal install-progress popup. Sits between the workspace and
        # the modal dialogs — visible while the user keeps editing, but
        # dismissed by any modal that pops over the top.
        self.install_runner.paint(canvas, screen)
        # Modal layers float above everything else. Only one is ever active
        # at a time (open_quick_open won't fire while a prompt is up, etc.),
        # so paint order doesn't matter for correctness.
        self.prompt.paint(canvas, screen)
        self.confirm_dialog.paint(canvas, screen)
        self.quick_open.paint(canvas, screen)
        self.save_as_dialog.paint(canvas, screen)
        self.symbol_pick.paint(canvas, screen)
        self.doc_pick.paint(canvas, screen)
        self.project_find.paint(canvas, screen, self.grammar_registry)
        self.local_changes.paint(canvas, screen)
        self.targets_dialog.paint(canvas, screen)
        # Settings overlay — paints over the workspace but below the
        # modal dialogs so an in-flight prompt is still visible. Drains
        # ``settings.dirty`` into the persisted config so user changes
        # survive a restart without an explicit "save settings" step.
        self.settings.paint(canvas, screen)
        if self.settings.active and self.settings.dirty:
            self.config.on_save_actions = self.settings.actions.copy()
            _ = save_config(self.config)
            self.settings.ack_dirty()
        # Persist the window session if it changed since the last save.
        # No-op when no project is open or no file-backed windows are
        # showing — closing the last window leaves the previously-saved
        # session intact so the next ``open_project`` can restore it.
        self._save_session_if_changed()

    fn _shortcut_for_action(self, action: String) -> String:
        """Reverse-lookup the most recently registered hotkey for ``action``
        (matching the dispatch order — newest wins). Empty string if none."""
        if len(action.as_bytes()) == 0:
            return String("")
        var i = len(self._hotkeys) - 1
        while i >= 0:
            if self._hotkeys[i].action == action:
                return format_hotkey(self._hotkeys[i].key, self._hotkeys[i].mods)
            i -= 1
        return String("")

    fn _refresh_shortcuts(mut self):
        for m in range(len(self.menu_bar.menus)):
            for it in range(len(self.menu_bar.menus[m].items)):
                if self.menu_bar.menus[m].items[it].is_separator:
                    continue
                var action = self.menu_bar.menus[m].items[it].action
                self.menu_bar.menus[m].items[it].shortcut = \
                    self._shortcut_for_action(action)

    # --- opening files -----------------------------------------------------

    fn open_file(mut self, path: String, screen: Rect) raises:
        """Open ``path`` as an editor window using framework defaults.

        Sizing: 80% of the current workspace, clamped to the workspace and
        to ``MIN_WIN_*``. Position: cascaded down-and-right by ``+1, +1``
        each call (mod-wraps when it would otherwise walk off-screen).
        Maximization: if the frontmost window is currently maximized, the
        new window starts maximized too — the underlying ``_restore_rect``
        is the 80% rect, so toggling maximize off lands on the cascade slot.
        Project: ``detect_project_from(path)`` runs first so the project
        menu reflects the new file's repo on the same frame.

        If the file is a Mojo source file, the LSP server is spawned (once)
        and notified about the new document so cmd+click goto-definition
        works without any extra wiring on the host side.

        If a window for the same file is already open, focus is moved
        to that window and a second copy is **not** created — re-opening
        is a no-op rather than a way to multiply windows on the same
        path. Path comparison uses ``realpath`` so symlink + canonical
        spellings are treated as the same file.
        """
        var existing = self._find_window_for_path(path)
        if existing >= 0:
            self.windows.focus_by_index(existing)
            return
        self.detect_project_from(path)
        var workspace = self.workspace_rect(screen)
        var rect = self._default_window_rect(workspace)
        var was_max = self._frontmost_maximized()
        var w = Window.from_file(basename(path), rect, path)
        self.windows.add(w^)
        self._open_count += 1
        if was_max:
            var idx = len(self.windows.windows) - 1
            self.windows.windows[idx].toggle_maximize(workspace)
        self._maybe_lsp_open(len(self.windows.windows) - 1)

    fn open_file_at(
        mut self, path: String, line: Int, character: Int, screen: Rect,
    ) raises:
        """Open ``path`` (or focus the existing window for it) and place
        the cursor at ``(line, character)`` (both 0-based).

        Used by the URL-scheme handler so ``turbokod://open?file=X&line=N``
        lands on the right line. Re-opens are a no-op the same way
        ``open_file`` is — but the cursor still jumps, so a URL targeting
        an already-open file still lands the user on the requested
        spot.
        """
        var existing = self._find_window_for_path(path)
        if existing < 0:
            self.open_file(path, screen)
            existing = len(self.windows.windows) - 1
        else:
            self.windows.focus_by_index(existing)
        if existing < 0 or existing >= len(self.windows.windows):
            return
        if not self.windows.windows[existing].is_editor:
            return
        var lc = self.windows.windows[existing].editor.buffer.line_count()
        var row = line
        if row < 0:
            row = 0
        if lc > 0 and row >= lc:
            row = lc - 1
        var col = character
        if col < 0:
            col = 0
        self.windows.windows[existing].editor.move_to(row, col, False, True)
        self.windows.windows[existing].editor.reveal_cursor(
            self.windows.windows[existing].interior(),
        )

    fn new_file(mut self, screen: Rect):
        """Open a fresh, file-less editor window using the same placement
        rules as ``open_file``. The first window is titled ``Untitled``;
        subsequent ones get a numeric suffix so the dynamic Window menu
        and per-window save prompts stay distinguishable.
        """
        self._untitled_count += 1
        var title = String("Untitled")
        if self._untitled_count > 1:
            title = title + String(" ") + String(self._untitled_count)
        var workspace = self.workspace_rect(screen)
        var rect = self._default_window_rect(workspace)
        var was_max = self._frontmost_maximized()
        self.windows.add(Window.editor_window(title^, rect, String("")))
        self._open_count += 1
        if was_max:
            var idx = len(self.windows.windows) - 1
            self.windows.windows[idx].toggle_maximize(workspace)

    fn _maybe_lsp_open(mut self, idx: Int):
        """If the window at ``idx`` is an editor for a recognized source
        file type, ensure the matching LSP server is started and inform
        it of this document.

        If the file type is known to the registry but no candidate binary
        is on ``$PATH``, surface an "Install <lang> LSP?" prompt — once
        per language per session, and only when the spec carries a
        non-empty ``install_hint`` (otherwise we'd have nothing actionable
        to suggest). Truly unknown extensions stay a silent no-op.
        """
        if idx < 0 or idx >= len(self.windows.windows):
            return
        if not self.windows.windows[idx].is_editor:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            return
        var ext = extension_of(path)
        # Grammar-download is independent from LSP install — a language
        # might have either, both, or neither. Try the grammar prompt
        # unconditionally; the helper bails fast when there's nothing
        # to ask about.
        self._maybe_prompt_grammar_install(ext)
        var lsp_idx = self._ensure_lsp_for_extension(ext)
        if lsp_idx < 0:
            self._maybe_prompt_lsp_install(ext)
            return
        var text = self.windows.windows[idx].editor.text_snapshot()
        self.lsp_managers[lsp_idx].notify_opened(path, text^)

    fn _maybe_prompt_lsp_install(mut self, ext: String):
        """Open the install prompt when ``ext`` belongs to a known language
        whose binary isn't on ``$PATH``.

        Bails permanently when: the extension isn't in our catalog, the
        spec has no install hint, the user has already been prompted for
        this language this session, or one of the candidate binaries is
        already installed. When the only blocker is an active modal
        (file picker, quick-open, etc.), we *defer* via
        ``_pending_lsp_prompt_ext`` and ``paint`` drains it on a later
        frame — otherwise opening a file from a dialog would silently
        eat the install prompt for that language."""
        var spec_idx = find_language_for_extension(self.lsp_specs, ext)
        if spec_idx < 0:
            return
        var spec = self.lsp_specs[spec_idx]
        if len(spec.install_hint.as_bytes()) == 0:
            return
        # One nag per language per session, regardless of yes/no.
        for i in range(len(self._lsp_install_prompted)):
            if self._lsp_install_prompted[i] == spec.language_id:
                return
        # Belt-and-suspenders: re-check that no candidate is on PATH.
        # ``_ensure_lsp_for_extension`` only returns -1-with-known-extension
        # when this is true, so this guards against future refactors.
        for c in range(len(spec.candidates)):
            var cand = spec.candidates[c]
            if len(cand.argv) > 0 \
                    and len(which(cand.argv[0]).as_bytes()) > 0:
                return
        # If something else is modal, defer rather than drop. First-
        # deferred wins — once a prompt is queued, opening another
        # unsupported language while still modal doesn't bump it.
        if self.prompt.active or self.confirm_dialog.active \
                or self.quick_open.active \
                or self.symbol_pick.active or self.project_find.active \
                or self.local_changes.active \
                or self.save_as_dialog.active or self.doc_pick.active:
            if len(self._pending_lsp_prompt_ext.as_bytes()) == 0:
                self._pending_lsp_prompt_ext = ext
            return
        self._lsp_install_prompted.append(spec.language_id)
        self._pending_action = _PA_LSP_INSTALL
        self._pending_arg = spec.language_id
        self.confirm_dialog.open(
            String("Install ") + spec.language_id + String(" LSP? '")
            + spec.install_hint + String("'")
        )

    fn _maybe_prompt_grammar_install(mut self, ext: String):
        """Open the "Install <lang> grammar?" prompt when ``ext`` belongs
        to a language in the downloadable-grammar registry and isn't
        already installed under ``~/.config/turbokod/languages/``.

        Mirrors ``_maybe_prompt_lsp_install`` exactly: one-nag-per-
        language-per-session, deferred via ``_pending_grammar_prompt_ext``
        when another modal owns the screen, silent no-op otherwise.
        Independent from the LSP prompt — both can fire on the same
        file open (in sequence), since neither is a substitute for
        the other.
        """
        var specs = built_in_downloadable_grammars()
        var spec_idx = find_downloadable_grammar_for_extension(specs, ext)
        if spec_idx < 0:
            return
        var spec = specs[spec_idx]
        if user_grammar_installed(spec.language_id):
            return
        for i in range(len(self._grammar_install_prompted)):
            if self._grammar_install_prompted[i] == spec.language_id:
                return
        if self.prompt.active or self.confirm_dialog.active \
                or self.quick_open.active \
                or self.symbol_pick.active or self.project_find.active \
                or self.local_changes.active \
                or self.save_as_dialog.active or self.doc_pick.active:
            if len(self._pending_grammar_prompt_ext.as_bytes()) == 0:
                self._pending_grammar_prompt_ext = ext
            return
        self._grammar_install_prompted.append(spec.language_id)
        self._pending_action = _PA_GRAMMAR_INSTALL
        self._pending_arg = spec.language_id
        self.confirm_dialog.open(
            String("Download ") + spec.display
                + String(" syntax grammar?")
        )

    fn _start_grammar_install(mut self, lang: String):
        """Spawn the curl that drops the grammar JSON into the user
        config dir. Single-slot ``InstallRunner`` — if an LSP or docs
        install is already running, surface the conflict on the status
        bar rather than queue, since the popup only renders one at a
        time."""
        var specs = built_in_downloadable_grammars()
        var spec_idx = find_downloadable_grammar_by_language(specs, lang)
        if spec_idx < 0:
            return
        var spec = specs[spec_idx]
        var cmd = grammar_install_command(spec.language_id, spec.url)
        if self.install_runner.is_active():
            self.status_bar.set_message(
                String("Install busy; try ") + spec.display
                    + String(" grammar again in a moment"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        try:
            self.install_runner.start(
                spec.display + String(" grammar"), cmd,
            )
            self._grammar_install_lang = lang
            self.status_bar.set_message(
                String("Downloading ") + spec.display + String(" grammar..."),
                Attr(BLACK, LIGHT_GRAY),
            )
        except:
            self.status_bar.set_message(
                String("Failed to start grammar download"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )

    fn _on_grammar_install_complete(
        mut self, result: InstallResult, screen: Rect,
    ):
        """React to a grammar-download finishing. Success: invalidate
        the highlight cache for any open editor whose extension matches
        this language so the new grammar takes effect on the next paint
        without needing the user to close+reopen the file. Failure:
        same shape as the LSP install path — pop the curl output into a
        new editor window."""
        var lang = self._grammar_install_lang
        self._grammar_install_lang = String("")
        if result.ok():
            self.status_bar.set_message(
                String("Installed ") + result.label,
                Attr(BLACK, LIGHT_GRAY),
            )
            # Drop the cached compile of any prior in-process state for
            # this language, then mark every editor's per-buffer cache
            # dirty so the next refresh tokenizes from row 0 against the
            # freshly-downloaded grammar.
            var specs = built_in_downloadable_grammars()
            var spec_idx = find_downloadable_grammar_by_language(specs, lang)
            if spec_idx < 0:
                return
            var spec = specs[spec_idx]
            for i in range(len(self.windows.windows)):
                if not self.windows.windows[i].is_editor:
                    continue
                var path = self.windows.windows[i].editor.file_path
                if len(path.as_bytes()) == 0:
                    continue
                var ext = extension_of(path)
                var matched = False
                for k in range(len(spec.file_types)):
                    if spec.file_types[k] == ext:
                        matched = True
                        break
                if matched:
                    self.windows.windows[i].editor.invalidate_highlight_cache()
        else:
            var title = String("Grammar install failed: ") + result.label \
                + String(" (exit ") + String(result.exit_code()) + String(")")
            var workspace = self.workspace_rect(screen)
            var rect = self._default_window_rect(workspace)
            var was_max = self._frontmost_maximized()
            var body = String("$ ") + result.command + String("\n\n") \
                + result.output
            self.windows.add(Window.editor_window(title^, rect, body^))
            self._open_count += 1
            if was_max:
                var win_idx = len(self.windows.windows) - 1
                self.windows.windows[win_idx].toggle_maximize(workspace)
            self.status_bar.set_message(
                String("Grammar install failed (exit ")
                    + String(result.exit_code()) + String(") — see new window"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )

    fn _ensure_lsp_for_extension(mut self, ext: String) -> Int:
        """Spawn (or look up) an LSP manager for files with extension
        ``ext``. Returns the index into ``lsp_managers`` of the manager,
        or ``-1`` for unsupported file types or when no candidate
        binary is installed. Idempotent — re-calling for an already-
        spawned language returns the existing index.

        ``ext`` is matched against the registry's ``file_types``; the
        matching ``LanguageSpec`` then drives binary selection. The
        first candidate in ``spec.candidates`` whose binary exists on
        ``$PATH`` (per ``which()``) wins. Mojo gets special-cased to
        thread ``-I`` include flags through the LSP argv.
        """
        var spec_idx = find_language_for_extension(self.lsp_specs, ext)
        if spec_idx < 0:
            return -1
        var lang = self.lsp_specs[spec_idx].language_id
        for i in range(len(self.lsp_languages)):
            if self.lsp_languages[i] == lang:
                return i
        # Pick the first installed candidate.
        var argv = List[String]()
        var argv_found = False
        var spec = self.lsp_specs[spec_idx]
        for c in range(len(spec.candidates)):
            var cand = spec.candidates[c]
            if len(cand.argv) == 0:
                continue
            if len(which(cand.argv[0]).as_bytes()) > 0:
                for k in range(len(cand.argv)):
                    argv.append(cand.argv[k])
                argv_found = True
                break
        if not argv_found:
            return -1
        var root = String("")
        if self.project:
            root = self.project.value()
        # Mojo wants ``-I <root> -I <root>/src`` injected so the server
        # can resolve project imports. Other languages take their argv
        # straight from the registry.
        if lang == String("mojo"):
            var includes = _mojo_include_dirs(root)
            for i in range(len(includes)):
                argv.append(String("-I"))
                argv.append(includes[i])
        var manager = LspManager()
        manager.start_with(lang, argv, root)
        self.lsp_managers.append(manager^)
        self.lsp_languages.append(lang)
        return len(self.lsp_managers) - 1

    fn _lsp_for_path(self, path: String) -> Int:
        """Index into ``lsp_managers`` of the (already-spawned) server
        handling ``path``, or ``-1`` if none has been spawned for that
        file's extension yet."""
        if len(path.as_bytes()) == 0:
            return -1
        var spec_idx = find_language_for_extension(
            self.lsp_specs, extension_of(path),
        )
        if spec_idx < 0:
            return -1
        var lang = self.lsp_specs[spec_idx].language_id
        for i in range(len(self.lsp_languages)):
            if self.lsp_languages[i] == lang:
                return i
        return -1

    fn _default_window_rect(self, workspace: Rect) -> Rect:
        var w80 = (workspace.width() * 80) // 100
        var h80 = (workspace.height() * 80) // 100
        if w80 < MIN_WIN_W:
            w80 = MIN_WIN_W
        if h80 < MIN_WIN_H:
            h80 = MIN_WIN_H
        if w80 > workspace.width():
            w80 = workspace.width()
        if h80 > workspace.height():
            h80 = workspace.height()
        var slack_x = workspace.width() - w80
        var slack_y = workspace.height() - h80
        var dx = 0
        var dy = 0
        if slack_x > 0:
            dx = self._open_count % (slack_x + 1)
        if slack_y > 0:
            dy = self._open_count % (slack_y + 1)
        var ax = workspace.a.x + dx
        var ay = workspace.a.y + dy
        return Rect(ax, ay, ax + w80, ay + h80)

    fn _frontmost_maximized(self) -> Bool:
        if self.windows.focused < 0 \
                or self.windows.focused >= len(self.windows.windows):
            return False
        return self.windows.windows[self.windows.focused].is_maximized

    fn _open_compare_with_clipboard(mut self, screen: Rect):
        """Open a read-only window with a unified diff of the focused
        editor's selection against the system clipboard. With no selection,
        compare the entire buffer. The "old" side (``-``) is the
        editor/selection, the "new" side (``+``) is the clipboard, so the
        diff reads as "what would change if I pasted the clipboard over
        this region."
        """
        if self.windows.focused < 0 \
                or not self.windows.windows[self.windows.focused].is_editor:
            return
        var idx = self.windows.focused
        var ed_label = self.windows.windows[idx].title
        var a_text: String
        if self.windows.windows[idx].editor.has_selection():
            a_text = self.windows.windows[idx].editor.selection_text()
            ed_label = ed_label + String(" (selection)")
        else:
            a_text = self.windows.windows[idx].editor.text_snapshot()
        var b_text = clipboard_paste()
        var diff_text = unified_diff(
            a_text, b_text, ed_label, String("(clipboard)"),
        )
        var workspace = self.workspace_rect(screen)
        var rect = self._default_window_rect(workspace)
        var was_max = self._frontmost_maximized()
        var title = String("Compare: ") + self.windows.windows[idx].title \
            + String(" vs clipboard")
        self.windows.add(Window.editor_window(title^, rect, diff_text^))
        self._open_count += 1
        var new_idx = len(self.windows.windows) - 1
        self.windows.windows[new_idx].editor.read_only = True
        self.windows.windows[new_idx].editor.line_numbers = False
        # Synthetic ``.diff`` path so the highlighter routes through
        # the bundled diff TextMate grammar. ``check_external_changes``
        # is gated by ``stat_file(...).ok`` and ``save`` by ``read_only``,
        # so the made-up path can't cause file operations.
        self.windows.windows[new_idx].editor.file_path = String("compare.diff")
        if was_max:
            self.windows.windows[new_idx].toggle_maximize(workspace)

    fn process_external_changes(mut self, screen: Rect) raises:
        """Re-stat every editor window and react to any out-of-band
        write. Clean reloads and clean 3-way merges happen silently
        inside the editors themselves; for every window where the
        merge produced conflicts, open a read-only diff window
        showing what changed externally so the user can see it
        alongside the now-marked-up buffer they need to resolve.
        """
        var conflicts = self.windows.check_external_changes()
        if len(conflicts) == 0:
            return
        var workspace = self.workspace_rect(screen)
        var was_max = self._frontmost_maximized()
        for k in range(len(conflicts)):
            var idx = conflicts[k]
            if idx < 0 or idx >= len(self.windows.windows):
                continue
            var diff_opt = \
                self.windows.windows[idx].editor.consume_conflict_diff()
            if not diff_opt:
                continue
            var src_title = self.windows.windows[idx].title
            var rect = self._default_window_rect(workspace)
            var title = String("Conflict: ") + src_title
            self.windows.add(Window.editor_window(
                title^, rect, diff_opt.value(),
            ))
            self._open_count += 1
            var new_idx = len(self.windows.windows) - 1
            self.windows.windows[new_idx].editor.read_only = True
            self.windows.windows[new_idx].editor.line_numbers = False
            # Synthetic .diff path so the diff TextMate grammar paints
            # the +/-/@@ lines. Same trick as _open_compare_with_clipboard.
            self.windows.windows[new_idx].editor.file_path = \
                String("conflict.diff")
            if was_max:
                self.windows.windows[new_idx].toggle_maximize(workspace)

    # --- dynamic Window menu -----------------------------------------------

    fn _rebuild_window_menu(mut self):
        """Replace the Window menu's items with the current window list +
        a separator + Maximize all + Restore all."""
        if self._window_menu_idx < 0:
            return
        var items = List[MenuItem]()
        for i in range(len(self.windows.windows)):
            items.append(MenuItem(
                self.windows.windows[i].title,
                WINDOW_FOCUS_PREFIX + String(i),
            ))
        if len(self.windows.windows) > 0:
            items.append(MenuItem.separator())
        items.append(MenuItem(String("Maximize all"), WINDOW_MAXIMIZE_ALL))
        items.append(MenuItem(String("Restore all"), WINDOW_RESTORE_ALL))
        self.menu_bar.menus[self._window_menu_idx].items = items^

    # --- project state -----------------------------------------------------

    fn detect_project_from(mut self, path: String):
        """Set the project to the ``.git`` ancestor of ``path``, if any.

        No-op if a project is already set — the user closes it explicitly
        before a new one can be auto-detected.
        """
        if self.project:
            return
        var found = find_git_project(path)
        if found:
            self._set_project(found.value())

    fn open_project(mut self, path: String):
        """Pick a project root for ``path``.

        Walks up from ``path`` looking for the nearest ``.git`` ancestor;
        if one is found at any level all the way to ``/``, that ancestor
        becomes the project. Only if no ancestor anywhere on the path
        contains a ``.git`` do we fall back to ``path`` itself. So a
        ``turbokod/app`` arg picks the outer ``turbokod/`` repo (where
        ``.git`` lives) rather than ``app/``, while a non-repo
        directory still gets treated as a project.
        """
        if self.project:
            return
        var found = find_git_project(path)
        if found:
            self._set_project(found.value())
        else:
            self._set_project(path)

    fn close_project(mut self):
        self.project = Optional[String]()
        self.file_tree.close()
        if self._project_menu_idx >= 0:
            self.menu_bar.menus[self._project_menu_idx].visible = False
            if self.menu_bar.open_idx == self._project_menu_idx:
                self.menu_bar.open_idx = -1
            # Reset the tree-toggle label for the next project.
            self.menu_bar.menus[self._project_menu_idx].items[0].label = _SHOW_TREE_LABEL
        # Drop the targets list and stop any in-flight run — the
        # next project's targets get loaded fresh on ``_set_project``.
        self.run_session.terminate()
        self._run_output_held = False
        self.targets = ProjectTargets()
        # Forget the cached session signature so the next project's
        # restore-then-save cycle starts from a clean slate (and so a
        # later switch back to this project can re-read the on-disk
        # file rather than the stale in-memory value).
        self._pending_restore = False
        self._last_session_json = String("")
        self._pending_restore_refit = Optional[Session]()
        # Close any open editor windows last — after self.project has
        # been cleared so _save_session_if_changed bails on its first
        # guard and leaves the on-disk session.json intact. Reopening
        # the project then restores exactly these files.
        self._close_all_editor_windows()

    fn _close_all_editor_windows(mut self):
        """Drop every editor window from the manager, leaving non-editor
        windows (host-added panels / demo content) alone. Rebuilds
        ``z_order`` and ``focused`` against the surviving windows."""
        var kept = List[Window]()
        var remap = List[Int]()
        for i in range(len(self.windows.windows)):
            if self.windows.windows[i].is_editor:
                remap.append(-1)
            else:
                remap.append(len(kept))
                kept.append(self.windows.windows[i])
        self.windows.windows = kept^
        var new_z = List[Int]()
        for k in range(len(self.windows.z_order)):
            var v = self.windows.z_order[k]
            if v >= 0 and v < len(remap) and remap[v] >= 0:
                new_z.append(remap[v])
        self.windows.z_order = new_z^
        if len(self.windows.z_order) > 0:
            self.windows.focused = self.windows.z_order[len(self.windows.z_order) - 1]
        else:
            self.windows.focused = -1
        # Reset the cascade counter so the next project's first opens
        # land at the workspace origin instead of inheriting an offset.
        self._open_count = 0

    fn _set_project(mut self, path: String):
        # Resolve so a label like ``.`` becomes the actual directory name,
        # and so the stored project path is canonical for downstream
        # comparisons. Fall back to the input on resolution failure.
        var resolved = realpath(path)
        var canonical = resolved if len(resolved.as_bytes()) > 0 else path
        self.project = Optional[String](canonical)
        # Record this project at the front of the persistent recents list
        # before any later step might raise — failing to save the config
        # is a non-fatal best-effort, just like the View-menu toggles.
        record_recent_project(self.config, canonical)
        _ = save_config(self.config)
        var label = basename(canonical)
        if self._project_menu_idx < 0:
            var items = List[MenuItem]()
            items.append(MenuItem(_SHOW_TREE_LABEL, PROJECT_TREE_ACTION))
            items.append(MenuItem(
                String("Configure targets..."), PROJECT_CONFIG_TARGETS,
            ))
            items.append(MenuItem.separator())
            items.append(MenuItem(String("Close project"), PROJECT_CLOSE_ACTION))
            self.menu_bar.add(Menu(label, items^, right_aligned=True))
            self._project_menu_idx = len(self.menu_bar.menus) - 1
        else:
            self.menu_bar.menus[self._project_menu_idx].label = label
            self.menu_bar.menus[self._project_menu_idx].visible = True
        # Load the per-project target list now that we know the root.
        # Empty/missing config yields an empty ``targets`` list, which
        # the status bar paints as no tabs at all — Cmd+R / Cmd+D
        # silently no-op until the user authors ``.turbokod/targets.json``.
        self.targets = load_project_targets(canonical)
        # Arm a session restore for the next ``paint`` — that's the
        # earliest place we have ``screen`` to clip restored rects
        # against. The restore code merges by file path (existing
        # editor windows for files in the session get their saved
        # rect; non-matching windows are left alone), so it's safe to
        # arm even when host-added demo or non-editor windows are
        # already on screen — they're not file-backed and so aren't
        # in the session.
        self._pending_restore = True

    # --- session restore / save -------------------------------------------

    fn _snapshot_session(self) -> Session:
        """Build a ``Session`` describing every file-backed editor window
        currently open. Non-editor windows and Untitled buffers (no
        ``file_path``) are skipped — they have nothing meaningful to
        restore from disk later. The returned ``z_order`` and
        ``focused`` index into the *filtered* window list, not into
        ``self.windows.windows``.
        """
        var session = Session()
        # Map from window-list index to session-list index (or -1 when
        # the window was filtered out). Used to translate ``z_order``
        # and ``focused`` into the session's own indexing.
        var win_to_session = List[Int]()
        if not self.project:
            return session^
        var root = self.project.value()
        for i in range(len(self.windows.windows)):
            # Index in directly rather than binding to a local — Window
            # carries the full Editor (buffer, undo stack, highlights),
            # which is dozens of KB; ``var w = self.windows.windows[i]``
            # would make a per-frame copy of all of it.
            if not self.windows.windows[i].is_editor:
                win_to_session.append(-1)
                continue
            var fp = self.windows.windows[i].editor.file_path
            if len(fp.as_bytes()) == 0:
                win_to_session.append(-1)
                continue
            var sw = SessionWindow()
            sw.path = _session_relative(root, fp)
            sw.rect_a_x = self.windows.windows[i].rect.a.x
            sw.rect_a_y = self.windows.windows[i].rect.a.y
            sw.rect_b_x = self.windows.windows[i].rect.b.x
            sw.rect_b_y = self.windows.windows[i].rect.b.y
            sw.is_maximized = self.windows.windows[i].is_maximized
            sw.restore_a_x = self.windows.windows[i]._restore_rect.a.x
            sw.restore_a_y = self.windows.windows[i]._restore_rect.a.y
            sw.restore_b_x = self.windows.windows[i]._restore_rect.b.x
            sw.restore_b_y = self.windows.windows[i]._restore_rect.b.y
            sw.cursor_row = self.windows.windows[i].editor.cursor_row
            sw.cursor_col = self.windows.windows[i].editor.cursor_col
            sw.scroll_x = self.windows.windows[i].editor.scroll_x
            sw.scroll_y = self.windows.windows[i].editor.scroll_y
            session.windows.append(sw^)
            win_to_session.append(len(session.windows) - 1)
        # Translate z-order. Drop windows that filtered out so the
        # session's z_order stays internally consistent.
        for k in range(len(self.windows.z_order)):
            var src = self.windows.z_order[k]
            if 0 <= src and src < len(win_to_session):
                var mapped = win_to_session[src]
                if mapped >= 0:
                    session.z_order.append(mapped)
        # Translate focused. Fall back to the top of the session's
        # z-order when the actual focused window was filtered out.
        var f = self.windows.focused
        if 0 <= f and f < len(win_to_session) and win_to_session[f] >= 0:
            session.focused = win_to_session[f]
        elif len(session.z_order) > 0:
            session.focused = session.z_order[len(session.z_order) - 1]
        else:
            session.focused = -1
        return session^

    fn _save_session_if_changed(mut self):
        """Re-encode the current session and write it to disk only when
        the encoding differs from the previously-written one. Skipped
        when no project is open — nowhere to write. Closing the last
        window writes an empty session so the next ``open_project``
        starts clean rather than restoring a stale window. The
        ``close_project`` flow clears ``self.project`` *before*
        dropping its editor windows, so the project guard here keeps
        the on-disk session intact for restore on reopen."""
        if not self.project:
            return
        var session = self._snapshot_session()
        var encoded = encode_session(session)
        if encoded == self._last_session_json:
            return
        if save_session(self.project.value(), session):
            self._last_session_json = encoded

    fn _restore_session(mut self, screen: Rect):
        """Recreate windows from ``<project>/.turbokod/session.json``.

        Files already open are left in place (so calling this from the
        ``open_file`` flow doesn't duplicate the user's freshly-opened
        window); only previously-saved files that aren't open get
        added. Restored rects are clipped to the current workspace —
        a smaller terminal than last time still produces visible
        windows. Z-order and focus are reapplied at the end so the
        user lands on the same window they left.
        """
        if not self.project:
            return
        var session = load_session(self.project.value())
        if len(session.windows) == 0:
            # Nothing to restore. Leave the cached encoding empty so a
            # later ``_save_session_if_changed`` will write the first
            # real session out fresh.
            self._last_session_json = String("")
            self._pending_restore_refit = Optional[Session]()
            return
        # Stash the loaded session so the next resize event re-applies
        # the saved rects against the now-correct workspace. The host
        # terminal often hands us its default size (80x24) for the
        # first paint and pushes the real dimensions a few ms later;
        # without re-application, rects saved at the larger size would
        # stay clipped to 80x24 forever.
        var session_copy = Session()
        for i in range(len(session.windows)):
            session_copy.windows.append(session.windows[i])
        for i in range(len(session.z_order)):
            session_copy.z_order.append(session.z_order[i])
        session_copy.focused = session.focused
        self._pending_restore_refit = Optional[Session](session_copy^)
        var workspace = self.workspace_rect(screen)
        var root = self.project.value()
        # Track which session entry maps to which final window index
        # so we can reapply z-order and focus afterwards.
        var session_to_window = List[Int]()
        for i in range(len(session.windows)):
            var sw = session.windows[i]
            var resolved = _resolve_session_path(root, sw.path)
            var rect = _clip_rect_to_workspace(
                Rect(sw.rect_a_x, sw.rect_a_y, sw.rect_b_x, sw.rect_b_y),
                workspace,
            )
            var restore = _clip_rect_to_workspace(
                Rect(sw.restore_a_x, sw.restore_a_y,
                     sw.restore_b_x, sw.restore_b_y),
                workspace,
            )
            var existing = self._find_window_for_path(resolved)
            if existing >= 0:
                # The window for this file is already open — likely the
                # user just opened it via ``open_file`` which triggered
                # us. The session's saved rect / cursor / scroll wins
                # over the cascade default the open_file path applied,
                # because the session is the user's last-known intent.
                # Set ``is_maximized`` and ``rect`` directly rather than
                # calling ``toggle_maximize`` — that helper clobbers
                # ``_restore_rect`` with the current rect, which would
                # erase the per-window un-maximized rect we just loaded
                # from disk.
                if sw.is_maximized:
                    self.windows.windows[existing].rect = workspace
                else:
                    self.windows.windows[existing].rect = rect
                self.windows.windows[existing].is_maximized = sw.is_maximized
                self.windows.windows[existing]._restore_rect = restore
                self.windows.windows[existing].editor.cursor_row = sw.cursor_row
                self.windows.windows[existing].editor.anchor_row = sw.cursor_row
                self.windows.windows[existing].editor.cursor_col = sw.cursor_col
                self.windows.windows[existing].editor.anchor_col = sw.cursor_col
                self.windows.windows[existing].editor.scroll_x = sw.scroll_x
                self.windows.windows[existing].editor.scroll_y = sw.scroll_y
                session_to_window.append(existing)
                continue
            try:
                # Construct at the saved ``rect`` (the current/last-known
                # position) and explicitly set ``_restore_rect`` to the
                # saved un-maximized rect. The maximized branch below
                # then overwrites ``rect`` to ``workspace`` if needed.
                # We don't call ``toggle_maximize`` because that would
                # clobber ``_restore_rect`` with the current rect.
                var w = Window.from_file(basename(resolved), rect, resolved)
                w._restore_rect = restore
                # Apply per-buffer view state. Bounds-check the cursor
                # against the restored buffer so a stale row from a
                # file that's since been truncated doesn't put us off
                # the end.
                var line_count = w.editor.buffer.line_count()
                var cr = sw.cursor_row
                if cr < 0:
                    cr = 0
                if line_count > 0 and cr >= line_count:
                    cr = line_count - 1
                w.editor.cursor_row = cr
                w.editor.anchor_row = cr
                w.editor.cursor_col = sw.cursor_col
                w.editor.anchor_col = sw.cursor_col
                w.editor.scroll_x = sw.scroll_x
                w.editor.scroll_y = sw.scroll_y
                self.windows.add(w^)
                var idx = len(self.windows.windows) - 1
                if sw.is_maximized:
                    # Direct field set — see the existing-window branch
                    # for why we don't call toggle_maximize here.
                    self.windows.windows[idx].rect = workspace
                    self.windows.windows[idx].is_maximized = True
                    self.windows.windows[idx]._restore_rect = restore
                self._maybe_lsp_open(idx)
                session_to_window.append(idx)
            except:
                session_to_window.append(-1)
        # Reapply z-order: rebuild from session order, dropping
        # entries we couldn't restore. Anything not in the session
        # (e.g. a window the user opened mid-restore) stays where it
        # naturally ended up — appended at the end.
        var new_z = List[Int]()
        var in_session = List[Bool]()
        for _ in range(len(self.windows.windows)):
            in_session.append(False)
        for k in range(len(session.z_order)):
            var sidx = session.z_order[k]
            if 0 <= sidx and sidx < len(session_to_window):
                var widx = session_to_window[sidx]
                if widx >= 0 and widx < len(in_session) \
                        and not in_session[widx]:
                    new_z.append(widx)
                    in_session[widx] = True
        for i in range(len(self.windows.windows)):
            if not in_session[i]:
                new_z.append(i)
        self.windows.z_order = new_z^
        # Restore focus: the session's focused index, or the top of
        # the rebuilt z-order as fallback.
        var focus_idx = -1
        if 0 <= session.focused and session.focused < len(session_to_window):
            focus_idx = session_to_window[session.focused]
        if focus_idx < 0 and len(self.windows.z_order) > 0:
            focus_idx = self.windows.z_order[len(self.windows.z_order) - 1]
        if focus_idx >= 0:
            self.windows.focused = focus_idx
        # Seed the change-detection cache with the encoding of what we
        # just loaded so the immediate post-restore ``paint`` doesn't
        # re-write the file with the same bytes.
        self._last_session_json = encode_session(self._snapshot_session())

    fn _reapply_session_rects(mut self, screen: Rect):
        """Re-apply saved rects from ``_pending_restore_refit`` to any
        already-open editor windows whose ``file_path`` matches a
        session entry. Used to recover from a startup-time clip when
        the host terminal pushes its real dimensions a few ms after
        the first ``_restore_session``. Only file-path-matched windows
        are touched; new windows that weren't open at restore time and
        windows the user manually moved (refit cleared) stay where they
        are."""
        if not self._pending_restore_refit or not self.project:
            return
        ref session = self._pending_restore_refit.value()
        var workspace = self.workspace_rect(screen)
        var root = self.project.value()
        for i in range(len(session.windows)):
            var sw = session.windows[i]
            var resolved = _resolve_session_path(root, sw.path)
            var existing = self._find_window_for_path(resolved)
            if existing < 0:
                continue
            var rect = _clip_rect_to_workspace(
                Rect(sw.rect_a_x, sw.rect_a_y, sw.rect_b_x, sw.rect_b_y),
                workspace,
            )
            var restore = _clip_rect_to_workspace(
                Rect(sw.restore_a_x, sw.restore_a_y,
                     sw.restore_b_x, sw.restore_b_y),
                workspace,
            )
            if sw.is_maximized:
                self.windows.windows[existing].rect = workspace
            else:
                self.windows.windows[existing].rect = rect
            self.windows.windows[existing].is_maximized = sw.is_maximized
            self.windows.windows[existing]._restore_rect = restore
        # Re-seed the change-detection cache so the post-refit paint
        # doesn't re-write the file with the now-correctly-fit bytes.
        self._last_session_json = encode_session(self._snapshot_session())

    fn _toggle_file_tree(mut self):
        if self._project_menu_idx < 0 or not self.project:
            return
        if self.file_tree.visible:
            self.file_tree.close()
            self.menu_bar.menus[self._project_menu_idx].items[0].label = \
                _SHOW_TREE_LABEL
        else:
            self.file_tree.open(self.project.value())
            self.menu_bar.menus[self._project_menu_idx].items[0].label = \
                _HIDE_TREE_LABEL

    # --- events ------------------------------------------------------------

    fn handle_event(mut self, event: Event, screen: Rect) -> Optional[String]:
        """Single entry point for every event the app receives.

        The Desktop handles the prompt-modal lifecycle, mouse routing, and
        all editor / project actions internally. ESC closes whichever modal
        layer is currently active (prompt → quick open → menu) and is
        otherwise dropped — apps that want a quit binding should register
        one explicitly (the default ``Ctrl+Q`` hotkey already does). Any
        action the Desktop doesn't claim is returned verbatim for the
        caller to dispatch.
        """
        # The first resize after a session restore is typically the
        # host terminal pushing its real dimensions. Re-apply the saved
        # rects against the now-correct workspace so windows that were
        # clipped to the host's 80x24 default at startup land where the
        # user left them. Mouse drags / window dragging clear the refit
        # marker (see drag handling) so this can't trample user moves
        # made between restore and the resize.
        if event.kind == EVENT_RESIZE and self._pending_restore_refit:
            self._reapply_session_rects(screen)
            self._pending_restore_refit = Optional[Session]()
        if self.prompt.active:
            if event.kind == EVENT_KEY:
                _ = self.prompt.handle_key(event)
                if self.prompt.submitted:
                    return self._on_prompt_submit()
            return Optional[String]()
        if self.confirm_dialog.active:
            if event.kind == EVENT_KEY:
                _ = self.confirm_dialog.handle_key(event)
            else:
                _ = self.confirm_dialog.handle_mouse(event, screen)
            if self.confirm_dialog.submitted:
                return self._on_confirm_submit()
            return Optional[String]()
        if self.save_as_dialog.active:
            if event.kind == EVENT_KEY:
                _ = self.save_as_dialog.handle_key(event)
            else:
                _ = self.save_as_dialog.handle_mouse(event, screen)
            if self.save_as_dialog.submitted:
                var path = self.save_as_dialog.selected_path
                self.save_as_dialog.close()
                var idx = self._focused_editor_idx()
                if idx >= 0:
                    try:
                        _ = self.windows.windows[idx].editor.save_as(path)
                    except:
                        pass
            return Optional[String]()
        if self.quick_open.active:
            if event.kind == EVENT_KEY:
                _ = self.quick_open.handle_key(event)
            else:
                _ = self.quick_open.handle_mouse(event, screen)
            if self.quick_open.submitted:
                var path = self.quick_open.selected_path
                var to_project = self.quick_open.picks_project
                self.quick_open.close()
                if to_project:
                    # Project switch: close any current project so
                    # ``open_project``'s "no-op when one is set" guard
                    # doesn't swallow the request, then re-arm.
                    if self.project:
                        self.close_project()
                    self.open_project(path)
                else:
                    try:
                        self.open_file(path, screen)
                    except:
                        pass
            return Optional[String]()
        if self.symbol_pick.active:
            if event.kind == EVENT_KEY:
                _ = self.symbol_pick.handle_key(event)
            else:
                _ = self.symbol_pick.handle_mouse(event, screen)
            if self.symbol_pick.submitted:
                var line = self.symbol_pick.selected_line
                var character = self.symbol_pick.selected_character
                var path = self.symbol_pick.path
                self.symbol_pick.close()
                self._jump_to(
                    DefinitionResolved(path, line, character), screen,
                )
            return Optional[String]()
        if self.doc_pick.active:
            if event.kind == EVENT_KEY:
                _ = self.doc_pick.handle_key(event)
            else:
                _ = self.doc_pick.handle_mouse(event, screen)
            if self.doc_pick.submitted:
                var entry_idx = self.doc_pick.selected_index
                var display = self.doc_pick.display
                self._open_doc_entry(entry_idx, display, screen)
                self.doc_pick.close()
            return Optional[String]()
        if self.project_find.active:
            if event.kind == EVENT_KEY:
                _ = self.project_find.handle_key(event, monotonic_ms())
            else:
                _ = self.project_find.handle_mouse(event, screen)
            if self.project_find.submitted:
                var path = self.project_find.selected_path
                var line_no = self.project_find.selected_line
                self.project_find.close()
                # Open (or focus) the file, then move the cursor to the
                # 1-based line number reported by ``find_in_project``.
                self._jump_to(
                    DefinitionResolved(path, line_no - 1, 0), screen,
                )
            return Optional[String]()
        if self.local_changes.active:
            if event.kind == EVENT_KEY:
                _ = self.local_changes.handle_key(event, screen)
            else:
                _ = self.local_changes.handle_mouse(event, screen)
            if self.local_changes.submitted:
                # ``selected_path`` is project-relative; resolve against
                # the project root before opening so ``open_file`` can
                # find it on disk regardless of the host's cwd.
                var rel = self.local_changes.selected_path
                self.local_changes.close()
                var abs = rel
                if not starts_with(rel, String("/")) and self.project:
                    abs = join_path(self.project.value(), rel)
                try:
                    self.open_file(abs, screen)
                except:
                    pass
            return Optional[String]()
        if self.targets_dialog.active:
            if event.kind == EVENT_KEY:
                _ = self.targets_dialog.handle_key(event)
            else:
                _ = self.targets_dialog.handle_mouse(event, screen)
            if self.targets_dialog.submitted:
                self._on_targets_dialog_submit()
            return Optional[String]()
        if self.settings.active:
            if event.kind == EVENT_KEY:
                _ = self.settings.handle_key(event)
            else:
                _ = self.settings.handle_mouse(event, screen)
            return Optional[String]()
        if event.kind == EVENT_KEY:
            # Side panels absorb arrow / Enter / Esc when focused;
            # if neither claims the key, fall through to the regular
            # dispatch (menu mnemonics, hotkeys, focused window).
            if self.debug_pane.handle_key(event):
                return Optional[String]()
            if self.file_tree.handle_key(event):
                return Optional[String]()
            return self._handle_key(event, screen)
        # Resize drags get first dibs: a click on a pane's resize edge
        # — or motion while a resize is already in flight — must reach
        # that pane before menu / status / overlapping-pane dispatch
        # can steal it. The file tree's left border can sit on top of
        # the debug pane's bottom rows, and the debug pane's top
        # border sits over the workspace where ``windows.handle_mouse``
        # would otherwise grab clicks.
        if event.kind == EVENT_MOUSE:
            var dp_rect = self.debug_pane_rect(screen)
            if self.debug_pane.is_resizing() \
                    or (event.button == MOUSE_BUTTON_LEFT \
                        and event.pressed and not event.motion \
                        and self.debug_pane.is_on_resize_edge(event.pos, dp_rect)):
                if self.debug_pane.handle_mouse(event, dp_rect):
                    return Optional[String]()
            if self.file_tree.is_resizing() \
                    or (event.button == MOUSE_BUTTON_LEFT \
                        and event.pressed and not event.motion \
                        and self.file_tree.is_on_resize_edge(event.pos, screen)):
                if self.file_tree.handle_mouse(event, screen):
                    return Optional[String]()
        # Mouse events (and everything else): route through menu → pane → tree → windows.
        var result = self.menu_bar.handle_event(event, screen.b.x)
        if result.action:
            return self.dispatch_action(result.action.value(), screen)
        if result.consumed:
            return Optional[String]()
        # Status-bar tab strip sits on the bottom row. Check it before
        # the workspace so a click on a tab doesn't also fall through
        # to whatever editor is rendered above it.
        var tab_idx = self.status_bar.handle_mouse(event, screen)
        if tab_idx >= 0:
            return self.dispatch_action(
                TARGET_SELECT_PREFIX + String(tab_idx), screen,
            )
        # Window tab bar (one row above status bar). Same rationale as
        # the status-bar tabs: route the click to the named window
        # before the workspace gets a shot at it.
        var win_tab_rect = self.tab_bar_rect(screen)
        var win_tab = self.tab_bar.handle_mouse(event, win_tab_rect)
        if win_tab >= 0:
            return self.dispatch_action(
                WINDOW_FOCUS_PREFIX + String(win_tab), screen,
            )
        if self.debug_pane.handle_mouse(event, self.debug_pane_rect(screen)):
            return Optional[String]()
        if self.file_tree.handle_mouse(event, screen):
            return Optional[String]()
        _ = self.windows.handle_mouse(event, self.workspace_rect(screen))
        # A click that reaches the window manager could have started a
        # drag/resize — drop the pending refit so the next resize event
        # doesn't trample the user's intended move. (This is coarse:
        # any click within the workspace clears it, even hover. That's
        # fine — the refit is only meaningful in the brief window
        # between restore and the host's first resize push, and clicks
        # in that window are rare.)
        if event.kind == EVENT_MOUSE and self._pending_restore_refit:
            self._pending_restore_refit = Optional[Session]()
        return Optional[String]()

    fn _handle_key(mut self, event: Event, screen: Rect) -> Optional[String]:
        # Capture and reset the one-shot ESC-prefix flag so this keystroke
        # gets at most one chance to act as a mnemonic via that path.
        var was_armed = self._esc_armed
        self._esc_armed = False
        if event.key == KEY_ESC:
            # ESC only closes whatever modal layer is open; it never quits
            # the app on its own. Quit is reserved for explicit bindings
            # like the default Ctrl+Q hotkey. When no modal is up, ESC
            # arms the prefix path so the next keystroke can act as a
            # menu mnemonic — useful on macOS terminals that don't deliver
            # Option+F as ``ESC f`` by default.
            if self.menu_bar.is_open():
                self.menu_bar.close()
            elif self._run_output_held \
                    and not self.dap.is_active() \
                    and not self.run_session.is_active():
                # Dismiss the held run-output pane. The status text
                # advertises this binding so the user knows ESC works
                # here regardless of whether the pane has focus.
                self._run_output_held = False
                self.debug_pane.focused = False
            elif self.windows.focused_is_editor() \
                    and self.windows.windows[self.windows.focused] \
                        .editor.has_extra_carets():
                # Multi-cursor escape hatch: drop back to the primary
                # caret. Same intent as plain mouse click; but reachable
                # without taking your hands off the keyboard.
                self.windows.windows[self.windows.focused] \
                    .editor.clear_extra_carets()
            else:
                self._esc_armed = True
            return Optional[String]()
        # When a menu is open, it captures keyboard focus: arrow keys
        # navigate, Enter activates. Mnemonic switching (Alt+<letter>)
        # still works as a fall-through if the menu doesn't consume.
        if self.menu_bar.is_open():
            var mr = self.menu_bar.handle_key(event)
            if mr.action:
                var action = mr.action.value()
                return self.dispatch_action(action, screen)
            if mr.consumed:
                return Optional[String]()
            if event.mods == MOD_ALT and self._open_menu_by_mnemonic(event.key):
                return Optional[String]()
            # Anything else is swallowed — typing into windows while a menu
            # is open would be surprising.
            return Optional[String]()
        # ESC-prefix menu mnemonic: if the previous keystroke armed us and
        # this one is a letter, treat as Alt+<letter>.
        if was_armed and event.mods == MOD_NONE \
                and self._open_menu_by_mnemonic(event.key):
            return Optional[String]()
        # Hotkey lookup: walk registrations newest-first so user-supplied
        # bindings can override the defaults. Hotkeys take priority over
        # forwarding to the focused window — without that priority, ``Ctrl+F``
        # would land in the editor as an unknown 0x06 character instead of
        # opening the find prompt.
        var i = len(self._hotkeys) - 1
        while i >= 0:
            if self._hotkeys[i].key == event.key \
                    and self._hotkeys[i].mods == event.mods:
                # Copy out before calling dispatch_action — the call may
                # mutate self, which would alias the borrowed string.
                var action = self._hotkeys[i].action
                return self.dispatch_action(action, screen)
            i -= 1
        # Direct Alt+<letter> mnemonic: works on terminals that send
        # Option+F as the literal ``ESC f`` byte pair (Linux defaults,
        # macOS terminals with "Use Option as Meta key" enabled).
        if event.mods == MOD_ALT and self._open_menu_by_mnemonic(event.key):
            return Optional[String]()
        _ = self.windows.handle_key(event)
        return Optional[String]()

    fn _open_menu_by_mnemonic(mut self, key: UInt32) -> Bool:
        var k = Int(key)
        if 0x41 <= k and k <= 0x5A:
            k = k + 0x20
        if not (0x61 <= k and k <= 0x7A):
            return False
        for mi in range(len(self.menu_bar.menus)):
            if not self.menu_bar.menus[mi].visible:
                continue
            var lb = self.menu_bar.menus[mi].label.as_bytes()
            if len(lb) == 0:
                continue
            var first = Int(lb[0])
            if 0x41 <= first and first <= 0x5A:
                first = first + 0x20
            if first == k:
                self.menu_bar.open_menu(mi)
                return True
        return False

    fn register_hotkey(
        mut self, key: UInt32, mods: UInt8, action: String,
    ):
        """Bind ``(key, mods)`` to ``action``.

        User registrations win over the framework's defaults — the lookup
        scans newest-first. Use ``ctrl_key("x")`` to encode a ``Ctrl+letter``
        binding (most terminals deliver those as control characters with
        ``MOD_NONE``).
        """
        self._hotkeys.append(Hotkey(key, mods, action))

    fn dispatch_action(
        mut self, action: String, screen: Rect,
    ) -> Optional[String]:
        """Execute a framework-recognized action; pass anything else back.

        Apps can call this to bind keyboard shortcuts to action strings
        without going through the menu bar. ``screen`` is needed for the
        maximize-related actions; pass the same rect you use for paint.
        """
        if action == PROJECT_CLOSE_ACTION:
            self.close_project()
            return Optional[String]()
        if action == PROJECT_TREE_ACTION:
            self._toggle_file_tree()
            return Optional[String]()
        if action == PROJECT_CONFIG_TARGETS:
            self._open_targets_config()
            return Optional[String]()
        if action == APP_SETTINGS:
            self.settings.open(self.config.on_save_actions.copy())
            return Optional[String]()
        if action == EDITOR_NEW:
            self.new_file(screen)
            return Optional[String]()
        if action == EDITOR_SAVE:
            self._do_save()
            return Optional[String]()
        if action == EDITOR_SAVE_AS:
            self._open_save_as_dialog()
            return Optional[String]()
        if action == EDITOR_QUICK_OPEN:
            # Project-aware: only meaningful when a project is set. Without
            # one, bubble the action up so the host can fall back to its
            # own "Open..." UI (typically a file dialog).
            if self.project:
                self.quick_open.open(self.project.value())
                return Optional[String]()
            return Optional[String](action)
        if action == EDITOR_OPEN_RECENT:
            self._open_recent_picker()
            return Optional[String]()
        if action == PROJECT_OPEN_RECENT:
            self._open_recent_projects_picker()
            return Optional[String]()
        if action == EDITOR_FIND:
            self._pending_action = EDITOR_FIND
            self.prompt.open(String("Find: "))
            return Optional[String]()
        if action == EDITOR_FIND_NEXT:
            # Repeat the previous Find without re-prompting. ``find_next``
            # already wraps to the top when it falls off the end. With no
            # prior search, fall through to the Find prompt so Ctrl+G is
            # still useful on a fresh editor.
            if len(self._last_search.as_bytes()) == 0:
                self._pending_action = EDITOR_FIND
                self.prompt.open(String("Find: "))
                return Optional[String]()
            var idx = self._focused_editor_idx()
            if idx >= 0:
                if self.windows.windows[idx].editor.find_next(self._last_search):
                    self.windows.windows[idx].editor.reveal_cursor(
                        self.windows.windows[idx].interior(),
                        margin_below=10, margin_above=10,
                    )
            return Optional[String]()
        if action == EDITOR_FIND_PREV:
            # Mirror of Find Next, walking backward from the current
            # selection / cursor and wrapping to the file end on miss.
            if len(self._last_search.as_bytes()) == 0:
                self._pending_action = EDITOR_FIND
                self.prompt.open(String("Find: "))
                return Optional[String]()
            var idx = self._focused_editor_idx()
            if idx >= 0:
                if self.windows.windows[idx].editor.find_prev(self._last_search):
                    self.windows.windows[idx].editor.reveal_cursor(
                        self.windows.windows[idx].interior(),
                        margin_below=10, margin_above=10,
                    )
            return Optional[String]()
        if action == EDITOR_REPLACE:
            self._pending_action = _PA_REPLACE_FIND
            self.prompt.open(String("Replace — find: "))
            return Optional[String]()
        if action == EDITOR_GOTO:
            self._pending_action = EDITOR_GOTO
            self.prompt.open(String("Go to line: "))
            return Optional[String]()
        if action == EDITOR_GOTO_SYMBOL:
            self._open_symbol_pick()
            return Optional[String]()
        if action == EDITOR_LOOKUP_DOCS:
            self._open_doc_pick(screen)
            return Optional[String]()
        if action == EDITOR_TOGGLE_COMMENT:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                self.windows.windows[self.windows.focused].editor.toggle_comment()
            return Optional[String]()
        if action == EDITOR_TOGGLE_CASE:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                self.windows.windows[self.windows.focused].editor.toggle_case()
            return Optional[String]()
        if action == EDITOR_TOGGLE_LINE_NUMBERS:
            self.config.line_numbers = not self.config.line_numbers
            self._apply_view_config()
            _ = save_config(self.config)
            return Optional[String]()
        if action == EDITOR_TOGGLE_SOFT_WRAP:
            self.config.soft_wrap = not self.config.soft_wrap
            self._apply_view_config()
            # Soft-wrap changes the relationship between buffer rows
            # and screen rows; re-scroll every editor so its cursor
            # stays visible after the layout change.
            for i in range(len(self.windows.windows)):
                if self.windows.windows[i].is_editor:
                    self.windows.windows[i].editor.reveal_cursor(
                        self.windows.windows[i].interior(),
                    )
            _ = save_config(self.config)
            return Optional[String]()
        if action == EDITOR_TOGGLE_GIT_CHANGES:
            self.config.git_changes = not self.config.git_changes
            # Drop every editor's cached change-line list so that
            # toggling off-then-on always re-queries git instead of
            # showing stale state from before the user's last edits.
            for i in range(len(self.windows.windows)):
                if self.windows.windows[i].is_editor:
                    self.windows.windows[i].editor.invalidate_git_changes()
            self._apply_view_config()
            _ = save_config(self.config)
            return Optional[String]()
        if action == EDITOR_TOGGLE_TAB_BAR:
            self.config.tab_bar = not self.config.tab_bar
            self._apply_view_config()
            _ = save_config(self.config)
            return Optional[String]()
        if action == GIT_LOCAL_CHANGES:
            if self.project:
                self.local_changes.open(self.project.value())
            return Optional[String]()
        if action == EDITOR_TOGGLE_BLAME:
            var idx = self._focused_editor_idx()
            if idx >= 0:
                # Lazy-load: only spawn ``git blame`` the first time
                # the gutter is enabled per editor. Subsequent toggles
                # flip visibility without re-spawning.
                if self.windows.windows[idx].editor.blame_visible:
                    self.windows.windows[idx].editor.blame_visible = False
                else:
                    var path = self.windows.windows[idx].editor.file_path
                    if len(path.as_bytes()) > 0 \
                            and len(self.windows.windows[idx].editor
                                    .blame_lines) == 0:
                        try:
                            var lines = compute_blame(path)
                            self.windows.windows[idx].editor.set_blame(
                                lines^,
                            )
                        except:
                            # Git missing or file not in a repo: leave
                            # the toggle off rather than blowing up.
                            pass
                    else:
                        self.windows.windows[idx].editor.blame_visible = True
            return Optional[String]()
        if action == EDITOR_CUT:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                self.windows.windows[self.windows.focused].editor.cut_to_clipboard()
            return Optional[String]()
        if action == EDITOR_COPY:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                self.windows.windows[self.windows.focused].editor.copy_to_clipboard()
            return Optional[String]()
        if action == EDITOR_PASTE:
            # Paste, undo, and redo can land the cursor anywhere in the
            # buffer — ``reveal_cursor`` brings it back into view since
            # the per-keystroke ``_scroll_to_cursor`` in editor.handle_key
            # is bypassed when the action arrives via a desktop hotkey or
            # menu click.
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                var idx = self.windows.focused
                self.windows.windows[idx].editor.paste_from_clipboard()
                self.windows.windows[idx].editor.reveal_cursor(
                    self.windows.windows[idx].interior(),
                )
            return Optional[String]()
        if action == EDITOR_COMPARE_CLIPBOARD:
            self._open_compare_with_clipboard(screen)
            return Optional[String]()
        if action == EDITOR_UNDO:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                var idx = self.windows.focused
                if self.windows.windows[idx].editor.undo():
                    self.windows.windows[idx].editor.reveal_cursor(
                        self.windows.windows[idx].interior(),
                    )
            return Optional[String]()
        if action == EDITOR_REDO:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                var idx = self.windows.focused
                if self.windows.windows[idx].editor.redo():
                    self.windows.windows[idx].editor.reveal_cursor(
                        self.windows.windows[idx].interior(),
                    )
            return Optional[String]()
        if action == PROJECT_FIND:
            if self.project:
                if len(which(String("rg")).as_bytes()) == 0:
                    self.windows.add(_rg_missing_window())
                else:
                    self.project_find.open(self.project.value())
            return Optional[String]()
        if action == PROJECT_REPLACE:
            if self.project:
                self._pending_action = _PA_PROJECT_REPLACE_FIND
                self.prompt.open(String("Replace in project — find: "))
            return Optional[String]()
        if action == WINDOW_MAXIMIZE_ALL:
            self.windows.maximize_all(self.workspace_rect(screen))
            return Optional[String]()
        if action == WINDOW_RESTORE_ALL:
            self.windows.restore_all()
            return Optional[String]()
        if action == WINDOW_CLOSE:
            _ = self.windows.close_focused()
            return Optional[String]()
        if starts_with(action, WINDOW_FOCUS_PREFIX):
            var idx = parse_int_prefix(action, len(WINDOW_FOCUS_PREFIX.as_bytes()), len(action.as_bytes()))
            self.windows.focus_by_index(idx)
            # Switching to a window means leaving the side panels —
            # otherwise their handle_key keeps swallowing arrows
            # when the user expects them at the editor cursor.
            self.debug_pane.focused = False
            self.file_tree.focused = False
            return Optional[String]()
        if action == WINDOW_ROTATE_NEXT:
            self.windows.rotate_focus(True)
            self.debug_pane.focused = False
            self.file_tree.focused = False
            return Optional[String]()
        if action == WINDOW_ROTATE_PREV:
            self.windows.rotate_focus(False)
            self.debug_pane.focused = False
            self.file_tree.focused = False
            return Optional[String]()
        if action == DEBUG_TOGGLE_BREAKPOINT:
            self._debug_toggle_breakpoint()
            return Optional[String]()
        if action == DEBUG_CONDITIONAL_BP:
            self._debug_open_condition_prompt()
            return Optional[String]()
        if action == DEBUG_START_OR_CONTINUE:
            self._debug_start_or_continue()
            return Optional[String]()
        if action == DEBUG_STEP_OVER:
            _ = self.dap.next()
            return Optional[String]()
        if action == DEBUG_STEP_IN:
            _ = self.dap.step_in()
            return Optional[String]()
        if action == DEBUG_STEP_OUT:
            _ = self.dap.step_out()
            return Optional[String]()
        if action == DEBUG_STOP:
            self.dap.shutdown()
            self._dap_exec_path = String("")
            self._dap_exec_line = -1
            return Optional[String]()
        if action == DEBUG_ADD_WATCH:
            self._pending_action = _PA_ADD_WATCH
            self.prompt.open(String("Watch expression: "))
            return Optional[String]()
        if action == DEBUG_TOGGLE_RAISED:
            self._toggle_raised_exceptions()
            return Optional[String]()
        if action == DEBUG_FOCUS_PANE:
            # Ctrl+9 from anywhere should *focus* the pane, not
            # toggle blindly — toggling-off would land the user
            # nowhere predictable. Force-on, and steal focus from
            # the file tree so only one side panel is keyboard-live
            # at a time.
            self.debug_pane.focused = True
            self.file_tree.focused = False
            return Optional[String]()
        if action == FILE_TREE_FOCUS:
            self.file_tree.focused = True
            self.debug_pane.focused = False
            return Optional[String]()
        if action == TARGET_RUN:
            self._target_run()
            return Optional[String]()
        if action == TARGET_DEBUG:
            self._target_debug()
            return Optional[String]()
        if action == TARGET_TEST:
            self._target_test()
            return Optional[String]()
        if starts_with(action, TARGET_SELECT_PREFIX):
            var idx = parse_int_prefix(
                action, len(TARGET_SELECT_PREFIX.as_bytes()),
                len(action.as_bytes()),
            )
            if idx >= 0 and self.targets.set_active_index(idx):
                if self.project:
                    _ = save_project_targets(self.project.value(), self.targets)
            return Optional[String]()
        return Optional[String](action)

    # --- LSP tick ---------------------------------------------------------

    fn lsp_tick(mut self, screen: Rect):
        """Drain editor → LSP → editor for the focused frame.

        Step 1: if the focused editor has a pending Cmd+click definition
                request, forward it to the LSP server matching that
                file's language (with the latest buffer text so the
                server's view is up to date).
        Step 2: tick every spawned server so responses keep flowing,
                and jump on any that comes back with a concrete location.
        Step 3: refresh the right-aligned LSP indicator on the status bar.
        """
        var idx = self._focused_editor_idx()
        if idx >= 0:
            var req_opt = self.windows.windows[idx].editor.consume_definition_request()
            if req_opt:
                self._dispatch_definition_request(idx, req_opt.value())
        # Drain every spawned manager every frame so responses on any
        # language server make progress regardless of which file is
        # focused.
        for i in range(len(self.lsp_managers)):
            var resolved = self.lsp_managers[i].tick()
            if resolved:
                self._jump_to(resolved.value(), screen)
            else:
                # Empty response just landed: no source location, but
                # we may still have offline docs for this symbol — try
                # the docs fallback before letting the status bar
                # settle on "no definition found". Stdlib symbols (the
                # common case for this fallback) live in DevDocs even
                # when the LSP can't see source for them.
                var unresolved = self.lsp_managers[i].take_empty_word()
                if len(unresolved.as_bytes()) > 0:
                    var lang = self.lsp_languages[i]
                    if self._try_docs_fallback(lang, unresolved, screen):
                        # Clear the latched flag so ``_refresh_lsp_status``
                        # doesn't overwrite our "opened docs" message
                        # with the stale "no definition found" one on
                        # the next tick.
                        self.lsp_managers[i].clear_empty()
            if self.symbol_pick.active and self.symbol_pick.loading \
                    and self.lsp_managers[i].has_pending_symbols():
                self.symbol_pick.set_entries(
                    self.lsp_managers[i].take_symbols(),
                )
        # Drive the background LSP-install runner from the same per-frame
        # tick. When the install completes we either flash a status-bar
        # success or open the captured output as a new editor window.
        var maybe_install = self.install_runner.tick()
        if maybe_install:
            self._on_install_complete(maybe_install.value(), screen)
        self._refresh_lsp_status()

    fn _on_install_complete(
        mut self, result: InstallResult, screen: Rect,
    ):
        """React to an install run finishing. Success: flash the status
        bar and re-attempt LSP startup for any open editors of that
        language so the user gets autocomplete without having to close
        and re-open the file. Failure: pop the captured output into a
        new editor window so the user can read what went wrong.

        Docs installs share the same ``InstallRunner`` slot but go
        through a separate completion path — the dispatch is by
        whichever ``_*_install_lang`` field was set when the install
        started (mutually exclusive: only one runner is active at a
        time, and only one of these fields is non-empty)."""
        if len(self._doc_install_lang.as_bytes()) > 0:
            self._on_doc_install_complete(result, screen)
            return
        if len(self._grammar_install_lang.as_bytes()) > 0:
            self._on_grammar_install_complete(result, screen)
            return
        var lang = self._install_lang
        self._install_lang = String("")
        if result.ok():
            self.status_bar.set_message(
                String("Installed ") + result.label,
                Attr(BLACK, LIGHT_GRAY),
            )
            self._retry_lsp_for_language(lang)
        else:
            var title = String("Install failed: ") + result.label \
                + String(" (exit ") + String(result.exit_code()) + String(")")
            var workspace = self.workspace_rect(screen)
            var rect = self._default_window_rect(workspace)
            var was_max = self._frontmost_maximized()
            var body = String("$ ") + result.command + String("\n\n") \
                + result.output
            self.windows.add(Window.editor_window(title^, rect, body^))
            self._open_count += 1
            if was_max:
                var idx = len(self.windows.windows) - 1
                self.windows.windows[idx].toggle_maximize(workspace)
            self.status_bar.set_message(
                String("Install failed (exit ")
                    + String(result.exit_code()) + String(") — see new window"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )

    fn _retry_lsp_for_language(mut self, lang: String):
        """After a successful install, re-attempt LSP startup for any
        editors whose language matches ``lang``. Cheap: ``open_file`` and
        ``_maybe_lsp_open`` both go through ``_ensure_lsp_for_extension``
        and stay no-ops if the binary is still missing.
        """
        for i in range(len(self.windows.windows)):
            if not self.windows.windows[i].is_editor:
                continue
            var path = self.windows.windows[i].editor.file_path
            if len(path.as_bytes()) == 0:
                continue
            var ext = extension_of(path)
            var spec_idx = find_language_for_extension(self.lsp_specs, ext)
            if spec_idx < 0:
                continue
            if self.lsp_specs[spec_idx].language_id != lang:
                continue
            self._maybe_lsp_open(i)

    fn _dispatch_definition_request(
        mut self, win_idx: Int, var req: DefinitionRequest,
    ):
        """Forward a Cmd+click definition request to the right server,
        with status-bar messaging for the common failure modes."""
        var path = self.windows.windows[win_idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("LSP: file has no path"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var lsp_idx = self._lsp_for_path(path)
        if lsp_idx < 0:
            self.status_bar.set_message(
                String("LSP: not started for this file type"),
                Attr(RED, LIGHT_GRAY),
            )
            return
        if self.lsp_managers[lsp_idx].is_failed():
            return
        if not self.lsp_managers[lsp_idx].is_active():
            self.status_bar.set_message(
                String("LSP: not started for this file type"),
                Attr(RED, LIGHT_GRAY),
            )
            return
        var text = self.windows.windows[win_idx].editor.text_snapshot()
        # Read primitive fields first; ``word`` is moved last so it's
        # the only ownership transfer out of ``req``. Reseat afterwards
        # so Mojo's auto-destructor sees a valid String.
        var row = req.row
        var col = req.col
        var word = req.word^
        req.word = String("")
        var ok = self.lsp_managers[lsp_idx].request_definition(
            path, row, col, word^, text^,
        )
        if not ok:
            self.status_bar.set_message(
                String("LSP: still starting up — try again"),
                Attr(BLACK, LIGHT_GRAY),
            )

    fn _refresh_lsp_status(mut self):
        """Show the focused editor's language-server state on the right
        side of the status bar. The prefix carries the language id so
        the user can tell whether a slow response is from mojo-lsp or
        pyright; flipping focus between a ``.mojo`` and a ``.py`` window
        flips the indicator. Files with no associated server (or no
        server installed) leave the existing message alone.
        """
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var path = self.windows.windows[idx].editor.file_path
        var lsp_idx = self._lsp_for_path(path)
        if lsp_idx < 0:
            return
        var prefix = String("LSP[") + self.lsp_languages[lsp_idx] \
            + String("]: ")
        _refresh_status_for(
            self.status_bar, prefix, self.lsp_managers[lsp_idx],
        )

    # --- DAP wiring ------------------------------------------------------

    fn dap_tick(mut self, screen: Rect):
        """Drive the DAP session forward and reflect its state in the UI.

        Called once per frame by the host (just like ``lsp_tick``).
        Steps:

        1. ``self.dap.tick()`` drains incoming messages, advancing the
           handshake and parking events.
        2. On a fresh ``stopped`` event, request a single-frame stack
           trace so we can paint the ``▶`` arrow on the right line.
        3. When the trace lands, latch ``_dap_exec_*`` and auto-jump the
           workspace to that location (opening the file if needed).
        4. ``terminated`` clears the latched arrow and the breakpoint
           gutter so the editor returns to a quiescent state.
        5. Push the per-file breakpoint slice + exec arrow onto every
           editor window's gutter fields, sized to 2 columns when
           anything debugger-related applies to that file.
        6. Refresh the right-aligned status indicator.
        """
        self.dap.tick()
        var stopped = self.dap.take_stopped()
        if stopped:
            # Fetch a deeper trace so the pane can show context, not
            # just the top frame. 64 frames is plenty for typical
            # stacks and trivial in payload size.
            _ = self.dap.request_stack_trace(stopped.value().thread_id, 64)
        # Frame click from the pane: re-fetch scopes for the chosen frame.
        var fclick = self.debug_pane.consume_frame_click()
        if fclick[0] != -1:
            self._dap_current_frame_id = fclick[0]
            self._dap_var_target_kind = UInt8(0)
            _ = self.dap.request_scopes(fclick[0])
            self._refresh_watches()
        # Variable expand click: request children for the row's ref.
        var eclick = self.debug_pane.consume_expand()
        if eclick[0] != -1:
            self._dap_var_target_kind = UInt8(1)
            self._dap_var_target_row = eclick[1]
            self._dap_var_target_depth = eclick[2]
            _ = self.dap.request_variables(eclick[0])
        # Collapse click: purely local, no DAP traffic.
        var cclick = self.debug_pane.consume_collapse()
        if cclick != -1:
            self.debug_pane.collapse_at(cclick)
        # Output-log link click: ``File "<path>", line N`` parsed out of
        # a stdout/stderr line and clicked. Open (or focus) the file
        # and jump to the line. Failures are swallowed — opening can
        # raise on a missing file, and stack traces from a previous
        # run can easily reference paths that have since moved.
        var oreq = self.debug_pane.consume_open_request()
        if len(oreq[0].as_bytes()) > 0:
            try:
                self.open_file_at(oreq[0], oreq[1] - 1, 0, screen)
            except:
                pass
        if self.dap.has_stack():
            var frames = self.dap.take_stack()
            if len(frames) > 0:
                self._dap_exec_path = frames[0].path
                self._dap_exec_line = frames[0].line
                self._dap_current_frame_id = frames[0].id
                if len(frames[0].path.as_bytes()) > 0:
                    self._jump_to(
                        DefinitionResolved(
                            frames[0].path, frames[0].line, 0,
                        ),
                        screen,
                    )
                # Cache the stack so subsequent variable arrivals can
                # rebuild the pane's inspect rows around the same frames.
                self._dap_stack_cache = frames.copy()
                # Kick off the chain: scopes → variables → pane fill.
                var top_id = frames[0].id
                self._dap_var_target_kind = UInt8(0)
                _ = self.dap.request_scopes(top_id)
                # Initial pane render: stack + empty locals + watches
                # (so the user sees the stack while variables fetch).
                self._rebuild_pane_inspect(List[DapVariable]())
                # Re-evaluate watch expressions on the new frame.
                self._refresh_watches()
        if self.dap.has_scopes():
            var scopes = self.dap.take_scopes()
            var pick = -1
            for i in range(len(scopes)):
                if not scopes[i].expensive:
                    pick = i
                    break
            if pick < 0 and len(scopes) > 0:
                pick = 0
            if pick >= 0:
                _ = self.dap.request_variables(
                    scopes[pick].variables_reference,
                )
                self._dap_pending_scope_label = scopes[pick].name
        if self.dap.has_variables():
            var vars = self.dap.take_variables()
            if self._dap_var_target_kind == UInt8(1):
                # Expand path: splice children after the parent row.
                self.debug_pane.splice_children_at(
                    self._dap_var_target_row,
                    self._dap_var_target_depth,
                    vars^,
                )
                self._dap_var_target_kind = UInt8(0)
                self._dap_var_target_row = -1
            else:
                # Initial scope load: rebuild the inspect rows around
                # the current stack + new locals.
                self._rebuild_pane_inspect(vars^)
        # Drain evaluate responses (watches). May arrive in batches.
        if self.dap.has_evaluations():
            self._fold_watch_results()
        # Output events get appended to the pane log.
        var outs = self.dap.take_outputs()
        for k in range(len(outs)):
            var cat = _category_to_pane(outs[k].category)
            self.debug_pane.append_output(outs[k].text, cat)
        # Adapter stderr — separate channel from DAP ``output`` events.
        # debugpy / lldb-dap log import failures and crash tracebacks
        # here. Without surfacing this, a crashed adapter looks
        # identical to a slow one — state stays INITIALIZING forever
        # because no response ever lands.
        var err = self.dap.drain_stderr()
        if len(err.as_bytes()) > 0:
            self.debug_pane.append_output(err, UInt8(1))  # PANE_OUT_STDERR
        if self.dap.consume_terminated():
            self._dap_exec_path = String("")
            self._dap_exec_line = -1
            self._dap_current_frame_id = -1
            self._dap_stack_cache = List[DapStackFrame]()
            self.debug_pane.clear()
        # Drain gutter clicks (one per editor) before recomputing
        # ``gutter_width`` below — so a click that creates the very first
        # breakpoint also makes the gutter appear on this same frame.
        for i in range(len(self.windows.windows)):
            if not self.windows.windows[i].is_editor:
                continue
            var bp_row = self.windows.windows[i].editor.consume_breakpoint_toggle()
            if not bp_row:
                continue
            var bp_path = self.windows.windows[i].editor.file_path
            if len(bp_path.as_bytes()) == 0:
                self.status_bar.set_message(
                    String("debug: file has no path — save it first"),
                    Attr(LIGHT_RED, LIGHT_GRAY),
                )
                continue
            self.dap.toggle_breakpoint(bp_path, bp_row.value())
        # Push gutter state to every editor window. We do this every
        # frame (cheap — small lists, simple equality checks) so the
        # gutter stays in sync after window churn (open / close / focus).
        for i in range(len(self.windows.windows)):
            if not self.windows.windows[i].is_editor:
                continue
            var path = self.windows.windows[i].editor.file_path
            if len(path.as_bytes()) == 0:
                self.windows.windows[i].editor.gutter_width = 0
                self.windows.windows[i].editor.exec_line = -1
                continue
            var bps = self.dap.breakpoints_for(path)
            var has_session = self.dap.is_active()
            var has_bps = len(bps) > 0
            if has_session or has_bps:
                self.windows.windows[i].editor.gutter_width = 2
            else:
                self.windows.windows[i].editor.gutter_width = 0
            self.windows.windows[i].editor.breakpoint_lines = bps^
            if _same_file(path, self._dap_exec_path):
                self.windows.windows[i].editor.exec_line = \
                    self._dap_exec_line
            else:
                self.windows.windows[i].editor.exec_line = -1
        # Drive the run-target session forward. Sits inside dap_tick
        # rather than its own host call because there's exactly one
        # per-frame integration point and adding a second one would
        # force every example to remember to call it.
        self.target_tick()
        # Pane visibility + status. Pane is shown the entire time the
        # session is alive (initialize → terminated) so the user sees
        # the spawn happen in real time. ``set_status`` mirrors the
        # right-aligned status-bar indicator so the same words are
        # always visible whether the user is looking up or down.
        # Keep the pane open while a run-session is active too — its
        # output is the only place the user sees stdout/stderr.
        # Once a run finishes, ``_run_output_held`` keeps the pane
        # open so the user can read the output instead of having
        # it disappear with the exit.
        self.debug_pane.visible = self.dap.is_active() \
            or self.run_session.is_active() \
            or self._run_output_held
        # Mode drives the pane's title ("Run"/"Debug") and whether
        # Stack/Locals/Watches show at all. DAP is the only state
        # that produces meaningful inspect content; Run sessions
        # (and the post-run "exited" hold) are output-only by
        # nature, so the inspect column would always be empty in
        # those modes — we collapse it and give Output the full pane.
        if self.dap.is_active():
            self.debug_pane.set_mode(PANE_MODE_DEBUG)
            self.debug_pane.set_status(self.dap.status_summary())
        elif self.run_session.is_active():
            self.debug_pane.set_mode(PANE_MODE_RUN)
            self.debug_pane.set_status(
                String("running ") + self.run_session.target_name,
            )
        elif self._run_output_held:
            self.debug_pane.set_mode(PANE_MODE_RUN)
            self.debug_pane.set_status(String("(exited — Esc to dismiss)"))
        elif self.dap.is_failed():
            # Surface the failure once even though we hide the pane —
            # status-bar message is more discoverable than nothing.
            pass
        self._refresh_dap_status()
        # End-of-tick marker — only emitted when the session is
        # actively running so we don't flood the log with one line per
        # 50 ms during idle. A missing marker right after a request
        # narrows a crash to the post-tick paint / next_event path.
        if self.dap.is_running() or self.dap.is_stopped():
            self.dap.client.process.trace(String("dap_tick done"))

    fn _rebuild_pane_inspect(mut self, var locals: List[DapVariable]):
        """Rebuild the inspect rows from the cached stack + given locals
        + cached watch results. Called whenever any one of those three
        inputs changes; the others are pulled from cached state so the
        pane stays consistent."""
        var watch_lines = List[String]()
        for k in range(len(self._dap_watch_exprs)):
            var v = String("")
            if k < len(self._dap_watch_values):
                v = self._dap_watch_values[k]
            watch_lines.append(
                self._dap_watch_exprs[k] + String(" = ") + v,
            )
        var stack_copy = self._dap_stack_cache.copy()
        self.debug_pane.rebuild_inspect(
            stack_copy^,
            String("Locals"),
            locals^,
            String("Watches"),
            watch_lines^,
            0,  # current frame index — top of stack on initial render
        )

    fn _refresh_watches(mut self):
        """Fire ``evaluate`` for every watch expression against the
        current frame. Results land asynchronously and are folded back
        in via ``_fold_watch_results``."""
        if not self.dap.is_stopped():
            return
        for k in range(len(self._dap_watch_exprs)):
            _ = self.dap.request_evaluate(
                self._dap_watch_exprs[k],
                self._dap_current_frame_id,
                String("watch"),
            )

    fn _fold_watch_results(mut self):
        """Drain DAP evaluate responses, splice them into the parallel
        ``_dap_watch_values`` list, and rebuild the pane so the new
        values show up. Watch results identify themselves by the
        original expression string — we don't keep an explicit seq map
        on the Desktop side because the DAP layer already does that."""
        var batch = self.dap.take_evaluations()
        # ``types`` is returned but the pane currently shows just value.
        for i in range(len(batch.expressions)):
            var e = batch.expressions[i]
            for k in range(len(self._dap_watch_exprs)):
                if self._dap_watch_exprs[k] == e:
                    if k < len(self._dap_watch_values):
                        self._dap_watch_values[k] = batch.values[i]
                    else:
                        self._dap_watch_values.append(batch.values[i])
                    break
        # Pane rebuild needs current locals — we don't have them cached
        # so reuse the existing pane row set by extracting locals from
        # it. Simpler: only rebuild watches' display, which is part of
        # the inspect rows. The cleanest path is to ask for a fresh
        # variables dump on the current frame; cheap because the
        # adapter usually serves these from cache. Skipping that here:
        # when the pane is next rebuilt (next stop, next frame click),
        # the new watch values will be picked up.
        # We can also force an immediate refresh by reusing the last
        # stack with empty locals — but that flickers. The compromise
        # below: just rebuild rows with watch-only update by writing
        # straight into the row text for ``PANE_ROW_WATCH`` rows.
        self._patch_pane_watches()

    fn _patch_pane_watches(mut self):
        """In-place update of the watch rows' text in the pane.
        Avoids a full rebuild (which would collapse any expanded
        variable rows). Called after watch values change."""
        var k = 0
        var i = 0
        while i < len(self.debug_pane.rows) \
                and k < len(self._dap_watch_exprs):
            if self.debug_pane.rows[i].kind == PANE_ROW_WATCH:
                var v = String("")
                if k < len(self._dap_watch_values):
                    v = self._dap_watch_values[k]
                var row = self.debug_pane.rows[i]
                row.text = self._dap_watch_exprs[k] + String(" = ") + v
                self.debug_pane.rows[i] = row
                k += 1
            i += 1

    fn add_watch(mut self, var expression: String):
        """Add a watch expression. Evaluates immediately if the session
        is stopped. Can be called from menu actions / hotkey handlers."""
        self._dap_watch_exprs.append(expression^)
        self._dap_watch_values.append(String("(pending)"))
        if self.dap.is_stopped():
            _ = self.dap.request_evaluate(
                self._dap_watch_exprs[len(self._dap_watch_exprs) - 1],
                self._dap_current_frame_id,
                String("watch"),
            )
        # Force a rebuild so the new watch row appears immediately.
        self._rebuild_pane_inspect(List[DapVariable]())
        self._refresh_watches()

    fn remove_watch(mut self, expression: String):
        var new_exprs = List[String]()
        var new_values = List[String]()
        for k in range(len(self._dap_watch_exprs)):
            if self._dap_watch_exprs[k] == expression:
                continue
            new_exprs.append(self._dap_watch_exprs[k])
            if k < len(self._dap_watch_values):
                new_values.append(self._dap_watch_values[k])
        self._dap_watch_exprs = new_exprs^
        self._dap_watch_values = new_values^

    fn _refresh_dap_status(mut self):
        """When a debug session is active, surface its state on the right
        side of the status bar (sharing space with the LSP indicator —
        whichever was set most recently wins, which is fine since both
        are ambient state and they never matter at exactly the same
        instant)."""
        if self.dap.is_active() or self.dap.is_failed():
            var attr = Attr(BLACK, LIGHT_GRAY)
            if self.dap.is_failed():
                attr = Attr(LIGHT_RED, LIGHT_GRAY)
            elif self.dap.is_stopped():
                attr = Attr(BLACK, LIGHT_GRAY)
            self.status_bar.set_message(self.dap.status_summary(), attr)

    fn _debug_open_condition_prompt(mut self):
        """Shift+F9: prompt for a breakpoint condition on the focused
        editor's cursor row. Pre-fills with any existing condition so
        users can edit rather than re-type. Path + line are stashed in
        ``_pending_arg`` as ``path|line`` so the submit handler can
        recover them."""
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("debug: file has no path — save it first"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var line = self.windows.windows[idx].editor.cursor_row
        self._pending_arg = path + String("|") + String(line)
        self._pending_action = _PA_BP_CONDITION
        var existing = self.dap.breakpoint_condition(path, line)
        var label = String("Break when (line ") + String(line + 1) + String("): ")
        self.prompt.open(label, existing)

    fn _toggle_raised_exceptions(mut self):
        """Add or remove the ``raised`` exception filter. The
        ``uncaught`` filter is left as-is — that's the always-on
        default, while ``raised`` is the noisier opt-in."""
        var current = self.dap.exception_filters()
        var has_raised = False
        for k in range(len(current)):
            if current[k] == String("raised"):
                has_raised = True
                break
        var new_filters = List[String]()
        for k in range(len(current)):
            if current[k] != String("raised"):
                new_filters.append(current[k])
        if not has_raised:
            new_filters.append(String("raised"))
        self.dap.set_exception_filters(new_filters^)

    fn _debug_toggle_breakpoint(mut self):
        """F9: toggle a breakpoint at the focused editor's cursor row.

        Local list mutates immediately; the manager will resend the
        ``setBreakpoints`` payload to the adapter on the next eligible
        state. No-op when nothing is focused / the focused window isn't
        an editor with a backing file.
        """
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("debug: file has no path — save it first"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var line = self.windows.windows[idx].editor.cursor_row
        self.dap.toggle_breakpoint(path, line)

    fn _debug_start_or_continue(mut self):
        """F5: start a session if none is active, otherwise resume.

        Picks the debugger spec from the focused editor's file
        extension → language id → registry. If no debugger is registered
        for that language (or the binary isn't on $PATH), surfaces a
        descriptive status message rather than failing silently.
        """
        if self.dap.is_running():
            return  # already running, nothing to do
        if self.dap.is_stopped():
            _ = self.dap.cont()
            return
        if self.dap.is_active():
            return  # mid-handshake, ignore
        # Fresh start. Need: program path + language → spec.
        var idx = self._focused_editor_idx()
        if idx < 0:
            self.status_bar.set_message(
                String("debug: focus a source file first"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("debug: save the file first"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        var ext = extension_of(path)
        var lang_idx = find_language_for_extension(self.lsp_specs, ext)
        if lang_idx < 0:
            self.status_bar.set_message(
                String("debug: unknown language for ") + ext,
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var lang_id = self.lsp_specs[lang_idx].language_id
        var deb_idx = find_debugger_for_language(self.dap_specs, lang_id)
        if deb_idx < 0:
            self.status_bar.set_message(
                String("debug: no adapter registered for ")
                + lang_id,
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        # If the manager is already TERMINATED / FAILED from a prior
        # session, return it to NOT_STARTED so ``start`` will run.
        # ``reset_for_restart`` is preferred over replacing ``self.dap``
        # because it preserves the user's breakpoints + exception
        # filter selection — wholesale replacement would silently drop
        # both, so the second F5 would launch with no breakpoints set
        # and the program would run straight through.
        if self.dap.is_failed() or self.dap.is_terminated():
            self.dap.reset_for_restart()
        var cwd = self.project.value() if self.project else String(".")
        self.dap.start(
            self.dap_specs[deb_idx], path, cwd, List[String](),
        )
        # Surface the resolved spawn line to the pane log immediately.
        # Pre-stderr-drain debugging this was guesswork ("did it pick
        # debugpy-adapter or python -m debugpy.adapter?"); a single
        # console-category line removes the ambiguity. Also visible
        # before the first event arrives, which matters when the
        # adapter crashes silently.
        if len(self.dap.spawn_argv) > 0:
            var line = String("$ ")
            for k in range(len(self.dap.spawn_argv)):
                if k > 0:
                    line = line + String(" ")
                line = line + self.dap.spawn_argv[k]
            self.debug_pane.append_output(line, UInt8(2))   # PANE_OUT_CONSOLE
            self.debug_pane.visible = True

    # --- target run / debug ----------------------------------------------

    fn _open_targets_config(mut self):
        """Open the structured targets-configuration dialog.

        Editing happens against a private copy inside ``TargetsDialog``;
        the host's ``self.targets`` is only updated on Save (handled
        in ``handle_event``'s modal-dispatch path).
        """
        if not self.project:
            self.status_bar.set_message(
                String("Configure targets: open a project first"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        # Make a copy so the dialog's snapshot can't alias our state
        # before the user saves. ``ProjectTargets`` opts out of
        # ImplicitlyCopyable (it carries a single mutable ``active``
        # index meant to live in one place at a time), so the copy
        # is explicit.
        var snapshot = ProjectTargets()
        snapshot.targets = self.targets.targets.copy()
        snapshot.active = self.targets.active
        self.targets_dialog.open(snapshot^)

    fn _on_targets_dialog_submit(mut self):
        """Copy the dialog's edited list back into the host and
        persist it. Called from the modal-dispatch loop when the
        user clicks Save / hits Enter on the Save button."""
        if not self.project:
            self.targets_dialog.close()
            return
        self.targets = self.targets_dialog.into_targets()
        _ = write_all_targets(self.project.value(), self.targets)
        self.targets_dialog.close()

    fn _target_run(mut self):
        """Cmd+R: spawn the active target's ``run_command``.

        If a debug session is running for the same target, terminate
        it first; if a run is already in flight (same or different
        target), terminate that too. The user's mental model is "this
        tab now means a run" — leaving the previous shape alive would
        make Cmd+R + Cmd+D + Cmd+R produce two children for one tab.
        """
        if not self.targets.has_active():
            self.status_bar.set_message(
                String("run: no targets defined — author .turbokod/targets.json"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        if not self.project:
            self.status_bar.set_message(
                String("run: open a project first"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        var target = self.targets.targets[self.targets.active]
        if len(target.program.as_bytes()) == 0:
            self.status_bar.set_message(
                String("run: target '") + target.name
                    + String("' has no program"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        # Stop any debug session — running and debugging the same
        # target are mutually exclusive by design (cmd+r kills debug,
        # cmd+d kills run).
        if self.dap.is_active():
            self.dap.shutdown()
            self._dap_exec_path = String("")
            self._dap_exec_line = -1
        # Stop any prior run, regardless of which target it was for.
        self.run_session.terminate()
        self._run_output_held = False
        self.debug_pane.clear()
        self.debug_pane.visible = True
        var cwd = resolved_cwd(self.project.value(), target.cwd)
        # Swap a bare ``python`` / ``python3`` for the project venv's
        # interpreter when one exists — anything else (or any path
        # the user spelled out) is passed straight through.
        var program_seed = resolve_python_interpreter(
            self.project.value(), target.program,
        )
        var program = resolved_program(
            self.project.value(), target.cwd, program_seed,
        )
        # Build a pretty argv line for the pane log so the user sees
        # exactly what got spawned (resolved paths, not the source
        # config strings).
        var pretty = program
        for k in range(len(target.args)):
            pretty = pretty + String(" ") + target.args[k]
        self.debug_pane.append_output(
            String("$ ") + pretty, UInt8(2),  # PANE_OUT_CONSOLE
        )
        var args = target.args.copy()
        try:
            self.run_session.start(
                String(target.name), program, args^, cwd,
            )
            self.status_bar.set_message(
                String("running ") + target.name + String("…"),
                Attr(BLACK, LIGHT_GRAY),
            )
        except e:
            self.status_bar.set_message(
                String("run: spawn failed — ") + String(e),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )

    fn _target_debug(mut self):
        """Cmd+D: launch the active target under the DAP adapter for
        its ``debug_language``.

        Stops any in-flight run for the same tab first (same reason
        Cmd+R stops debug). Reuses the existing DAP plumbing — just
        a different program / args / cwd seed.
        """
        if not self.targets.has_active():
            self.status_bar.set_message(
                String("debug: no targets defined — author .turbokod/targets.json"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        if not self.project:
            self.status_bar.set_message(
                String("debug: open a project first"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        var target = self.targets.targets[self.targets.active]
        if len(target.debug_language.as_bytes()) == 0:
            self.status_bar.set_message(
                String("debug: target '") + target.name
                    + String("' has no debug language set"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        if len(target.program.as_bytes()) == 0:
            self.status_bar.set_message(
                String("debug: target '") + target.name
                    + String("' has no program"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var deb_idx = find_debugger_for_language(
            self.dap_specs, target.debug_language,
        )
        if deb_idx < 0:
            self.status_bar.set_message(
                String("debug: no adapter for language '")
                    + target.debug_language + String("'"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        # Stop any in-flight run for this target — the user just
        # asked for a debug session of the same thing.
        self.run_session.terminate()
        self._run_output_held = False
        # Tear down any prior debug session before starting a new one.
        if self.dap.is_active():
            self.dap.shutdown()
        if self.dap.is_failed() or self.dap.is_terminated():
            self.dap.reset_for_restart()
        var cwd = resolved_cwd(self.project.value(), target.cwd)
        var program_seed = resolve_python_interpreter(
            self.project.value(), target.program,
        )
        var program = resolved_program(
            self.project.value(), target.cwd, program_seed,
        )
        var args = target.args.copy()
        self.dap.start(self.dap_specs[deb_idx], program, cwd, args^)
        self.debug_pane.clear()
        if len(self.dap.spawn_argv) > 0:
            var line = String("$ ")
            for k in range(len(self.dap.spawn_argv)):
                if k > 0:
                    line = line + String(" ")
                line = line + self.dap.spawn_argv[k]
            self.debug_pane.append_output(line, UInt8(2))  # PANE_OUT_CONSOLE
        self.debug_pane.visible = True
        self.status_bar.set_message(
            String("debugging ") + target.name + String("…"),
            Attr(BLACK, LIGHT_GRAY),
        )

    fn _target_test(mut self):
        """Cmd+T: run the project's test suite.

        Unlike ``_target_run`` / ``_target_debug``, this doesn't read
        ``program`` / ``args`` off the active target — the user just
        wants "run the tests" without authoring a separate target for
        them. The language guess (active target's ``debug_language``
        first; otherwise ``detect_project_language`` on the project
        root) picks the runner: for ``python``, we invoke
        ``python -m pytest`` in the project root, swapping ``python``
        for the project venv's interpreter when one exists (same
        idiom as Cmd+R).

        Like Cmd+R, this terminates any in-flight run / debug session
        first — the debug pane only has one slot and the user's
        intent is "this pane now means tests". Test output streams
        through the same RUN-mode pane as Cmd+R, so the title flips
        to ``Run`` and the inspect column collapses to give the
        output log the full pane.
        """
        if not self.project:
            self.status_bar.set_message(
                String("test: open a project first"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        var project_root = self.project.value()
        # Active-target language wins when set (the user has already
        # told us what kind of project this is via the targets dialog);
        # otherwise probe the project root for known markers.
        var language = String("")
        if self.targets.has_active():
            language = self.targets.targets[self.targets.active].debug_language
        if len(language.as_bytes()) == 0:
            language = detect_project_language(project_root)
        if language != String("python"):
            var hint: String
            if len(language.as_bytes()) == 0:
                hint = String(
                    "test: couldn't detect project language —"
                    " no pyproject.toml / setup.py / *.py at root"
                )
            else:
                hint = String("test: no test runner configured for '") \
                    + language + String("'")
            self.status_bar.set_message(hint, Attr(LIGHT_RED, LIGHT_GRAY))
            return
        var program_seed = resolve_python_interpreter(
            project_root, String("python"),
        )
        var program = resolved_program(
            project_root, String(""), program_seed,
        )
        var args = List[String]()
        args.append(String("-m"))
        args.append(String("pytest"))
        # Stop any prior run / debug — the debug pane is single-slot.
        if self.dap.is_active():
            self.dap.shutdown()
            self._dap_exec_path = String("")
            self._dap_exec_line = -1
        self.run_session.terminate()
        self._run_output_held = False
        self.debug_pane.clear()
        self.debug_pane.visible = True
        var pretty = program
        for k in range(len(args)):
            pretty = pretty + String(" ") + args[k]
        self.debug_pane.append_output(
            String("$ ") + pretty, UInt8(2),  # PANE_OUT_CONSOLE
        )
        try:
            self.run_session.start(
                String("pytest"), program, args^, project_root,
            )
            self.status_bar.set_message(
                String("running tests…"),
                Attr(BLACK, LIGHT_GRAY),
            )
        except e:
            self.status_bar.set_message(
                String("test: spawn failed — ") + String(e),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )

    fn target_tick(mut self):
        """Drain the run session's output into the debug pane and
        reap on exit. Called once per frame by the host (paired with
        ``lsp_tick`` / ``dap_tick``).

        Cheap when no run is in flight — early-out on the first line.
        """
        if not self.run_session.is_active():
            return
        var out = drain_run_output(self.run_session)
        if len(out.stdout.as_bytes()) > 0:
            self.debug_pane.append_output(out.stdout, UInt8(0))  # PANE_OUT_STDOUT
        if len(out.stderr.as_bytes()) > 0:
            self.debug_pane.append_output(out.stderr, UInt8(1))  # PANE_OUT_STDERR
        if poll_run_exit(self.run_session):
            var name = self.run_session.target_name
            var code = self.run_session.exit_code
            self.run_session.terminate()
            self.debug_pane.append_output(
                String("[") + name + String(" exited with ")
                    + String(code) + String("]"),
                UInt8(2),  # PANE_OUT_CONSOLE
            )
            var attr = Attr(BLACK, LIGHT_GRAY) if code == 0 \
                else Attr(LIGHT_RED, LIGHT_GRAY)
            self.status_bar.set_message(
                name + String(" exited (") + String(code) + String(")"),
                attr,
            )
            # Pin the output pane open until the user dismisses it —
            # otherwise the exit message and any tail output flash off
            # screen as ``run_session.is_active()`` flips to False.
            self._run_output_held = True

    fn _paint_tab_bar(mut self, mut canvas: Canvas, screen: Rect):
        """Render one tab per open window directly above the status
        bar when ``config.tab_bar`` is on. Hidden when no rect is
        carved out (toggle off, or terminal too short)."""
        var rect = self.tab_bar_rect(screen)
        if rect.width() <= 0 or rect.height() <= 0:
            return
        var items = List[TabBarItem]()
        for i in range(len(self.windows.windows)):
            items.append(TabBarItem(self.windows.windows[i].title, i))
        self.tab_bar.paint(canvas, rect, items, self.windows.focused)

    fn _refresh_target_tabs(mut self):
        """Push the current target list + active selection into the
        status bar so the tabs render with up-to-date state. Called
        every paint — cheap (one short list)."""
        var tabs = List[StatusTab]()
        for i in range(len(self.targets.targets)):
            var t = self.targets.targets[i]
            var running = self.run_session.matches(t.name)
            var debugging = (
                self.dap.is_active()
                and self.dap.language_id == t.debug_language
                and len(t.debug_language.as_bytes()) > 0
                and self.targets.active == i
            )
            tabs.append(StatusTab(t.name, running, debugging))
        self.status_bar.set_tabs(tabs^, self.targets.active)

    fn _jump_to(mut self, target: DefinitionResolved, screen: Rect):
        """Focus the window for ``target.path`` (opening it if needed) and
        move the cursor to ``(line, character)``."""
        var existing = self._find_window_for_path(target.path)
        if existing < 0:
            try:
                self.open_file(target.path, screen)
            except:
                return
            existing = len(self.windows.windows) - 1
        else:
            self.windows.focus_by_index(existing)
        if existing < 0 or existing >= len(self.windows.windows):
            return
        if not self.windows.windows[existing].is_editor:
            return
        self.windows.windows[existing].editor.move_to(
            target.line, target.character, False, True,
        )
        self.windows.windows[existing].editor.reveal_cursor(
            self.windows.windows[existing].interior(),
        )

    fn _find_window_for_path(self, path: String) -> Int:
        """Return the index of an existing editor window whose file_path
        matches ``path`` (raw or canonicalized), or -1."""
        var canon = realpath(path)
        for i in range(len(self.windows.windows)):
            if not self.windows.windows[i].is_editor:
                continue
            var fp = self.windows.windows[i].editor.file_path
            if fp == path:
                return i
            if len(canon.as_bytes()) > 0 and realpath(fp) == canon:
                return i
        return -1

    # --- recents ----------------------------------------------------------

    fn _track_recent_focus(mut self):
        """Promote the focused editor's file path to the front of
        ``_recent_files``. Untitled / file-less buffers are skipped —
        they have no path that ``open_file`` could later restore.
        """
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            return
        # Already at the front — no change.
        if len(self._recent_files) > 0 and self._recent_files[0] == path:
            return
        # Remove an existing copy (anywhere in the list) before
        # re-inserting at the front, so each path appears at most once.
        var new_list = List[String]()
        new_list.append(path)
        for i in range(len(self._recent_files)):
            if self._recent_files[i] != path:
                new_list.append(self._recent_files[i])
        # Cap the list so a long-running session doesn't grow unbounded.
        var cap = 100
        while len(new_list) > cap:
            _ = new_list.pop(len(new_list) - 1)
        self._recent_files = new_list^

    fn _open_recent_picker(mut self):
        """Open the QuickOpen picker over the recents list, skipping the
        currently focused file. No-op when there's nothing to show
        (single open file, or no file-backed editors at all)."""
        if len(self._recent_files) <= 1:
            return
        # Display labels: project-relative when the file lives under the
        # active project root, absolute otherwise. Parallel ``abs_entries``
        # carries the absolute path used to actually open the file.
        var root = String("")
        if self.project:
            root = self.project.value()
        var rb = root.as_bytes()
        var rel_entries = List[String]()
        var abs_entries = List[String]()
        # Skip index 0 — that's the file the user is currently on.
        for i in range(1, len(self._recent_files)):
            var p = self._recent_files[i]
            var pb = p.as_bytes()
            var label = p
            if len(rb) > 0 and len(pb) > len(rb) + 1:
                var matches_root = True
                for k in range(len(rb)):
                    if pb[k] != rb[k]:
                        matches_root = False
                        break
                if matches_root and pb[len(rb)] == 0x2F:
                    label = String(StringSlice(
                        unsafe_from_utf8=pb[len(rb) + 1:],
                    ))
            rel_entries.append(label)
            abs_entries.append(p)
        if len(rel_entries) == 0:
            return
        self.quick_open.open_recent(root, rel_entries^, abs_entries^)

    fn _open_recent_projects_picker(mut self):
        """Open the QuickOpen picker over ``self.config.recent_projects``.

        Skips the currently active project (if any), and silently drops
        entries whose path no longer stats — a project that was moved
        or deleted shouldn't dead-end the dialog. No-op when nothing
        survives the filter.
        """
        if len(self.config.recent_projects) == 0:
            return
        var current = String("")
        if self.project:
            current = self.project.value()
        # Display labels: basename + " — " + parent for disambiguation
        # ("turbokod — /Users/boxed/Projects" reads better than the full
        # path), with parallel absolute paths for the actual open.
        var labels = List[String]()
        var abs_entries = List[String]()
        for i in range(len(self.config.recent_projects)):
            var p = self.config.recent_projects[i]
            if p == current:
                continue
            var info = stat_file(p)
            if not info.ok or not info.is_dir():
                continue
            var name = basename(p)
            var parent = parent_path(p)
            var label = name
            if len(name.as_bytes()) > 0 and len(parent.as_bytes()) > 0:
                label = name + String(" — ") + parent
            labels.append(label)
            abs_entries.append(p)
        if len(labels) == 0:
            return
        self.quick_open.open_recent(
            String(""), labels^, abs_entries^, picks_project=True,
        )

    # --- editor-action helpers --------------------------------------------

    fn _focused_editor_idx(self) -> Int:
        if self.windows.focused < 0 or self.windows.focused >= len(self.windows.windows):
            return -1
        if not self.windows.windows[self.windows.focused].is_editor:
            return -1
        return self.windows.focused

    fn _do_save(mut self):
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var has_path = len(self.windows.windows[idx].editor.file_path.as_bytes()) > 0
        if has_path:
            try:
                _ = self.windows.windows[idx].editor.save()
                # If the user just saved the targets file, reload so
                # the tab strip reflects their edit on the next frame
                # without needing to close/reopen the project.
                # Copy the path out before calling the reload helper —
                # passing the field directly would alias the borrowed
                # ``self`` (Mojo's exclusivity check rejects the call).
                var saved_path = self.windows.windows[idx].editor.file_path
                self._maybe_reload_targets(saved_path)
                # The diff against ``HEAD`` is now stale; clear the
                # cache so the next paint re-queries git for this file.
                self.windows.windows[idx].editor.invalidate_git_changes()
                # Fire any user-configured on-save actions whose language
                # matches this file. Each runs synchronously and reports
                # via the status bar — the editor blocks until they exit.
                self._run_on_save_actions(saved_path)
            except:
                pass
            return
        # No backing file — escalate to Save As.
        self._open_save_as_dialog()

    fn _run_on_save_actions(mut self, saved_path: String):
        """Walk ``self.config.on_save_actions`` and spawn each entry
        whose ``language_id`` matches the saved file's language (empty
        ``language_id`` matches every file). Each runs as a one-shot
        ``program + args`` subprocess; we wait for the exit and report
        the outcome on the status bar.

        Failures don't escalate — the save itself succeeded; an
        on-save action that exits non-zero just gets a status-bar
        warning. Spawn errors (program missing, etc.) likewise.
        """
        if len(self.config.on_save_actions) == 0:
            return
        var actions = self.config.on_save_actions.copy()
        var ext = extension_of(saved_path)
        var lang_idx = find_language_for_extension(self.lsp_specs, ext)
        var lang = String("")
        if lang_idx >= 0:
            lang = self.lsp_specs[lang_idx].language_id
        var ran_any = False
        for i in range(len(actions)):
            var act = actions[i]
            if len(act.language_id.as_bytes()) > 0 \
                    and act.language_id != lang:
                continue
            if len(act.program.as_bytes()) == 0:
                continue
            self._spawn_on_save_action(act, saved_path)
            ran_any = True
        # Formatters typically rewrite the saved file in place; pick up
        # the new bytes so the buffer doesn't drift from disk. The
        # buffer is clean (just saved + the action ran synchronously),
        # so this hits the clean-reload path — no merge needed.
        if ran_any:
            self._reload_after_on_save(saved_path)

    fn _reload_after_on_save(mut self, saved_path: String):
        """Re-stat the editor backing ``saved_path`` and adopt any new
        bytes the on-save action wrote. Silent on no-change."""
        for i in range(len(self.windows.windows)):
            if not self.windows.windows[i].is_editor:
                continue
            if self.windows.windows[i].editor.file_path != saved_path:
                continue
            try:
                _ = self.windows.windows[i].editor.check_for_external_change()
            except:
                pass
            return

    fn _spawn_on_save_action(
        mut self, act: OnSaveAction, saved_path: String,
    ):
        """Fork+exec ``act.program act.args...`` with the configured
        cwd (or the project root when blank), wait for it, and report.

        Uses ``LspProcess.spawn`` for the fork+exec wiring so the env
        (``HOME``, ``PATH``, etc.) matches everything else we run. We
        change the child's working directory by spawning ``sh -c``
        with a leading ``cd`` rather than going through ``fchdir`` —
        the env-allowlist + redirection plumbing is already wired for
        ``sh``, and an inline ``cd`` is one less moving part.
        """
        var cwd = act.cwd
        if len(cwd.as_bytes()) == 0:
            if self.project:
                cwd = self.project.value()
            else:
                cwd = parent_path(saved_path)
        var cmd = String("cd '") + cwd + String("' && '") + act.program \
            + String("'")
        for k in range(len(act.args)):
            var expanded = _expand_save_placeholders(act.args[k], saved_path)
            cmd = cmd + String(" '") + expanded + String("'")
        var argv = List[String]()
        argv.append(String("sh"))
        argv.append(String("-c"))
        argv.append(cmd^)
        var label = act.program
        var b = label.as_bytes()
        var slash = -1
        for k in range(len(b)):
            if b[k] == 0x2F:
                slash = k
        if slash >= 0:
            label = String(StringSlice(unsafe_from_utf8=b[slash + 1:]))
        try:
            var proc = LspProcess.spawn(argv)
            var status = waitpid_blocking(proc.pid)
            untrack_child(proc.pid)
            if proc.stdin_fd  >= 0: _ = close_fd(proc.stdin_fd)
            if proc.stdout_fd >= 0: _ = close_fd(proc.stdout_fd)
            if proc.stderr_fd >= 0: _ = close_fd(proc.stderr_fd)
            var exit_code = (Int(status) >> 8) & 0xFF
            if exit_code == 0:
                self.status_bar.set_message(
                    String("on-save: ") + label + String(" ok"),
                    Attr(BLACK, LIGHT_GRAY),
                )
            else:
                self.status_bar.set_message(
                    String("on-save: ") + label + String(" exit ")
                        + String(exit_code),
                    Attr(LIGHT_RED, LIGHT_GRAY),
                )
        except:
            self.status_bar.set_message(
                String("on-save: failed to spawn ") + label,
                Attr(LIGHT_RED, LIGHT_GRAY),
            )

    fn _maybe_reload_targets(mut self, saved_path: String):
        if not self.project:
            return
        var expected = join_path(
            join_path(self.project.value(), String(".turbokod")),
            String("targets.json"),
        )
        if saved_path == expected:
            self.targets = load_project_targets(self.project.value())

    fn _open_symbol_pick(mut self):
        """Open the Go-to-Symbol picker for the focused editor and kick
        off a ``textDocument/documentSymbol`` request to its language
        server. Picker shows "Loading…" until the response lands."""
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("LSP: file has no path"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var lsp_idx = self._lsp_for_path(path)
        if lsp_idx < 0:
            self.status_bar.set_message(
                String("LSP: not started for this file type"),
                Attr(RED, LIGHT_GRAY),
            )
            return
        if self.lsp_managers[lsp_idx].is_failed():
            return
        if not self.lsp_managers[lsp_idx].is_ready():
            self.status_bar.set_message(
                String("LSP: still starting up — try again"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        var text = self.windows.windows[idx].editor.text_snapshot()
        var ok = self.lsp_managers[lsp_idx].request_document_symbols(
            path, text^,
        )
        if ok:
            self.symbol_pick.open(path)

    fn _open_save_as_dialog(mut self):
        """Open the modal save-as picker, seeded from the focused editor's
        current path (or the project root for an untitled buffer). The
        dialog reuses ``DirBrowser`` for the folder listing — see
        ``SaveAsDialog`` for the keyboard model.
        """
        var idx = self._focused_editor_idx()
        var seed = String("")
        if idx >= 0:
            seed = self.windows.windows[idx].editor.file_path
        if len(seed.as_bytes()) == 0 and self.project:
            seed = self.project.value()
        self.save_as_dialog.open(seed^)

    # --- documentation lookup -------------------------------------------

    fn _doc_dest_dir(self, slug: String) -> String:
        """Where the offline DevDocs JSON for ``slug`` lives on disk.

        Per-project (under ``<project>/.turbokod/docs/<slug>/``) when a
        project is open; falls back to ``./.turbokod/docs/<slug>/`` so
        the user can still install docs while editing a stray file. The
        same path is used for the ``is_installed`` check, the install
        command, and the load — so all three agree without round-tripping
        through a registry.
        """
        var root = self.project.value() if self.project else String(".")
        return join_path(
            join_path(root, String(".turbokod")),
            join_path(String("docs"), slug),
        )

    fn _ensure_doc_store(mut self, lang: String) -> Int:
        """Index into ``doc_stores`` of the (possibly already-loaded)
        store for language ``lang``. Returns -1 when the language isn't
        in the docset registry. Doesn't load from disk — that happens
        on first ``_open_doc_pick`` after install confirms the files
        are actually there."""
        for i in range(len(self.doc_languages)):
            if self.doc_languages[i] == lang:
                return i
        var spec_idx = find_docset_by_language(self.doc_specs, lang)
        if spec_idx < 0:
            return -1
        var spec = self.doc_specs[spec_idx]
        self.doc_stores.append(DocStore(spec.slug, spec.display))
        self.doc_languages.append(lang)
        return len(self.doc_stores) - 1

    fn _open_doc_pick(mut self, screen: Rect):
        """Entry point for ``Ctrl+K`` / "Look up in docs".

        Routing tiers (first hit wins):

        1. **Focused editor's language** — if a recognized file is
           focused and its docset is installed, use that. The query
           is seeded with the identifier under the cursor.
        2. **Last-used docset** — sticky across windows so repeat
           lookups land on the same docs even after the user clicks
           into a different file.
        3. **Any installed docset** — when the user hasn't opened one
           this session but has an installed docset on disk from a
           previous run, just open it. First match in registry order.
        4. **Install prompt** — only if a focused editor pointed at a
           recognized-but-not-installed docset, ask the user to
           download. Otherwise we surface a status hint instead of
           prompting blind.

        The point: docs lookup never silently does nothing because no
        editor is focused. The fallback chain finds *something* to
        show as long as any docset is installed anywhere.
        """
        # Tier 1: focused editor with a recognized extension.
        var idx = self._focused_editor_idx()
        var ext_spec_idx = -1
        if idx >= 0:
            var path = self.windows.windows[idx].editor.file_path
            ext_spec_idx = find_docset_for_extension(
                self.doc_specs, extension_of(path),
            )
            if ext_spec_idx >= 0:
                var ext_lang = self.doc_specs[ext_spec_idx].language_id
                if self._open_doc_pick_for_lang(ext_lang, idx):
                    return
        # Tier 2: last-used docset. Copy out before the call — Mojo's
        # exclusivity check rejects passing an alias of ``self`` while
        # the method takes ``mut self``.
        if len(self._last_doc_lang.as_bytes()) > 0:
            var last = self._last_doc_lang
            if self._open_doc_pick_for_lang(last, idx):
                return
        # Tier 3: scan the registry for any docset that's installed on
        # disk. Earlier specs win — pinned slugs are listed in roughly
        # popularity order in ``built_in_docsets``.
        for i in range(len(self.doc_specs)):
            var spec = self.doc_specs[i]
            var dest = self._doc_dest_dir(spec.slug)
            # Cheap stat-based check before we materialize a store —
            # ``DocStore.is_installed`` only stats the two JSON files,
            # so a throwaway probe asks the disk question without
            # committing to a store entry for an unused language.
            var probe = DocStore(String(""), String(""))
            if probe.is_installed(dest):
                if self._open_doc_pick_for_lang(spec.language_id, idx):
                    return
        # Tier 4: nothing installed. If the focused file pointed at a
        # known docset, prompt to install it; otherwise hint that the
        # user needs to focus a recognized file once to bootstrap.
        if ext_spec_idx >= 0:
            var ext_spec = self.doc_specs[ext_spec_idx]
            self._maybe_prompt_doc_install(ext_spec)
            return
        self.status_bar.set_message(
            String("Docs: open a recognized source file once to install a docset"),
            Attr(BLACK, LIGHT_GRAY),
        )

    fn _open_doc_pick_for_lang(
        mut self, lang: String, focused_editor_idx: Int,
    ) -> Bool:
        """Open the picker for ``lang`` if its docset is installed on
        disk. Returns False (no side effects) when the docset isn't in
        the registry or hasn't been downloaded — caller falls through
        to the next tier. Returns True even on a load error so the
        caller doesn't keep falling through and stomp the error
        message we just set on the status bar.

        ``focused_editor_idx`` is the editor whose cursor word seeds
        the query; pass -1 to skip seeding (fallback tiers where no
        editor was usable).
        """
        var spec_idx = find_docset_by_language(self.doc_specs, lang)
        if spec_idx < 0:
            return False
        var spec = self.doc_specs[spec_idx]
        var dest = self._doc_dest_dir(spec.slug)
        var store_idx = self._ensure_doc_store(spec.language_id)
        if store_idx < 0:
            return False
        if not self.doc_stores[store_idx].is_installed(dest):
            return False
        try:
            self.doc_stores[store_idx].load(dest)
        except e:
            self.status_bar.set_message(
                String("Docs load failed: ") + String(e),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return True
        self.doc_pick.open(
            spec.display, self.doc_stores[store_idx].entries.copy(),
        )
        if focused_editor_idx >= 0:
            self._seed_doc_query_from_cursor(focused_editor_idx)
        self._last_doc_lang = spec.language_id
        return True

    fn _seed_doc_query_from_cursor(mut self, win_idx: Int):
        """Pre-fill the doc picker's query with the identifier under the
        focused editor's cursor (if any). No-op for buffers with no
        identifier under the cursor (whitespace, punctuation, etc.) —
        the user just gets the full entry list."""
        if win_idx < 0 or win_idx >= len(self.windows.windows):
            return
        if not self.windows.windows[win_idx].is_editor:
            return
        var editor = self.windows.windows[win_idx].editor
        var row = editor.cursor_row
        if row < 0 or row >= editor.buffer.line_count():
            return
        var line = editor.buffer.line(row)
        var word = word_at(line, editor.cursor_col)
        if len(word.as_bytes()) == 0:
            return
        self.doc_pick.query = word^
        self.doc_pick._refilter()

    fn _maybe_prompt_doc_install(mut self, spec: DocSpec):
        """Open the "Download <X> docs?" prompt. Skipped when another
        modal is open or when the user has already been asked for this
        language this session — same one-nag rule as the LSP installer.
        """
        for i in range(len(self._doc_install_prompted)):
            if self._doc_install_prompted[i] == spec.language_id:
                # Already declined / pending — surface a hint so the
                # user knows why nothing happened on their second
                # Ctrl+K attempt for this language.
                self.status_bar.set_message(
                    String("Docs: ") + spec.display
                        + String(" not installed (asked earlier this session)"),
                    Attr(BLACK, LIGHT_GRAY),
                )
                return
        if self.prompt.active or self.confirm_dialog.active \
                or self.quick_open.active \
                or self.symbol_pick.active or self.project_find.active \
                or self.local_changes.active \
                or self.save_as_dialog.active or self.doc_pick.active:
            return
        self._doc_install_prompted.append(spec.language_id)
        self._pending_action = _PA_DOC_INSTALL
        self._pending_arg = spec.language_id
        self.confirm_dialog.open(
            String("Download ") + spec.display
                + String(" docs (~few MB)?")
        )

    fn _start_doc_install(mut self, lang: String):
        """Spawn the ``curl`` install for the docset matching ``lang``,
        through the same ``InstallRunner`` that handles LSP installs.

        ``InstallRunner`` is single-slot — if an install (LSP *or* docs)
        is already in flight we surface the conflict on the status bar
        rather than queue, since the popup only renders one at a time.
        """
        var spec_idx = find_docset_by_language(self.doc_specs, lang)
        if spec_idx < 0:
            return
        var spec = self.doc_specs[spec_idx]
        var dest = self._doc_dest_dir(spec.slug)
        var cmd = docs_install_command(spec.slug, dest)
        if self.install_runner.is_active():
            self.status_bar.set_message(
                String("Install busy; try ") + spec.display
                    + String(" docs again in a moment"),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        try:
            self.install_runner.start(
                spec.display + String(" docs"), cmd,
            )
            self._doc_install_lang = lang
            self.status_bar.set_message(
                String("Downloading ") + spec.display + String(" docs..."),
                Attr(BLACK, LIGHT_GRAY),
            )
        except:
            self.status_bar.set_message(
                String("Failed to start docs download"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )

    fn _on_doc_install_complete(
        mut self, result: InstallResult, screen: Rect,
    ):
        """React to a docs download finishing. Success: load + open the
        picker right away so the user sees the entries they just paid
        for. Failure: same shape as the LSP install path — popup an
        editor window with the curl output."""
        var lang = self._doc_install_lang
        self._doc_install_lang = String("")
        if result.ok():
            var store_idx = self._ensure_doc_store(lang)
            if store_idx < 0:
                return
            var spec_idx = find_docset_by_language(self.doc_specs, lang)
            if spec_idx < 0:
                return
            var spec = self.doc_specs[spec_idx]
            var dest = self._doc_dest_dir(spec.slug)
            try:
                self.doc_stores[store_idx].load(dest)
            except e:
                self.status_bar.set_message(
                    String("Docs load failed: ") + String(e),
                    Attr(LIGHT_RED, LIGHT_GRAY),
                )
                return
            self.status_bar.set_message(
                String("Installed ") + result.label,
                Attr(BLACK, LIGHT_GRAY),
            )
            # Open the picker now — the user just opted in to docs, so
            # taking them straight to the listing is the obvious follow-up.
            self.doc_pick.open(
                spec.display, self.doc_stores[store_idx].entries.copy(),
            )
            var idx = self._focused_editor_idx()
            if idx >= 0:
                self._seed_doc_query_from_cursor(idx)
            # Remember this language so a subsequent Ctrl+K from any
            # window (focused editor or not) lands on the same docset.
            self._last_doc_lang = lang
        else:
            var title = String("Docs install failed: ") + result.label \
                + String(" (exit ") + String(result.exit_code()) + String(")")
            var workspace = self.workspace_rect(screen)
            var rect = self._default_window_rect(workspace)
            var was_max = self._frontmost_maximized()
            var body = String("$ ") + result.command + String("\n\n") \
                + result.output
            self.windows.add(Window.editor_window(title^, rect, body^))
            self._open_count += 1
            if was_max:
                var w_idx = len(self.windows.windows) - 1
                self.windows.windows[w_idx].toggle_maximize(workspace)
            self.status_bar.set_message(
                String("Docs install failed (exit ")
                    + String(result.exit_code()) + String(") — see new window"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )

    fn _try_docs_fallback(
        mut self, lang: String, word: String, screen: Rect,
    ) -> Bool:
        """When the LSP returns no definition for ``word``, try to open
        the matching DevDocs entry instead. Returns True iff we
        actually opened something.

        Conservative behavior on purpose:

        * We **don't** prompt to install — a single Cmd+click should
          never escalate to a network download. If the docset isn't on
          disk we silently fall through and the existing "no definition
          found" status takes over.
        * We do an *exact* name match first, then a ``*.<word>`` suffix
          match (``find`` → ``str.find``) so unqualified clicks on
          methods still resolve. Multiple suffix matches → first one
          wins; the user can still hit Ctrl+K to disambiguate.
        """
        var spec_idx = find_docset_by_language(self.doc_specs, lang)
        if spec_idx < 0:
            return False
        var spec = self.doc_specs[spec_idx]
        var dest = self._doc_dest_dir(spec.slug)
        var store_idx = self._ensure_doc_store(lang)
        if store_idx < 0:
            return False
        # Don't trigger an install here — silently bail when the user
        # hasn't opted in to docs for this language yet.
        if not self.doc_stores[store_idx].is_installed(dest):
            return False
        if not self.doc_stores[store_idx].loaded:
            try:
                self.doc_stores[store_idx].load(dest)
            except:
                return False
        var entry_idx = _find_doc_entry_for_word(
            self.doc_stores[store_idx].entries, word,
        )
        if entry_idx < 0:
            return False
        self._open_doc_entry(entry_idx, spec.display, screen)
        self.status_bar.set_message(
            String("Opened docs: ") + word + String(" (")
                + spec.display + String(")"),
            Attr(BLACK, LIGHT_GRAY),
        )
        return True

    fn _open_doc_entry(
        mut self, entry_idx: Int, display: String, screen: Rect,
    ):
        """Render a doc entry's HTML and open it in a read-only viewer
        window.

        The window title carries the entry name + docset; the body is
        markdown-flavoured plain text from ``html_to_text``. The
        editor's ``read_only`` flag suppresses every mutating
        operation (typing, paste, undo, …) so the user can scroll and
        copy without accidentally typing into the rendered page.
        ``_apply_view_config`` keeps the line-number gutter off on
        read-only editors regardless of the global view toggle.
        """
        # Find which loaded store this index belongs to. Picker
        # tracked the docset by ``display``; we look up the store by
        # display since multiple docsets can share a language id is
        # not currently a thing but might be in the future.
        var store_idx = -1
        for i in range(len(self.doc_stores)):
            if self.doc_stores[i].display == display:
                store_idx = i
                break
        if store_idx < 0:
            return
        if entry_idx < 0 or entry_idx >= len(self.doc_stores[store_idx].entries):
            return
        var entry = self.doc_stores[store_idx].entries[entry_idx]
        var html = self.doc_stores[store_idx].html_for(entry_idx)
        var text = html_to_text(html)
        if len(text.as_bytes()) == 0:
            text = String("(no body — this entry's path was missing from db.json)")
        var title = entry.name + String(" — ") + display
        var workspace = self.workspace_rect(screen)
        var rect = self._default_window_rect(workspace)
        var was_max = self._frontmost_maximized()
        self.windows.add(Window.editor_window(title^, rect, text^))
        self._open_count += 1
        var idx = len(self.windows.windows) - 1
        self.windows.windows[idx].editor.read_only = True
        self.windows.windows[idx].editor.line_numbers = False
        if was_max:
            self.windows.windows[idx].toggle_maximize(workspace)

    fn _on_confirm_submit(mut self) -> Optional[String]:
        """Resolve the most recent ``confirm_dialog.open`` by reading
        ``confirm_dialog.confirmed`` and dispatching the install action
        keyed by ``_pending_action``. The dialog is closed before any
        side effects run so install spawns can surface follow-up
        modals without colliding with the closing dialog."""
        var yes = self.confirm_dialog.confirmed
        self.confirm_dialog.close()
        var pa = self._pending_action
        self._pending_action = String("")
        if pa == _PA_DOC_INSTALL:
            var lang = self._pending_arg
            self._pending_arg = String("")
            if yes:
                self._start_doc_install(lang)
            return Optional[String]()
        if pa == _PA_GRAMMAR_INSTALL:
            var lang = self._pending_arg
            self._pending_arg = String("")
            if yes:
                self._start_grammar_install(lang)
            return Optional[String]()
        if pa == _PA_LSP_INSTALL:
            # Yes → run the install command as ``sh -c <hint>`` and show
            # a non-modal progress popup. The clipboard copy is preserved
            # as a fallback for cases that genuinely need a real shell
            # (interactive sudo, password prompts, anything that wants a
            # TTY) — those will fail in our non-TTY child and the user
            # can paste from the clipboard into their own terminal.
            # ``_pending_arg`` carries the language id for the spec lookup.
            var lang = self._pending_arg
            self._pending_arg = String("")
            if yes:
                var spec_idx = -1
                for i in range(len(self.lsp_specs)):
                    if self.lsp_specs[i].language_id == lang:
                        spec_idx = i
                        break
                if spec_idx >= 0:
                    var hint = self.lsp_specs[spec_idx].install_hint
                    clipboard_copy(hint)
                    if self.install_runner.is_active():
                        self.status_bar.set_message(
                            String("Install busy; copied to clipboard: ")
                                + hint,
                            Attr(BLACK, LIGHT_GRAY),
                        )
                    else:
                        try:
                            self.install_runner.start(
                                String(lang), String(hint),
                            )
                            self._install_lang = lang
                            self.status_bar.set_message(
                                String("Installing ") + lang
                                    + String("…  (also copied to clipboard)"),
                                Attr(BLACK, LIGHT_GRAY),
                            )
                        except:
                            self.status_bar.set_message(
                                String("Run: ") + hint
                                    + String("  (copied to clipboard)"),
                                Attr(BLACK, LIGHT_GRAY),
                            )
            return Optional[String]()
        # Unknown / no pending action — nothing to do.
        self._pending_arg = String("")
        return Optional[String]()

    fn _on_prompt_submit(mut self) -> Optional[String]:
        var text = self.prompt.input
        self.prompt.close()
        var pa = self._pending_action
        self._pending_action = String("")
        if pa == EDITOR_FIND:
            self._last_search = text
            var idx = self._focused_editor_idx()
            if idx >= 0:
                if self.windows.windows[idx].editor.find_next(text):
                    self.windows.windows[idx].editor.reveal_cursor(
                        self.windows.windows[idx].interior(),
                        margin_below=10, margin_above=10,
                    )
            return Optional[String]()
        if pa == _PA_DOC_INSTALL or pa == _PA_GRAMMAR_INSTALL \
                or pa == _PA_LSP_INSTALL:
            # The confirm dialog is what drives these actions now —
            # if we ever land here it means a stale pending tag
            # leaked into a regular prompt submit. Drop it cleanly.
            self._pending_arg = String("")
            return Optional[String]()
        if pa == EDITOR_GOTO:
            var idx = self._focused_editor_idx()
            if idx >= 0:
                var n = 0
                if len(text.as_bytes()) > 0:
                    try:
                        n = Int(atol(text))
                    except:
                        n = 0
                self.windows.windows[idx].editor.goto_line(n)
            return Optional[String]()
        if pa == _PA_REPLACE_FIND:
            self._pending_arg = text
            self._pending_action = _PA_REPLACE_DO
            self.prompt.open(String("Replace with: "))
            return Optional[String]()
        if pa == _PA_REPLACE_DO:
            var find = self._pending_arg
            self._pending_arg = String("")
            var idx = self._focused_editor_idx()
            if idx >= 0:
                _ = self.windows.windows[idx].editor.replace_all(find, text)
            return Optional[String]()
        if pa == _PA_PROJECT_REPLACE_FIND:
            self._pending_arg = text
            self._pending_action = _PA_PROJECT_REPLACE_DO
            self.prompt.open(String("Replace in project with: "))
            return Optional[String]()
        if pa == _PA_PROJECT_REPLACE_DO:
            var find = self._pending_arg
            self._pending_arg = String("")
            if self.project:
                try:
                    var summary = replace_in_project(
                        self.project.value(), find, text,
                    )
                    self.windows.add(_summary_window(
                        find, text, summary[0], summary[1],
                    ))
                except:
                    pass
            return Optional[String]()
        if pa == _PA_BP_CONDITION:
            # ``_pending_arg`` carries ``path|line`` from when the
            # prompt was opened. Empty input clears any existing
            # condition (the breakpoint stays).
            var arg = self._pending_arg
            self._pending_arg = String("")
            var sep = -1
            var ab = arg.as_bytes()
            for k in range(len(ab)):
                if ab[k] == 0x7C:  # '|'
                    sep = k
                    break
            if sep > 0:
                var path = String(StringSlice(
                    ptr=ab.unsafe_ptr(), length=sep,
                ))
                var line_str = String(StringSlice(
                    ptr=ab.unsafe_ptr() + sep + 1, length=len(ab) - sep - 1,
                ))
                var line = 0
                try:
                    line = Int(atol(line_str))
                except:
                    pass
                self.dap.set_breakpoint_condition(path, line, text)
            return Optional[String]()
        if pa == _PA_ADD_WATCH:
            if len(text.as_bytes()) > 0:
                self.add_watch(text)
            return Optional[String]()
        return Optional[String]()


# --- Small helpers ----------------------------------------------------------


fn _find_doc_entry_for_word(
    entries: List[DocEntry], word: String,
) -> Int:
    """Return the index of the entry whose name best matches ``word``,
    or -1 when no entry matches.

    Match priority: exact equality → exact equality ignoring ASCII
    case → suffix match (entry name ends with ``.<word>``, e.g.
    ``str.find`` for the word ``find``). The suffix path is what makes
    Cmd+click on an unqualified method name (``s.find()`` → click on
    ``find``) land on the right entry; the case-insensitive tier is a
    safety net for languages where DevDocs and the user's source
    spell things differently (CSS property names, HTML attrs)."""
    if len(word.as_bytes()) == 0:
        return -1
    # Exact match wins, regardless of position in the list.
    for i in range(len(entries)):
        if entries[i].name == word:
            return i
    var wb = word.as_bytes()
    # Case-insensitive exact match.
    for i in range(len(entries)):
        var nb = entries[i].name.as_bytes()
        if len(nb) != len(wb):
            continue
        var ok = True
        for k in range(len(nb)):
            var ca = Int(nb[k])
            var cb = Int(wb[k])
            if 0x41 <= ca and ca <= 0x5A: ca += 0x20
            if 0x41 <= cb and cb <= 0x5A: cb += 0x20
            if ca != cb:
                ok = False
                break
        if ok:
            return i
    # Suffix match: ``.<word>``. First hit wins (DevDocs typically
    # lists the most common parent type first — ``str.find`` ahead of
    # ``bytes.find`` for example).
    for i in range(len(entries)):
        var nb = entries[i].name.as_bytes()
        if len(nb) <= len(wb):
            continue
        # The byte before ``word`` must be ``.``.
        if nb[len(nb) - len(wb) - 1] != 0x2E:
            continue
        var ok2 = True
        for k in range(len(wb)):
            if nb[len(nb) - len(wb) + k] != wb[k]:
                ok2 = False
                break
        if ok2:
            return i
    return -1




fn _expand_save_placeholders(arg: String, saved_path: String) -> String:
    """Replace every literal ``$FilePath$`` in ``arg`` with ``saved_path``.

    Only one placeholder is recognised today; this is the entry point
    for adding more later (``$FileDir$``, ``$ProjectDir$``, …) without
    touching the call site.
    """
    var token_str = String("$FilePath$")
    var token = token_str.as_bytes()
    var b = arg.as_bytes()
    var n = len(b)
    var t = len(token)
    if n < t:
        return arg
    var out = String("")
    var i = 0
    var run_start = 0
    while i + t <= n:
        var hit = True
        for k in range(t):
            if b[i + k] != token[k]:
                hit = False
                break
        if hit:
            if i > run_start:
                out = out + String(StringSlice(unsafe_from_utf8=b[run_start:i]))
            out = out + saved_path
            i += t
            run_start = i
        else:
            i += 1
    if run_start < n:
        out = out + String(StringSlice(unsafe_from_utf8=b[run_start:n]))
    return out




fn _clip_rect_to_workspace(rect: Rect, workspace: Rect) -> Rect:
    """Shrink-and-shift ``rect`` so it fits entirely inside ``workspace``,
    preserving the upper-left anchor when possible. Used for restored
    sessions: a window saved at terminal size 200×60 gets clipped down
    if the user opens the project in an 80×24 terminal, instead of
    being painted off-screen.

    Width / height are clamped first (to ``MIN_WIN_*``-or-workspace,
    whichever is smaller); then the anchor slides up-and-left until
    the clipped rect fits.
    """
    var w = rect.width()
    var h = rect.height()
    if w < MIN_WIN_W:
        w = MIN_WIN_W
    if h < MIN_WIN_H:
        h = MIN_WIN_H
    if w > workspace.width():
        w = workspace.width()
    if h > workspace.height():
        h = workspace.height()
    var ax = rect.a.x
    var ay = rect.a.y
    if ax < workspace.a.x:
        ax = workspace.a.x
    if ay < workspace.a.y:
        ay = workspace.a.y
    if ax + w > workspace.b.x:
        ax = workspace.b.x - w
    if ay + h > workspace.b.y:
        ay = workspace.b.y - h
    return Rect(ax, ay, ax + w, ay + h)


fn _category_to_pane(category: String) -> UInt8:
    """Map a DAP ``output`` event's category string to the pane's
    output-attr enum. ``stderr`` lights the row red; ``console`` (and
    ``important``) get a dim color so the user can tell adapter chatter
    apart from program output. Anything unknown defaults to stdout."""
    if category == String("stderr"):
        return UInt8(1)   # PANE_OUT_STDERR
    if category == String("console") or category == String("important"):
        return UInt8(2)   # PANE_OUT_CONSOLE
    return UInt8(0)       # PANE_OUT_STDOUT


fn _same_file(a: String, b: String) -> Bool:
    """True if ``a`` and ``b`` resolve to the same on-disk file. Used to
    match a DAP stack-frame source path against editor file paths even
    when one is a symlink and the other is canonical."""
    if a == b:
        return True
    if len(a.as_bytes()) == 0 or len(b.as_bytes()) == 0:
        return False
    var ra = realpath(a)
    var rb = realpath(b)
    return len(ra.as_bytes()) > 0 and ra == rb




fn _mojo_include_dirs(root: String) -> List[String]:
    """``-I`` paths for ``mojo-lsp-server``: the project root, plus
    ``<root>/src`` if it exists.

    Without these the server can resolve ``from sys import ...`` but not
    ``from <project> import ...`` — every Cmd+click on a project symbol
    comes back empty. The ``src/`` subdirectory is a near-universal Mojo
    project convention (matches ``mojo run -I src ...`` in this repo's
    own ``run.sh``); covering it plus the root keeps both flat and
    src-style layouts working without any per-project configuration.
    """
    var dirs = List[String]()
    if len(root.as_bytes()) == 0:
        return dirs^
    dirs.append(root)
    var src = join_path(root, String("src"))
    var info = stat_file(src)
    if info.ok and info.is_dir():
        dirs.append(src)
    return dirs^


# --- Result / summary windows for project search ----------------------------


fn _refresh_status_for(
    mut sb: StatusBar, prefix: String, m: LspManager,
):
    """Free function so the caller can pass ``self.status_bar`` and one
    of ``self.lsp_*`` without tripping Mojo's exclusivity check (a
    method receiver implicitly aliases the whole struct, which conflicts
    with passing one of its fields as a separate argument)."""
    if m.is_failed():
        sb.set_message(
            prefix + m.failure_reason,
            Attr(LIGHT_RED, LIGHT_GRAY),
        )
        return
    if m.is_initializing():
        sb.set_message(
            prefix + String("starting..."),
            Attr(BLACK, LIGHT_GRAY),
        )
        return
    if m.is_ready():
        var word = m.inflight_word()
        if len(word.as_bytes()) > 0:
            sb.set_message(
                prefix + String("looking up ") + word + String("..."),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        if m.last_empty():
            sb.set_message(
                prefix + String("no definition found"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        sb.set_message(
            prefix + String("ready"),
            Attr(BLACK, LIGHT_GRAY),
        )


fn _rg_missing_window() -> Window:
    var content = List[String]()
    content.append(String("Project find requires ripgrep (rg), which was not"))
    content.append(String("found on your PATH."))
    content.append(String(""))
    content.append(String("Install it from https://github.com/BurntSushi/ripgrep"))
    content.append(String("(e.g. `brew install ripgrep` or your distro's package"))
    content.append(String("manager) and try again."))
    return Window(
        String("ripgrep not installed"), Rect(10, 6, 68, 15), content^,
    )


fn _summary_window(
    find: String, replace: String, files_changed: Int, total: Int,
) -> Window:
    var content = List[String]()
    content.append(String("Find:    ") + find)
    content.append(String("Replace: ") + replace)
    content.append(String(""))
    content.append(
        String("Replaced ") + String(total)
        + String(" occurrence(s) in ")
        + String(files_changed) + String(" file(s)."),
    )
    return Window(String("Replace in project"), Rect(10, 6, 64, 14), content^)
