#!/usr/bin/env bash
# run-matrix.sh <spike-binary> <dir>: the checks in RESULTS.md, against a
# server started by local-sshd.sh <dir>.
B="$1"; S="$2"; cd "$S"; export PP=secret
C=(--host 127.0.0.1 --port 2222 --user "$USER" --known-hosts "$S/known_hosts")
"$B" "${C[@]}" --key keys/ed25519 --list "$S/data/dir" --download "$S/data/blob100m.bin" --exec 'echo hi; uname -s'
for k in ed25519-enc rsa-enc rsa-pem-enc; do "$B" "${C[@]}" --key keys/$k --passphrase-env PP --list "$S/data"; done
for k in rsa ecdsa; do "$B" "${C[@]}" --key keys/$k --list "$S/data"; done
SSH_AUTH_SOCK=agent.sock "$B" "${C[@]}" --agent --list "$S/data" --exec 'exit 3'
"$B" "${C[@]}" --known-hosts /dev/null --key keys/ed25519 --exec 'echo x >&2; echo y'
"$B" "${C[@]}" --key keys/ed25519 --list /nonexistent
"$B" "${C[@]}" --key keys/ed25519-enc --passphrase-env NOPE 2>&1
PP=wrong "$B" "${C[@]}" --key keys/ed25519-enc --passphrase-env PP
