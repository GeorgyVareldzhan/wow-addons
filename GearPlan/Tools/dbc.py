"""Предмет -> имя иконки по таблицам клиента (DBFilesClient\\Item.dbc, ItemDisplayInfo.dbc) через mpq.py."""
import struct


def parse(raw):
    magic, nrec, nf, rsize, ssize = struct.unpack("<4sIIII", raw[:20])
    assert magic == b"WDBC"
    recs = raw[20:20 + nrec * rsize]
    strings = raw[20 + nrec * rsize:20 + nrec * rsize + ssize]
    rows = [struct.unpack_from("<%dI" % nf, recs, i * rsize) for i in range(nrec)]
    return rows, strings


def string(strings, off):
    end = strings.find(b"\0", off)
    return strings[off:end].decode("utf-8", "replace")


def item_icons(archives):
    def read(name):
        for a in archives:
            try:
                d = a.read(name)
            except Exception:
                d = None
            if d:
                return d
        return None

    item, _ = parse(read("DBFilesClient\\Item.dbc"))
    disp, s = parse(read("DBFilesClient\\ItemDisplayInfo.dbc"))
    icon_of_disp = {r[0]: string(s, r[5]) for r in disp}
    return {r[0]: icon_of_disp.get(r[5], "") for r in item}
