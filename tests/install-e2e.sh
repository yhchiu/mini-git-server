#!/usr/bin/env bash
# End-to-end test of "install" on a disposable Debian 13 system, such as a CI
# container.
#
# Unlike tests/integration.sh, this test changes the system: it installs
# packages, creates the "git" hosting account, writes to /etc/ssh and starts
# sshd on port 2222. It refuses to run unless MGS_E2E_DISPOSABLE=1 is set.
# Never run it on a machine you want to keep.
#
# After installing, it starts sshd and uses real SSH connections: the admin
# workflow, Gitolite access rules, Git protocol v2, doctor, status and
# backup. The steps depend on each other, so the run stops at the first
# failure and prints the end of the log.
set -Eeuo pipefail
IFS=$'\n\t'

# Ignore Git settings from the caller's environment.
while IFS= read -r var; do
  [[ $var == GIT_* ]] && unset "$var"
done < <(compgen -e)

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/mini-git-server.sh"
SSH_PORT=2222
GL_USER=git
GL_HOME=/home/git
PORT_DROPIN=/etc/ssh/sshd_config.d/00-gitolite-port.conf
HARDENING_DROPIN=/etc/ssh/sshd_config.d/90-gitolite.conf
LIMITS_DROPIN=/etc/ssh/sshd_config.d/99-gitolite-limits.conf

refuse() {
  printf '%s\n' "$*" >&2
  exit 1
}

[[ ${MGS_E2E_DISPOSABLE:-} == 1 ]] || \
  refuse "This test changes the system (packages, the git account, /etc/ssh, sshd). Run it only on a disposable Debian 13 system or container, with MGS_E2E_DISPOSABLE=1."
[[ ${EUID:-$(id -u)} -eq 0 ]] || refuse "The install test must run as root."
# shellcheck disable=SC1091
[[ $(. /etc/os-release && printf '%s' "${ID:-}") == debian ]] || \
  refuse "The install test needs Debian, because install supports Debian only."
if id "$GL_USER" >/dev/null 2>&1 || [[ -e $PORT_DROPIN || -e $HARDENING_DROPIN || -e $LIMITS_DROPIN ]]; then
  refuse "This system already has a '$GL_USER' account or mini-git-server SSH settings. Use a fresh system."
fi

TMP=$(mktemp -d)
LOG="$TMP/test.log"
KEYS="$TMP/keys"
ADMIN="$TMP/gitolite-admin"
WORK="$TMP/work"
KNOWN_HOSTS="$TMP/known_hosts"
CLIENT_GITCONFIG="$TMP/client.gitconfig"
SSHD_PID_FILE="$TMP/sshd.pid"
CURRENT_STEP="setup"
PASS=0

# Keep the original stderr: the EXIT trap may run while a step's output is
# still redirected to the log.
exec 3>&2

cleanup() {
  if [[ -f $SSHD_PID_FILE ]]; then
    kill "$(cat "$SSHD_PID_FILE")" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}

on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    printf 'not ok - %s\n' "$CURRENT_STEP" >&3
    if [[ -f $LOG ]]; then
      printf '%s\n' '--- end of test log ---' >&3
      tail -n 60 "$LOG" >&3 || true
    fi
  fi
  cleanup
  exit "$rc"
}
trap on_exit EXIT
trap 'printf "  failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND"' ERR

step() {
  CURRENT_STEP=$1
  printf '=== %s\n' "$1" >>"$LOG"
  "$2" >>"$LOG" 2>&1
  printf 'ok - %s\n' "$1"
  PASS=$((PASS + 1))
}

assert_eq() {
  local expected=$1 actual=$2 msg=${3:-"values differ"}
  [[ $actual == "$expected" ]] || {
    printf '  %s\n  expected: %q\n  actual:   %q\n' "$msg" "$expected" "$actual"
    return 1
  }
}

assert_contains() {
  local haystack=$1 needle=$2 msg=${3:-"missing expected text"}
  [[ $haystack == *"$needle"* ]] || {
    printf '  %s\n  missing: %s\n' "$msg" "$needle"
    return 1
  }
}

# Run a command as the hosting account, starting in its home directory.
as_git() {
  (cd "$GL_HOME" && runuser -u "$GL_USER" -- env HOME="$GL_HOME" "$@")
}

# The SSH options of every client connection in this test: no user or system
# SSH config, no ssh-agent, one key, and only the host keys printed by
# host-keys (an unknown host key fails instead of prompting).
ssh_options() {
  printf '%s\n' -F /dev/null -i "$KEYS/$1" -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS"
}

ssh_as() {
  local key=$1
  shift
  local -a options=()
  mapfile -t options < <(ssh_options "$key")
  ssh "${options[@]}" -p "$SSH_PORT" "$@"
}

# Run a client-side command whose Git connects over real SSH with KEY.
client_as() {
  local key=$1 ssh_cmd option
  shift
  ssh_cmd=ssh
  while IFS= read -r option; do
    printf -v ssh_cmd '%s %q' "$ssh_cmd" "$option"
  done < <(ssh_options "$key")
  env GIT_CONFIG_GLOBAL="$CLIENT_GITCONFIG" GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="$ssh_cmd" "$@"
}

url() {
  printf 'ssh://%s@localhost:%s/%s' "$GL_USER" "$SSH_PORT" "$1"
}

# expect_push allow|deny KEYNAME REFSPEC REPO
expect_push() {
  local expected=$1 key=$2 refspec=$3 repo=$4 out result
  if out=$(client_as "$key" git -C "$WORK" push --porcelain "$(url "$repo")" "$refspec" 2>&1); then
    [[ $out != *'[up to date]'* ]] || {
      printf '  %s pushing %s changed nothing, so it tests nothing\n' "$key" "$refspec"
      return 1
    }
    result=allow
  else
    result=deny
    [[ $out == *DENIED* ]] || {
      printf '  %s pushing %s failed without a Gitolite denial:\n%s\n' "$key" "$refspec" "$out"
      return 1
    }
  fi
  [[ $result == "$expected" ]] || {
    printf '  %s pushing %s: expected %s, got %s\n%s\n' "$key" "$refspec" "$expected" "$result" "$out"
    return 1
  }
  printf '  %-5s %-10s %s\n' "$result" "$key" "$refspec"
}

config_checksums() {
  sha256sum "$PORT_DROPIN" "$HARDENING_DROPIN" "$LIMITS_DROPIN" \
    "$GL_HOME/.ssh/authorized_keys" "$GL_HOME/.gitconfig"
}

# ---------------------------------------------------------------------------

test_install() {
  local out effective all
  out=$("$SCRIPT" install \
    --admin-key "$KEYS/admin.pub" \
    --admin-name arthur-admin \
    --ssh-port "$SSH_PORT" \
    --default-branch trunk \
    --max-startups 50:30:200 2>&1)
  printf '%s\n' "$out"
  assert_contains "$out" 'Installation complete.'
  assert_contains "$out" "]:$SSH_PORT ssh-ed25519 " 'install must print known_hosts lines'
  if [[ ! -d /run/systemd/system ]]; then
    assert_contains "$out" 'systemd is not running'
  fi

  # sshd configuration. Capture the output first: with pipefail,
  # "sshd -T | grep -q" can fail when grep stops reading early.
  all=$(sshd -T)
  grep -qx "port $SSH_PORT" <<<"$all"
  grep -qx 'maxstartups 50:30:200' <<<"$all"
  effective=$(sshd -T -C "user=$GL_USER,host=localhost,addr=127.0.0.1")
  grep -qx 'acceptenv GIT_PROTOCOL' <<<"$effective"
  grep -qx 'permittty no' <<<"$effective"
  grep -qx 'passwordauthentication no' <<<"$effective"
  grep -qx 'allowtcpforwarding no' <<<"$effective"

  # hosting account and Gitolite
  assert_eq 'refs/heads/master' \
    "$(as_git git -C "$GL_HOME/repositories/gitolite-admin.git" symbolic-ref HEAD)"
  as_git git -C "$GL_HOME/repositories/gitolite-admin.git" show-ref --verify --quiet refs/heads/master
  assert_eq 'trunk' "$(as_git git config --global --get init.defaultBranch)"
  assert_eq 'always' "$(as_git git config --global --get core.logAllRefUpdates)"
  assert_eq 'L' "$(passwd -S "$GL_USER" | awk '{print $2}')"
}

test_second_install_changes_nothing() {
  local before after out
  before=$(config_checksums)
  if out=$("$SCRIPT" install \
    --admin-key "$KEYS/other.pub" \
    --admin-name someone-else \
    --ssh-port 2200 \
    --default-branch other \
    --max-startups 5 2>&1); then
    printf '  a second install did not fail\n'
    return 1
  fi
  printf '%s\n' "$out"
  assert_contains "$out" 'refusing to overwrite'
  after=$(config_checksums)
  assert_eq "$before" "$after" 'a refused install must not change any configuration'
}

test_real_ssh_and_protocol_v2() {
  local out i
  # sshd reads the system configuration, including the new drop-ins.
  mkdir -p /run/sshd
  /usr/sbin/sshd -o "PidFile=$SSHD_PID_FILE"
  for ((i = 0; i < 50; i++)); do
    [[ -s $SSHD_PID_FILE ]] && break
    sleep 0.1
  done

  # The port is read from sshd, so only --host is given.
  "$SCRIPT" host-keys --host localhost | sed -n '/^known_hosts lines/,$p' | tail -n +2 >"$KNOWN_HOSTS"
  grep -q "^\\[localhost\\]:$SSH_PORT ssh-ed25519 " "$KNOWN_HOSTS"

  out=$(ssh_as admin "$GL_USER@localhost" info)
  printf '%s\n' "$out"
  assert_contains "$out" 'hello arthur-admin'
  assert_contains "$out" 'gitolite-admin'

  out=$(GIT_TRACE_PACKET=1 client_as admin git -c protocol.version=2 ls-remote "$(url gitolite-admin)" 2>&1)
  assert_contains "$out" 'version 2' 'Git must use protocol v2 over SSH'
}

test_admin_workflow_over_ssh() {
  local name out
  for name in arthur agent-e2e; do
    ssh-keygen -q -t ed25519 -N '' -C "$name" -f "$KEYS/$name"
  done
  client_as admin git clone --quiet "$(url gitolite-admin)" "$ADMIN"
  assert_eq 'master' "$(git -C "$ADMIN" branch --show-current)"

  client_as admin "$SCRIPT" admin-init --admin-dir "$ADMIN"
  client_as admin "$SCRIPT" user-add --admin-dir "$ADMIN" --name arthur --key "$KEYS/arthur.pub"
  client_as admin "$SCRIPT" user-add --admin-dir "$ADMIN" --name agent-e2e --key "$KEYS/agent-e2e.pub"
  client_as admin "$SCRIPT" repo-set --admin-dir "$ADMIN" \
    --repo project-e2e \
    --owner arthur \
    --agents agent-e2e \
    --protected-branch trunk
  client_as admin "$SCRIPT" apply --admin-dir "$ADMIN" -m 'Add project-e2e'

  [[ -d "$GL_HOME/repositories/project-e2e.git" ]]
  assert_eq 'refs/heads/trunk' "$(as_git git -C "$GL_HOME/repositories/project-e2e.git" symbolic-ref HEAD)"
  out=$(ssh_as agent-e2e "$GL_USER@localhost" info)
  assert_contains "$out" 'hello agent-e2e'

  git init --quiet -b trunk "$WORK"
  git -C "$WORK" -c user.name=Test -c user.email=test@example.invalid commit --quiet --allow-empty -m first
  expect_push allow arthur 'trunk:refs/heads/trunk' project-e2e
  git -C "$WORK" -c user.name=Test -c user.email=test@example.invalid commit --quiet --allow-empty -m second
  expect_push allow agent-e2e 'HEAD:refs/heads/agent/agent-e2e/issue-1' project-e2e
  expect_push deny  agent-e2e 'HEAD:refs/heads/trunk' project-e2e
  expect_push deny  agent-e2e 'HEAD:refs/tags/v1' project-e2e
  expect_push allow arthur    'HEAD:refs/tags/v1' project-e2e
}

test_doctor_status_backup() {
  local out backup_dir
  out=$(: | timeout 120 "$SCRIPT" doctor || true)
  printf '%s\n' "$out"
  assert_contains "$out" "[ OK ] gitolite-admin uses the 'master' branch"
  assert_contains "$out" "[ OK ] sshd accepts GIT_PROTOCOL for $GL_USER"
  assert_contains "$out" '[ OK ] hosted repositories keep reflogs'
  assert_contains "$out" '[ OK ] managed SSH port drop-in is installed'
  assert_contains "$out" '[ OK ] SSH hardening drop-in is installed'
  assert_contains "$out" '[ OK ] all non-comment authorized_keys entries have forced commands'
  assert_contains "$out" '[ OK ] hosting account password is locked'
  assert_contains "$out" '[ OK ] gitolite sshkeys-lint passed'

  out=$("$SCRIPT" status)
  printf '%s\n' "$out"
  grep -Eq "^SSH ports: +$SSH_PORT\$" <<<"$out"
  grep -Eq '^Default branch: +trunk$' <<<"$out"
  grep -Eq '^SSH MaxStartups: +50:30:200$' <<<"$out"

  out=$("$SCRIPT" backup --output "$TMP/backups")
  backup_dir=$(printf '%s\n' "$out" | tail -n 1)
  grep -qx 'failed=0' "$backup_dir/meta/manifest.txt"
  grep -Eq '^gitolite_version=3\.' "$backup_dir/meta/manifest.txt"
  [[ -d "$backup_dir/repos/project-e2e.git" && -d "$backup_dir/repos/gitolite-admin.git" ]]
  [[ -f "$backup_dir/meta/$(basename "$LIMITS_DROPIN")" ]]
}

test_ssh_limits() {
  local out before
  out=$("$SCRIPT" ssh-limits)
  assert_eq "MaxStartups: 50:30:200 ($LIMITS_DROPIN)" "$out"

  "$SCRIPT" ssh-limits --max-startups 20
  assert_eq '20:30:20' "$(sshd -T | awk '$1 == "maxstartups" {print $2}')"

  # sshd would reject this value; nothing may change.
  before=$(sha256sum "$LIMITS_DROPIN")
  if "$SCRIPT" ssh-limits --max-startups 100:30:10; then
    printf '  an invalid value was accepted\n'
    return 1
  fi
  assert_eq "$before" "$(sha256sum "$LIMITS_DROPIN")"

  # A MaxStartups line after the Include line of sshd_config overrides the
  # drop-in. ssh-limits must notice it and restore the previous file.
  printf 'MaxStartups 9:30:90 # mini-git-server test\n' >>/etc/ssh/sshd_config
  if out=$("$SCRIPT" ssh-limits --max-startups 50:30:200 2>&1); then
    printf '  an overridden value was accepted\n'
    return 1
  fi
  printf '%s\n' "$out"
  assert_contains "$out" 'overrides'
  assert_eq "$before" "$(sha256sum "$LIMITS_DROPIN")" 'the previous drop-in must be restored'
  sed -i '/# mini-git-server test$/d' /etc/ssh/sshd_config

  "$SCRIPT" ssh-limits --reset
  [[ ! -e $LIMITS_DROPIN ]]
  assert_eq '10:30:100' "$(sshd -T | awk '$1 == "maxstartups" {print $2}')"
}

# ---------------------------------------------------------------------------

mkdir -p "$KEYS"
chmod 0700 "$TMP"
ssh-keygen -q -t ed25519 -N '' -C admin -f "$KEYS/admin"
ssh-keygen -q -t ed25519 -N '' -C other -f "$KEYS/other"
cat >"$CLIENT_GITCONFIG" <<'CONF'
[user]
	name = Install Test
	email = install-test@example.invalid
CONF
# install runs "sshd -t", which needs this directory. On a normal Debian
# host the ssh service creates it; a container may not have it.
mkdir -p /run/sshd
# Run from a directory the hosting account cannot read, like /root.
cd "$TMP"

step 'install sets up sshd, the hosting account and Gitolite' test_install
step 'a second install is refused and changes nothing' test_second_install_changes_nothing
step 'real SSH works with the printed host keys, using Git protocol v2' test_real_ssh_and_protocol_v2
step 'the admin workflow and access rules work over SSH' test_admin_workflow_over_ssh
step 'doctor, status and backup report the installed server correctly' test_doctor_status_backup
step 'ssh-limits sets, checks and resets MaxStartups' test_ssh_limits

printf '\n%d passed, 0 failed\n' "$PASS"
