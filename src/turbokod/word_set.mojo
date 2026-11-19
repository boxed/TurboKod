"""A set of short byte strings, stored compactly.

Every word lives in one byte blob, NUL-terminated, and is found through an
open-addressing table of 32-bit offsets into it. That is the word's bytes
plus about six more per word, where a ``List[String]`` per hash bucket cost
81 (a 24-byte ``String`` each, doubled by list growth): the spelling
dictionary's 292k words went from 23.6 MB to about 5.

Words can't be removed one at a time, only all at once (``clear``), which
is all the dictionary needs. An empty set holds no memory.
"""

from std.collections.list import List


comptime _MIN_SLOTS = 64


def _hash(w: Span[UInt8, _]) -> UInt32:
    """32-bit FNV-1a."""
    var h = UInt32(2166136261)
    for i in range(len(w)):
        h = (h ^ UInt32(w[i])) * UInt32(16777619)
    return h


struct WordSet(Copyable, Movable):
    var blob: List[UInt8]
    """The words, each followed by a NUL. Byte 0 is a NUL of its own so
    that no word starts at offset 0, which ``slots`` uses for "empty"."""
    var slots: List[UInt32]
    """Offsets into ``blob``, 0 for an empty slot. A power of two long, at
    most three quarters full; linear probing."""
    var count: Int

    def __init__(out self):
        self.blob = List[UInt8]()
        self.slots = List[UInt32]()
        self.count = 0

    def clear(mut self):
        self.blob = List[UInt8]()
        self.slots = List[UInt32]()
        self.count = 0

    def reserve(mut self, bytes: Int, words: Int):
        """Make room up front for ``words`` more words totalling ``bytes``
        bytes (terminators included, so a word-per-line file's size is the
        figure). Loading a large list into a set that grows as it goes
        leaves the outgrown blobs and tables behind as garbage the
        allocator keeps."""
        var need = len(self.blob) + bytes + 1
        if need > self.blob.capacity():
            self.blob.reserve(need)
        var n_slots = max(len(self.slots), _MIN_SLOTS)
        while (self.count + words) * 4 > n_slots * 3:
            n_slots *= 2
        if n_slots > len(self.slots):
            self._rehash(n_slots)

    def _rehash(mut self, n_slots: Int):
        var slots = List[UInt32](length=n_slots, fill=0)
        var mask = n_slots - 1
        var n = len(self.blob)
        var off = 1
        while off < n:
            var h = UInt32(2166136261)
            var end = off
            while self.blob[end] != 0:
                h = (h ^ UInt32(self.blob[end])) * UInt32(16777619)
                end += 1
            var s = Int(h) & mask
            while slots[s] != 0:
                s = (s + 1) & mask
            slots[s] = UInt32(off)
            off = end + 1
        self.slots = slots^

    def _equals(self, off: Int, w: Span[UInt8, _]) -> Bool:
        var n = len(w)
        if off + n >= len(self.blob) or self.blob[off + n] != 0:
            return False
        for i in range(n):
            if self.blob[off + i] != w[i]:
                return False
        return True

    def _slot_of(self, w: Span[UInt8, _]) -> Int:
        """The slot holding ``w``, or the empty one it would go in. Needs a
        table (``len(slots) > 0``)."""
        var mask = len(self.slots) - 1
        var s = Int(_hash(w)) & mask
        while True:
            var off = Int(self.slots[s])
            if off == 0 or self._equals(off, w):
                return s
            s = (s + 1) & mask

    def has(self, w: Span[UInt8, _]) -> Bool:
        if self.count == 0 or len(w) == 0:
            return False
        return self.slots[self._slot_of(w)] != 0

    def add(mut self, w: Span[UInt8, _]) -> Bool:
        """Add ``w``; False if it was already there, or can't be stored (an
        empty word, or one with a NUL in it)."""
        var n = len(w)
        if n == 0:
            return False
        for i in range(n):
            if w[i] == 0:
                return False
        if (self.count + 1) * 4 > len(self.slots) * 3:
            self._rehash(max(len(self.slots) * 2, _MIN_SLOTS))
        var s = self._slot_of(w)
        if self.slots[s] != 0:
            return False
        if len(self.blob) == 0:
            self.blob.append(0)
        self.slots[s] = UInt32(len(self.blob))
        self.blob.extend(w)
        self.blob.append(0)
        self.count += 1
        return True
