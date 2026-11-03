#!/usr/bin/env bash
# local-sshd.sh <dir>: start a throwaway sshd on 127.0.0.1:2222 as the
# current user, with test client keys of every type and an ssh-agent.
# Stop it with: kill $(cat <dir>/sshd.pid); kill $SSH_AGENT_PID from <dir>/agent.env
set -euo pipefail
S="$(mkdir -p "$1" && cd "$1" && pwd)"
cd "$S"
mkdir -p keys data/dir

for t in ed25519 rsa ecdsa; do [ -f host_$t ] || ssh-keygen -q -t $t -N '' -f host_$t; done
gen() { [ -f "keys/$1" ] || ssh-keygen -q -C "$1" -f "keys/$1" "${@:2}"; }
gen ed25519     -t ed25519 -N ''
gen ed25519-enc -t ed25519 -N secret
gen rsa         -t rsa -b 3072 -N ''
gen rsa-enc     -t rsa -b 3072 -N secret
gen rsa-pem-enc -t rsa -b 3072 -m PEM -N secret
gen ecdsa       -t ecdsa -b 256 -N ''
gen agent-only  -t ed25519 -N ''
cat keys/*.pub > authorized_keys

cat > sshd_config <<CFG
Port 2222
ListenAddress 127.0.0.1
HostKey $S/host_ed25519
HostKey $S/host_rsa
HostKey $S/host_ecdsa
AuthorizedKeysFile $S/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $S/sshd.pid
Subsystem sftp /usr/libexec/sftp-server
CFG

[ -f data/blob100m.bin ] || mkfile 100m data/blob100m.bin
for i in $(seq 1 500); do echo "line $i" > data/dir/file$i.txt; done

/usr/sbin/sshd -f "$S/sshd_config" -E "$S/sshd.log"
# Record the ed25519 host key, as a first OpenSSH connection would.
echo "[127.0.0.1]:2222 $(cut -d' ' -f1-2 host_ed25519.pub)" > known_hosts

# Unix socket paths are limited to ~104 bytes, so bind it relative to $S.
ssh-agent -a agent.sock > agent.env
SSH_AUTH_SOCK=agent.sock ssh-add -q keys/agent-only
echo "sshd on 127.0.0.1:2222, files in $S"
