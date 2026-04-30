"""Persistent global preferences for turbokod.

Lives at ``~/.config/turbokod/config.json``. Defaults are encoded right
here so the editor still works on a fresh checkout with no config file
present, and any failure (missing file, malformed JSON, missing keys)
silently falls back to the defaults rather than refusing to start.

Currently persists the View-menu toggles — line numbers and soft wrap.
Other settings can join later by extending ``TurbokodConfig`` plus the
load/save round-trip.
"""

from std.ffi import external_call

from .file_io import read_file, stat_file, write_file
from .json import (
    JsonValue, encode_json, json_bool, json_object, parse_json,
)
from .posix import getenv_value


fn _config_dir() -> String:
    """Directory that holds the config file. Empty when ``$HOME`` is
    unset (e.g. inside an unusual sandbox); callers treat that as
    "no persistent config available" and skip both load and save."""
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0:
        return String("")
    return home + String("/.config/turbokod")


fn _config_path() -> String:
    var dir = _config_dir()
    if len(dir.as_bytes()) == 0:
        return String("")
    return dir + String("/config.json")


fn _ensure_dir(path: String):
    """Best-effort ``mkdir`` ignoring ``EEXIST``. We don't recurse; the
    caller attempts both ``~/.config`` and ``~/.config/turbokod`` to
    cover machines where ``~/.config`` doesn't exist yet."""
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


@fieldwise_init
struct TurbokodConfig(ImplicitlyCopyable, Movable):
    """Global preferences. Defaults match the pre-config behavior."""
    var line_numbers: Bool
    var soft_wrap: Bool

    fn __init__(out self):
        self.line_numbers = False
        self.soft_wrap = False


fn load_config() -> TurbokodConfig:
    """Load the saved config, or return defaults on any failure."""
    var cfg = TurbokodConfig()
    var path = _config_path()
    if len(path.as_bytes()) == 0:
        return cfg
    var info = stat_file(path)
    if not info.ok:
        return cfg
    try:
        var text = read_file(path)
        var root = parse_json(text)
        if not root.is_object():
            return cfg
        var ln = root.object_get(String("line_numbers"))
        if ln and ln.value().is_bool():
            cfg.line_numbers = ln.value().as_bool()
        var sw = root.object_get(String("soft_wrap"))
        if sw and sw.value().is_bool():
            cfg.soft_wrap = sw.value().as_bool()
    except:
        pass
    return cfg


fn save_config(config: TurbokodConfig) -> Bool:
    """Write ``config`` to ``~/.config/turbokod/config.json``. Returns
    True on success. Creates ``~/.config`` and ``~/.config/turbokod``
    if they don't exist yet."""
    var path = _config_path()
    if len(path.as_bytes()) == 0:
        return False
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) > 0:
        _ensure_dir(home + String("/.config"))
    _ensure_dir(_config_dir())
    var root = json_object()
    root.put(String("line_numbers"), json_bool(config.line_numbers))
    root.put(String("soft_wrap"), json_bool(config.soft_wrap))
    return write_file(path, encode_json(root) + String("\n"))
