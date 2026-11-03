"""The last text typed into a search field, remembered per project root.

Find, Find / Replace in Project, Quick Open and Find Symbol reopen with
what the user last searched for *in that project*, fully selected so the
first keystroke replaces it. One ``QueryMemory`` per field; ``""`` is the
key for "no project".
"""

from std.collections.list import List


struct QueryMemory(Copyable, Movable):
    var _roots: List[String]
    var _texts: List[String]

    def __init__(out self):
        self._roots = List[String]()
        self._texts = List[String]()

    def get(self, root: String) -> String:
        for i in range(len(self._roots)):
            if self._roots[i] == root:
                return self._texts[i]
        return String("")

    def put(mut self, root: String, text: String):
        for i in range(len(self._roots)):
            if self._roots[i] == root:
                self._texts[i] = text
                return
        self._roots.append(root)
        self._texts.append(text)
