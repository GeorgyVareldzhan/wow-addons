"""Минимальное чтение архивов MPQ (v1/v2, как в WoW 3.3.5): поиск файла и распаковка (zlib, bzip2).
Только чтение, свой код по открытому описанию формата."""
import bz2
import os
import struct
import zlib

M = 0xFFFFFFFF


def _crypt_table():
    t = [0] * 0x500
    seed = 0x00100001
    for i in range(256):
        idx = i
        for _ in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            t1 = (seed & 0xFFFF) << 16
            seed = (seed * 125 + 3) % 0x2AAAAB
            t2 = seed & 0xFFFF
            t[idx] = t1 | t2
            idx += 256
    return t


CT = _crypt_table()


def mhash(s, kind):
    s1, s2 = 0x7FED7FED, 0xEEEEEEEE
    for ch in s.upper().encode("latin-1"):
        s1 = (CT[(kind << 8) + ch] ^ ((s1 + s2) & M)) & M
        s2 = (ch + s1 + s2 + ((s2 << 5) & M) + 3) & M
    return s1


def decrypt(data, key):
    seed = 0xEEEEEEEE
    n = len(data) // 4
    vals = struct.unpack("<%dI" % n, data[:n * 4])
    out = []
    for v in vals:
        seed = (seed + CT[0x400 + (key & 0xFF)]) & M
        ch = v ^ ((key + seed) & M)
        out.append(ch)
        key = ((((~key) << 0x15) + 0x11111111) & M) | (key >> 0x0B)
        seed = (ch + seed + ((seed << 5) & M) + 3) & M
    return struct.pack("<%dI" % n, *out) + data[n * 4:]


class Archive:
    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        off = 0
        size = os.path.getsize(path)
        while off < size:
            self.f.seek(off)
            if self.f.read(4) == b"MPQ\x1a":
                break
            off += 512
        else:
            raise ValueError("не MPQ")
        self.base = off
        self.f.seek(off)
        h = self.f.read(44)
        (_, hsize, _, ver, sshift, htpos, btpos, htsize, btsize) = struct.unpack("<4sIIHHIIII", h[:32])
        self.version = ver
        self.sector = 512 << sshift
        hi_bt = ht_hi = bt_hi = 0
        if ver >= 1 and hsize >= 44:
            hi_bt, ht_hi, bt_hi = struct.unpack("<QHH", h[32:44])
        self.f.seek(off + htpos + (ht_hi << 32))
        ht = decrypt(self.f.read(htsize * 16), mhash("(hash table)", 3))
        self.hash = [struct.unpack_from("<IIHHI", ht, i * 16) for i in range(htsize)]
        self.f.seek(off + btpos + (bt_hi << 32))
        bt = decrypt(self.f.read(btsize * 16), mhash("(block table)", 3))
        self.block = [struct.unpack_from("<IIII", bt, i * 16) for i in range(btsize)]
        self.hihi = [0] * btsize
        if hi_bt:
            self.f.seek(off + hi_bt)
            raw = self.f.read(btsize * 2)
            self.hihi = list(struct.unpack("<%dH" % btsize, raw))

    def find(self, name):
        n = len(self.hash)
        if n == 0:
            return None
        a, b = mhash(name, 1), mhash(name, 2)
        i = mhash(name, 0) % n
        for _ in range(n):
            ha, hb, loc, plat, bi = self.hash[i]
            if bi == 0xFFFFFFFF:
                return None
            if ha == a and hb == b and bi != 0xFFFFFFFE:
                return bi
            i = (i + 1) % n
        return None

    def read(self, name):
        bi = self.find(name)
        if bi is None:
            return None
        boff, psize, fsize, flags = self.block[bi]
        if not flags & 0x80000000:
            return None
        pos = self.base + boff + (self.hihi[bi] << 32)
        key = None
        if flags & 0x10000:
            key = mhash(name.replace("/", "\\").split("\\")[-1], 3)
            if flags & 0x20000:
                key = ((key + boff) ^ fsize) & M
        self.f.seek(pos)
        if flags & 0x1000000:  # один блок
            d = self.f.read(psize)
            if key is not None:
                d = decrypt(d, key)
            return self._unpack(d, fsize) if (flags & 0x200 and psize < fsize) else d
        nsec = (fsize + self.sector - 1) // self.sector
        raw = self.f.read(psize)
        tlen = (nsec + 1) * 4
        tbl = raw[:tlen]
        if key is not None:
            tbl = decrypt(tbl, (key - 1) & M)
        offs = struct.unpack("<%dI" % (nsec + 1), tbl)
        out = []
        left = fsize
        for s in range(nsec):
            d = raw[offs[s]:offs[s + 1]]
            if key is not None:
                d = decrypt(d, (key + s) & M)
            want = min(self.sector, left)
            if (flags & 0x200) and len(d) < want:
                d = self._unpack(d, want)
            out.append(d)
            left -= want
        return b"".join(out)[:fsize]

    @staticmethod
    def _unpack(d, size):
        t = d[0]
        if t == 0x02:
            return zlib.decompress(d[1:])
        if t == 0x10:
            return bz2.decompress(d[1:])
        raise ValueError("сжатие 0x%02x не поддержано" % t)
