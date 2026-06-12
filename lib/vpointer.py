#!/usr/bin/env python3
"""Minimal zero-dependency Wayland client for wlr-virtual-pointer-unstable-v1.

Used by bin/hb-point to inject real pointer input into the bench compositor.
Speaks the wire protocol directly over the unix socket - no pywayland, no
compiled helper. wlrctl cannot hold a button (no press/release), which drags
require, hence this client. Protocol reference vendored at
protocols/wlr-virtual-pointer-unstable-v1.xml; opcodes are the request order
in the interface definition.

Usage: vpointer.py --extent WxH OP [OP...]
  OPs: move X Y | press BTN | release BTN | sleep MS
Coordinates are absolute compositor/output pixels (motion_absolute against
the given extents). BTN: left | right | middle.
"""
import os
import socket
import struct
import sys
import time

BTN = {"left": 0x110, "right": 0x111, "middle": 0x112}
PRESSED, RELEASED = 1, 0

# zwlr_virtual_pointer_v1 request opcodes (see vendored XML)
REQ_MOTION_ABSOLUTE = 1
REQ_BUTTON = 2
REQ_FRAME = 4
REQ_DESTROY = 8
# zwlr_virtual_pointer_manager_v1
REQ_CREATE_POINTER = 0


class Wayland:
    def __init__(self, display):
        path = display if display.startswith("/") else os.path.join(
            os.environ["XDG_RUNTIME_DIR"], display)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.next_id = 2
        self.buf = b""

    def new_id(self):
        i = self.next_id
        self.next_id += 1
        return i

    def send(self, obj, opcode, args=b""):
        size = 8 + len(args)
        self.sock.sendall(struct.pack("<II", obj, (size << 16) | opcode) + args)

    @staticmethod
    def string(s):
        b = s.encode() + b"\0"
        return struct.pack("<I", len(b)) + b + b"\0" * ((-len(b)) % 4)

    def read_msg(self):
        while len(self.buf) < 8:
            d = self.sock.recv(4096)
            if not d:
                raise ConnectionError("wayland socket closed")
            self.buf += d
        obj, so = struct.unpack_from("<II", self.buf)
        size, opcode = so >> 16, so & 0xFFFF
        while len(self.buf) < size:
            d = self.sock.recv(4096)
            if not d:
                raise ConnectionError("wayland socket closed")
            self.buf += d
        payload = self.buf[8:size]
        self.buf = self.buf[size:]
        return obj, opcode, payload

    def roundtrip(self, handler=None):
        """wl_display.sync; pump events until the callback fires."""
        cb = self.new_id()
        self.send(1, 0, struct.pack("<I", cb))
        while True:
            obj, opcode, payload = self.read_msg()
            if obj == cb and opcode == 0:  # wl_callback.done
                return
            if obj == 1 and opcode == 0:  # wl_display.error
                eobj, ecode = struct.unpack_from("<II", payload)
                slen = struct.unpack_from("<I", payload, 8)[0]
                msg = payload[12:12 + slen - 1].decode()
                raise RuntimeError(
                    f"wayland error: object {eobj} code {ecode}: {msg}")
            if handler:
                handler(obj, opcode, payload)


def now_ms():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


def main():
    args = sys.argv[1:]
    if len(args) < 3 or args[0] != "--extent":
        sys.exit(__doc__.strip())
    ext_w, ext_h = (int(v) for v in args[1].split("x"))
    ops = args[2:]

    display = os.environ.get("HB_WAYLAND_DISPLAY") or os.environ.get("WAYLAND_DISPLAY")
    if not display:
        sys.exit("vpointer: no HB_WAYLAND_DISPLAY/WAYLAND_DISPLAY")
    w = Wayland(display)

    registry = w.new_id()
    w.send(1, 1, struct.pack("<I", registry))  # wl_display.get_registry
    found = {}

    def on_global(obj, opcode, payload):
        if obj == registry and opcode == 0:  # wl_registry.global
            name = struct.unpack_from("<I", payload)[0]
            slen = struct.unpack_from("<I", payload, 4)[0]
            iface = payload[8:8 + slen - 1].decode()
            ver = struct.unpack_from("<I", payload, 8 + slen + ((-slen) % 4))[0]
            found[iface] = (name, ver)

    w.roundtrip(on_global)

    iface = "zwlr_virtual_pointer_manager_v1"
    if iface not in found:
        sys.exit(f"vpointer: compositor does not advertise {iface}")
    gname, gver = found[iface]
    mgr = w.new_id()
    w.send(registry, 0, struct.pack("<I", gname) + Wayland.string(iface)
           + struct.pack("<II", min(gver, 1), mgr))  # wl_registry.bind
    ptr = w.new_id()
    w.send(mgr, REQ_CREATE_POINTER, struct.pack("<II", 0, ptr))  # seat=null
    w.roundtrip()  # surface bind errors before injecting

    i = 0
    while i < len(ops):
        op = ops[i]
        if op == "move":
            x, y = int(ops[i + 1]), int(ops[i + 2])
            i += 3
            x = max(0, min(x, ext_w))
            y = max(0, min(y, ext_h))
            w.send(ptr, REQ_MOTION_ABSOLUTE,
                   struct.pack("<IIIII", now_ms(), x, y, ext_w, ext_h))
            w.send(ptr, REQ_FRAME)
        elif op in ("press", "release"):
            btn = BTN[ops[i + 1]]
            i += 2
            state = PRESSED if op == "press" else RELEASED
            w.send(ptr, REQ_BUTTON, struct.pack("<III", now_ms(), btn, state))
            w.send(ptr, REQ_FRAME)
        elif op == "sleep":
            ms = int(ops[i + 1])
            i += 2
            w.roundtrip()  # flush queued events before waiting
            time.sleep(ms / 1000)
        else:
            sys.exit(f"vpointer: unknown op '{op}'")

    w.roundtrip()
    w.send(ptr, REQ_DESTROY)
    w.sock.close()


if __name__ == "__main__":
    main()
