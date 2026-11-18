"""Lookups over the built-in catalogs keyed by language — language
servers, docsets, downloadable grammars and dictionaries, debuggers. Each
catalog's entry says what language it's for (and, where files map to it,
whether an extension does); these find an entry the one way."""

from std.collections.list import List


trait LanguageKeyed(Copyable, Movable):
    def catalog_language(self) -> String:
        """The language id the entry is for."""
        ...


trait ExtensionKeyed(LanguageKeyed):
    def catalog_has_extension(self, ext: String) -> Bool:
        """Whether files with extension ``ext`` are this entry's."""
        ...


def catalog_by_language[T: LanguageKeyed](
    specs: List[T], language_id: String,
) -> Int:
    """Index of the entry for ``language_id``, or -1 (also for an empty
    id)."""
    if len(language_id.as_bytes()) == 0:
        return -1
    for i in range(len(specs)):
        if specs[i].catalog_language() == language_id:
            return i
    return -1


def catalog_by_extension[T: ExtensionKeyed](
    specs: List[T], ext: String,
) -> Int:
    """Index of the first entry claiming extension ``ext``, or -1 (also for
    an empty one). A linear scan: the catalogs are small and this runs
    once per file open."""
    if len(ext.as_bytes()) == 0:
        return -1
    for i in range(len(specs)):
        if specs[i].catalog_has_extension(ext):
            return i
    return -1
