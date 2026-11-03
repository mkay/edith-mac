# SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
# SPDX-License-Identifier: GPL-3.0-or-later

"""A small FTP/FTPS server for EdithCore's tests. Standard library only.

    python3 ftpserver.py --root DIR --port N [--cert C --key K]
                         [--implicit] [--no-mlsd] [--no-epsv] [--require-reuse]

Serves DIR to user "test" with password "secret". With a certificate it
offers AUTH TLS (or speaks TLS from the start with --implicit). With
--require-reuse it refuses data connections that don't resume the control
connection's TLS session, as vsftpd does by default. --no-mlsd hides MLSD
and MLST so clients fall back to LIST. Prints "ready" once listening.
"""

import argparse
import os
import shutil
import socket
import socketserver
import ssl
import stat
import sys
import threading
import time

ARGS = None
CONTEXT = None


class Session(socketserver.StreamRequestHandler):
    def setup(self):
        sock = self.request
        if ARGS.implicit:
            sock = CONTEXT.wrap_socket(sock, server_side=True)
        self.sock = sock
        self.reader = sock.makefile("rb")
        self.cwd = "/"
        self.user = None
        self.logged_in = False
        self.tls = ARGS.implicit
        self.prot_private = False
        self.passive = None
        self.rename_from = None

    def handle(self):
        self.reply(220, "Edith test server")
        while True:
            raw = self.reader.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            cmd, _, arg = line.partition(" ")
            cmd = cmd.upper()
            handler = getattr(self, "cmd_" + cmd, None)
            if handler is None:
                self.reply(502, f"{cmd} not implemented")
                continue
            if cmd not in ("USER", "PASS", "AUTH", "FEAT", "QUIT", "PBSZ", "PROT") and not self.logged_in:
                self.reply(530, "Please log in")
                continue
            try:
                if handler(arg) == "quit":
                    return
            except OSError as e:
                self.reply(550, str(e))

    def reply(self, code, text):
        lines = text.split("\n")
        out = "".join(f"{code}-{l}\r\n" for l in lines[:-1]) + f"{code} {lines[-1]}\r\n"
        self.sock.sendall(out.encode())

    def real(self, path):
        path = path or "."
        virtual = os.path.normpath(os.path.join(self.cwd, path)) if not path.startswith("/") else os.path.normpath(path)
        virtual = "/" + virtual.lstrip("/")
        return os.path.join(ARGS.root, virtual.lstrip("/")), virtual

    # --- session ---

    def cmd_USER(self, arg):
        self.user = arg
        self.reply(331, "Password please")

    def cmd_PASS(self, arg):
        if self.user == "test" and arg == "secret":
            self.logged_in = True
            self.reply(230, "Logged in")
        else:
            self.reply(530, "Login incorrect")

    def cmd_AUTH(self, arg):
        if CONTEXT is None or arg.upper() not in ("TLS", "SSL"):
            self.reply(500, "AUTH not understood")
            return
        self.reply(234, "Go ahead")
        self.sock = CONTEXT.wrap_socket(self.sock, server_side=True)
        self.reader = self.sock.makefile("rb")
        self.tls = True

    def cmd_PBSZ(self, arg):
        self.reply(200, "PBSZ=0")

    def cmd_PROT(self, arg):
        self.prot_private = arg.upper() == "P"
        self.reply(200, "Protection set")

    def cmd_FEAT(self, arg):
        feats = ["UTF8", "SIZE", "MDTM", "EPSV"]
        if not ARGS.no_mlsd:
            feats.append("MLST type*;size*;modify*;unix.mode*;unix.owner*;")
        if CONTEXT is not None:
            feats += ["AUTH TLS", "PBSZ", "PROT"]
        self.reply(211, "Features:\n" + "\n".join(" " + f for f in feats) + "\nEnd")

    def cmd_OPTS(self, arg):
        self.reply(200, "OK")

    def cmd_TYPE(self, arg):
        self.reply(200, "Type set")

    def cmd_NOOP(self, arg):
        self.reply(200, "OK")

    def cmd_QUIT(self, arg):
        self.reply(221, "Bye")
        return "quit"

    def cmd_PWD(self, arg):
        self.reply(257, '"' + self.cwd.replace('"', '""') + '" is the current directory')

    def cmd_CWD(self, arg):
        real, virtual = self.real(arg)
        if os.path.isdir(real):
            self.cwd = virtual
            self.reply(250, "OK")
        else:
            self.reply(550, "No such directory")

    def cmd_ABOR(self, arg):
        self.reply(226, "Nothing to abort")

    # --- data connections ---

    def cmd_EPSV(self, arg):
        if ARGS.no_epsv:
            self.reply(502, "EPSV not implemented")
            return
        self.open_passive()
        self.reply(229, f"Entering Extended Passive Mode (|||{self.passive.getsockname()[1]}|)")

    def cmd_PASV(self, arg):
        self.open_passive()
        port = self.passive.getsockname()[1]
        # An address that isn't reachable, like the private ones real servers
        # send: clients must connect to the control host instead.
        self.reply(227, f"Entering Passive Mode (10,255,255,1,{port >> 8},{port & 255})")

    def open_passive(self):
        if self.passive:
            self.passive.close()
        self.passive = socket.socket()
        self.passive.bind(("127.0.0.1", 0))
        self.passive.listen(1)

    def data(self):
        """Accept the data connection, after the 150, as real servers do."""
        if not self.passive:
            self.reply(425, "Use PASV first")
            return None
        self.reply(150, "Opening data connection")
        self.passive.settimeout(10)
        conn, _ = self.passive.accept()
        self.passive.close()
        self.passive = None
        if self.tls and self.prot_private:
            conn = CONTEXT.wrap_socket(conn, server_side=True)
            if ARGS.require_reuse and not conn.session_reused:
                conn.close()
                self.reply(522, "SSL connection failed: session reuse required")
                return None
        return conn

    def finish(self, conn, code=226, text="Transfer complete"):
        try:
            if isinstance(conn, ssl.SSLSocket):
                conn.unwrap()
        except (OSError, ValueError):
            pass
        conn.close()
        self.reply(code, text)

    def cmd_RETR(self, arg):
        real, _ = self.real(arg)
        if not os.path.isfile(real):
            self.reply(550, "No such file")
            return
        conn = self.data()
        if conn is None:
            return
        with open(real, "rb") as f:
            try:
                shutil.copyfileobj(f, conn.makefile("wb"))
            except OSError:
                pass
        self.finish(conn)

    def cmd_STOR(self, arg):
        real, _ = self.real(arg)
        if not os.path.isdir(os.path.dirname(real)):
            self.reply(550, "No such directory")
            return
        conn = self.data()
        if conn is None:
            return
        with open(real, "wb") as f:
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                f.write(chunk)
        self.finish(conn)

    def listing(self, real):
        return sorted(os.listdir(real)) if os.path.isdir(real) else []

    def cmd_MLSD(self, arg):
        if ARGS.no_mlsd:
            self.reply(500, "Unknown command")
            return
        real, _ = self.real(arg)
        if not os.path.isdir(real):
            self.reply(550, "No such directory")
            return
        conn = self.data()
        if conn is None:
            return
        out = "".join(self.facts(os.path.join(real, n)) + " " + n + "\r\n" for n in self.listing(real))
        conn.sendall(out.encode())
        self.finish(conn)

    def cmd_MLST(self, arg):
        if ARGS.no_mlsd:
            self.reply(500, "Unknown command")
            return
        real, virtual = self.real(arg)
        if not os.path.lexists(real):
            self.reply(550, "No such file")
            return
        # RFC 3659: the facts line starts with a space, not the code.
        self.sock.sendall(f"250-Listing {virtual}\r\n {self.facts(real)} {virtual}\r\n250 End\r\n".encode())

    def facts(self, real):
        st = os.lstat(real)
        if stat.S_ISLNK(st.st_mode):
            kind = "OS.unix=symlink"
        elif stat.S_ISDIR(st.st_mode):
            kind = "dir"
        else:
            kind = "file"
        modify = time.strftime("%Y%m%d%H%M%S", time.gmtime(st.st_mtime))
        return f"type={kind};size={st.st_size};modify={modify};unix.mode={stat.S_IMODE(st.st_mode):04o};unix.owner=tester;"

    def cmd_LIST(self, arg):
        args = arg.split()
        show_all = "-a" in args
        paths = [a for a in args if not a.startswith("-")]
        real, _ = self.real(paths[0] if paths else "")
        conn = self.data()
        if conn is None:
            return
        lines = []
        for name in self.listing(real):
            if name.startswith(".") and not show_all:
                continue
            full = os.path.join(real, name)
            st = os.lstat(full)
            when = time.strftime("%b %d %H:%M", time.localtime(st.st_mtime))
            shown = name + (" -> " + os.readlink(full) if stat.S_ISLNK(st.st_mode) else "")
            lines.append(f"{stat.filemode(st.st_mode)} 1 tester staff {st.st_size:>8} {when} {shown}")
        conn.sendall(("\r\n".join(lines) + "\r\n").encode() if lines else b"")
        self.finish(conn)

    # --- files ---

    def cmd_SIZE(self, arg):
        real, _ = self.real(arg)
        if os.path.isfile(real):
            self.reply(213, str(os.path.getsize(real)))
        else:
            self.reply(550, "No such file")

    def cmd_MDTM(self, arg):
        real, _ = self.real(arg)
        if os.path.exists(real):
            self.reply(213, time.strftime("%Y%m%d%H%M%S", time.gmtime(os.path.getmtime(real))))
        else:
            self.reply(550, "No such file")

    def cmd_MKD(self, arg):
        real, virtual = self.real(arg)
        if os.path.exists(real):
            self.reply(550, "File exists")
            return
        os.mkdir(real)
        self.reply(257, f'"{virtual}" created')

    def cmd_RMD(self, arg):
        real, _ = self.real(arg)
        os.rmdir(real)
        self.reply(250, "Removed")

    def cmd_DELE(self, arg):
        real, _ = self.real(arg)
        if not os.path.lexists(real):
            self.reply(550, "No such file")
            return
        os.remove(real)
        self.reply(250, "Deleted")

    def cmd_RNFR(self, arg):
        real, _ = self.real(arg)
        if not os.path.lexists(real):
            self.reply(550, "No such file")
            return
        self.rename_from = real
        self.reply(350, "Ready for RNTO")

    def cmd_RNTO(self, arg):
        real, _ = self.real(arg)
        os.rename(self.rename_from, real)
        self.reply(250, "Renamed")

    def cmd_SITE(self, arg):
        parts = arg.split(None, 2)
        if len(parts) == 3 and parts[0].upper() == "CHMOD":
            real, _ = self.real(parts[2])
            os.chmod(real, int(parts[1], 8))
            self.reply(200, "Permissions changed")
        else:
            self.reply(500, "Unknown SITE command")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    global ARGS, CONTEXT
    p = argparse.ArgumentParser()
    p.add_argument("--root", required=True)
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--cert")
    p.add_argument("--key")
    p.add_argument("--implicit", action="store_true")
    p.add_argument("--no-mlsd", action="store_true")
    p.add_argument("--require-reuse", action="store_true")
    p.add_argument("--no-epsv", action="store_true")
    ARGS = p.parse_args()
    if ARGS.cert:
        CONTEXT = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        CONTEXT.load_cert_chain(ARGS.cert, ARGS.key)
    server = Server(("127.0.0.1", ARGS.port), Session)
    print("ready", server.server_address[1], flush=True)
    # Stop when the test process goes away (its end of our stdin closes).
    threading.Thread(target=lambda: (sys.stdin.read(), os._exit(0)), daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
