# SFTP spike results (Phase 0, 2026-11-03)

Both backends ran the same checks (`scripts/run-matrix.sh`) against a local
OpenSSH `sshd` on 127.0.0.1:2222 (`scripts/local-sshd.sh`) with ed25519, RSA
and ECDSA host keys.

| Check | libssh2 1.11.1 | Citadel 0.12.1 |
|---|---|---|
| ed25519 key | ✅ | ✅ |
| ed25519 key, encrypted (OpenSSH, bcrypt) | ✅ | ✅ |
| RSA key | ✅ | ❌ `allAuthenticationOptionsFailed` (signs with SHA-1 `ssh-rsa`, which OpenSSH rejects) |
| RSA key, encrypted (OpenSSH) | ✅ | ❌ same |
| RSA key, encrypted (legacy PEM) | ✅ | ❌ `invalidPrivateKeyFormat` |
| ECDSA P-256 key | ✅ | ❌ no key-file parser |
| ssh-agent | ✅ | ❌ not supported |
| known_hosts match / mismatch | ✅ via `libssh2_knownhost_*` | ✅ hand-written |
| exec: exit status | ✅ | ❌ non-zero exit throws |
| exec: stderr kept separate | ✅ | ❌ stderr output throws `TTYSTDError` |
| list 500 entries | 3.4 ms | 3.9 ms |
| 100 MB download (loopback) | 288 MB/s, one 1 MB `libssh2_sftp_read` loop | 310 MB/s, only with 16 hand-pipelined 32 KB reads |
| wrong passphrase / missing path | clear errors | clear errors |

Not covered locally: password and keyboard-interactive auth, because a
non-root sshd can't check passwords. Test them against a real server
(below).

## Decision: libssh2

Citadel fails on RSA keys, legacy PEM keys, ECDSA key files and the agent.
Those are exactly the long tail a few hundred real servers will hit. libssh2
handled every case, and its exec channel gives the exit status and stderr
that archiving (`zip`/`tar` over SSH) needs.

Things to carry into `EdithCore`'s SFTP client:

- **Host key preference.** libssh2 prefers ECDSA host keys, while OpenSSH
  prefers ed25519. That makes a known host look unknown, because known_hosts
  holds a different key type. Call `libssh2_session_method_pref(…HOSTKEY…)`
  with the types known_hosts already has for the host first, then OpenSSH's
  default order.
- **Packaging.** Homebrew's libssh2 links OpenSSL 4 dynamically. The app
  needs its own static libssh2 and OpenSSL build (an xcframework from a
  script in this repo), signed with the app.
- **Blocking API.** Run each session on its own thread inside an actor, or
  use non-blocking mode with a socket dispatch source. Decide in Phase 1.

## Running it against a real server

```sh
cd Spikes/SFTPSpike
swift build -c release
B=.build/release/sftp-spike-libssh2

$B --host example.com --user deploy --agent --list /var/www --exec 'uname -a'
$B --host example.com --user deploy --key ~/.ssh/id_rsa --passphrase-env PP --list /
PW='…' $B --host example.com --user deploy --password-env PW --download /path/big.file
```

The spike only reads: it lists, downloads to a temp file it deletes, and runs
the command you pass.
