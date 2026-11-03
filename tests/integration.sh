#!/usr/bin/env bash
# Integration tests against a real Gitolite installation.
#
# Requirements: root, gitolite3, git, ssh-keygen, runuser and useradd.
#
# The tests create a temporary hosting account and remove it afterwards.
# They do not start sshd and do not change the system SSH configuration:
# tests/fake-ssh runs each key's forced command from the Gitolite
# authorized_keys file, the same way sshd would.
#
# The steps depend on each other, so the run stops at the first failure
# and prints the end of the log.
set -Eeuo pipefail
IFS=$'\n\t'

# Ignore Git settings from the caller's environment (for example
# GIT_CONFIG_COUNT), so the results do not depend on who runs the tests.
while IFS= read -r var; do
  [[ $var == GIT_* ]] && unset "$var"
done < <(compgen -e)

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/mini-git-server.sh"
FAKE_SSH="$ROOT_DIR/tests/fake-ssh"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'Integration tests must run as root (try: sudo make test-integration).\n' >&2
  exit 1
fi
for cmd in git gitolite ssh-keygen runuser useradd userdel timeout; do
  command -v "$cmd" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$cmd" >&2
    exit 1
  }
done

GL_USER="mgs-it-$$"
if id "$GL_USER" >/dev/null 2>&1; then
  printf 'User %s already exists; refusing to touch it.\n' "$GL_USER" >&2
  exit 1
fi

TMP=$(mktemp -d)
LOG="$TMP/test.log"
KEYS="$TMP/keys"
ADMIN="$TMP/gitolite-admin"
WORK="$TMP/work"
CLIENT_GITCONFIG="$TMP/client.gitconfig"
GL_HOME=""
CREATED_USER=0
CURRENT_STEP="setup"
PASS=0

# Keep the original stderr: the EXIT trap may run while a step's output is
# still redirected to the log.
exec 3>&2

cleanup() {
  if (( CREATED_USER )); then
    userdel -r "$GL_USER" >/dev/null 2>&1 || true
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

# Run a client-side command (an admin workstation or an agent host). Git uses
# an isolated configuration and reaches Gitolite through tests/fake-ssh.
client() {
  local ssh_cmd
  printf -v ssh_cmd '%q' "$FAKE_SSH"
  env GIT_CONFIG_GLOBAL="$CLIENT_GITCONFIG" GIT_CONFIG_NOSYSTEM=1 \
    GIT_SSH_COMMAND="$ssh_cmd" GIT_SSH_VARIANT=simple \
    MGS_IT_GIT_USER="$GL_USER" MGS_IT_GIT_HOME="$GL_HOME" MGS_IT_KEYS="$KEYS" \
    "$@"
}

# expect_push allow|deny KEYNAME REFSPEC
# A denial only counts when Gitolite itself reports it, so a broken test
# harness cannot make the ACL checks pass.
expect_push() {
  local expected=$1 key=$2 refspec=$3 out result
  if out=$(client git -C "$WORK" push --quiet "as-$key:project-x" "$refspec" 2>&1); then
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
  printf '  %-5s %-11s %s\n' "$result" "$key" "$refspec"
}

refs_of() {
  git -C "$1" for-each-ref --format='%(objectname) %(refname)'
}

# ---------------------------------------------------------------------------

test_init_keeps_admin_repo_on_master() {
  # The installer accepts an existing hosting account. Create one whose own
  # Git configuration already names another default branch: setup must still
  # put gitolite-admin on master. The account did not exist when the run
  # started, so cleanup removes it even if setup fails halfway.
  CREATED_USER=1
  useradd --create-home --shell /bin/bash "$GL_USER"
  GL_HOME=$(getent passwd "$GL_USER" | cut -d: -f6)
  as_git git config --global init.defaultBranch main

  # Run from a directory the hosting account cannot read, like /root.
  (
    # shellcheck source=/dev/null
    source "$SCRIPT"
    init_hosting_account "$GL_USER" "$KEYS/admin.pub" arthur-admin trunk
  )

  local admin_repo="$GL_HOME/repositories/gitolite-admin.git"
  assert_eq 'refs/heads/master' "$(as_git git -C "$admin_repo" symbolic-ref HEAD)" \
    'gitolite-admin must stay on master even with --default-branch'
  as_git git -C "$admin_repo" show-ref --verify --quiet refs/heads/master
  assert_eq 'trunk' "$(as_git git config --global --get init.defaultBranch)" \
    '--default-branch must apply to new repositories'
}

test_server_commands_from_unreadable_directory() {
  local out
  out=$("$SCRIPT" status --git-user "$GL_USER")
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -Eq '^Default branch: +trunk$'

  # doctor exits non-zero on hosts without a running sshd; only the
  # Gitolite checks matter here. The pipe on stdin used to make it hang.
  out=$(: | timeout 120 "$SCRIPT" doctor --git-user "$GL_USER" || true)
  printf '%s\n' "$out"
  assert_contains "$out" "[ OK ] gitolite-admin uses the 'master' branch"
  assert_contains "$out" '[ OK ] gitolite sshkeys-lint passed'
}

test_doctor_lints_authorized_keys_without_terminal() {
  # Add the admin key a second time without a forced command. sshkeys-lint
  # must report it even though stdin is not a terminal. (It used to read
  # stdin instead of authorized_keys, and passed without checking anything.)
  local authkeys="$GL_HOME/.ssh/authorized_keys" out
  cp -p "$authkeys" "$TMP/authorized_keys.orig"
  awk 'NF {print $1, $2}' "$KEYS/admin.pub" >>"$authkeys"

  out=$(timeout 120 "$SCRIPT" doctor --git-user "$GL_USER" </dev/null || true)
  cp -p "$TMP/authorized_keys.orig" "$authkeys"
  printf '%s\n' "$out"
  assert_contains "$out" '[WARN] gitolite sshkeys-lint returned a non-zero status'
}

test_admin_workflow_is_applied() {
  local name
  for name in arthur agent-impl agent-fix dev1 ci; do
    ssh-keygen -q -t ed25519 -N '' -C "$name" -f "$KEYS/$name"
  done

  client git clone --quiet as-admin:gitolite-admin "$ADMIN"
  assert_eq 'master' "$(git -C "$ADMIN" branch --show-current)"

  client "$SCRIPT" admin-init --admin-dir "$ADMIN"
  # Daily identity, separate from the admin identity arthur-admin.
  client "$SCRIPT" user-add --admin-dir "$ADMIN" --name arthur --key "$KEYS/arthur.pub"
  client "$SCRIPT" user-add --admin-dir "$ADMIN" --name agent-impl --key "$KEYS/agent-impl.pub" --key-id host1
  client "$SCRIPT" user-add --admin-dir "$ADMIN" --name agent-fix --key "$KEYS/agent-fix.pub" --key-id host1
  client "$SCRIPT" user-add --admin-dir "$ADMIN" --name dev1 --key "$KEYS/dev1.pub"
  client "$SCRIPT" user-add --admin-dir "$ADMIN" --name ci --key "$KEYS/ci.pub"
  client "$SCRIPT" repo-set --admin-dir "$ADMIN" \
    --repo project-x \
    --owner arthur \
    --writers dev1 \
    --agents agent-impl,agent-fix \
    --readers ci \
    --protected-branch trunk
  client "$SCRIPT" apply --admin-dir "$ADMIN" -m 'Add project-x and agents'

  # Gitolite applied the push: the repository exists and the keys work.
  local repo="$GL_HOME/repositories/project-x.git" out
  [[ -d $repo ]] || { printf '  project-x.git was not created\n'; return 1; }
  assert_eq 'refs/heads/trunk' "$(as_git git -C "$repo" symbolic-ref HEAD)" \
    'new repositories must use --default-branch'
  out=$(client "$FAKE_SSH" as-agent-impl info)
  printf '%s\n' "$out"
  assert_contains "$out" 'hello agent-impl'
  assert_contains "$out" 'project-x'
}

test_gitolite_enforces_agent_acl() {
  git init --quiet -b trunk "$WORK"
  git -C "$WORK" -c user.name=Test -c user.email=test@example.invalid \
    commit --quiet --allow-empty -m 'first'
  expect_push allow arthur 'trunk:refs/heads/trunk'

  git -C "$WORK" -c user.name=Test -c user.email=test@example.invalid \
    commit --quiet --allow-empty -m 'second'

  # Agents may only write to agent/<their name>/, without rewinds or deletes.
  expect_push deny  agent-impl 'HEAD:refs/heads/trunk'
  expect_push deny  agent-impl 'HEAD:refs/heads/feature'
  expect_push deny  agent-impl 'HEAD:refs/tags/v1'
  expect_push deny  agent-impl 'HEAD:refs/heads/agent/agent-fix/issue-42'
  expect_push allow agent-impl 'HEAD:refs/heads/agent/agent-impl/issue-42'
  git -C "$WORK" -c user.name=Test -c user.email=test@example.invalid \
    commit --quiet --amend --allow-empty -m 'second, rewritten'
  expect_push deny  agent-impl '+HEAD:refs/heads/agent/agent-impl/issue-42'
  expect_push deny  agent-impl ':refs/heads/agent/agent-impl/issue-42'
  expect_push allow agent-fix  'HEAD:refs/heads/agent/agent-fix/issue-7'

  # Writers may write anywhere except the protected branch.
  expect_push deny  dev1 'HEAD:refs/heads/trunk'
  expect_push allow dev1 'HEAD:refs/heads/feature'

  # Readers can fetch but not push.
  expect_push deny  ci 'HEAD:refs/heads/ci-result'
  client git ls-remote as-ci:project-x refs/heads/trunk | grep -q 'refs/heads/trunk'

  # The owner may rewind the protected branch.
  expect_push allow arthur '+HEAD:refs/heads/trunk'

  # The admin identity has no access to project repositories at all.
  expect_push deny admin 'HEAD:refs/heads/admin-test'
}

test_fsck_checks_every_repository() {
  "$SCRIPT" fsck --git-user "$GL_USER"
}

test_backup_mirrors_every_repository() {
  local out backup_dir repo rel mirror
  out=$("$SCRIPT" backup --git-user "$GL_USER" --output "$TMP/backups")
  backup_dir=$(printf '%s\n' "$out" | tail -n 1)
  [[ -d $backup_dir/repos ]] || { printf '  backup directory missing: %s\n' "$backup_dir"; return 1; }
  grep -qx 'failed=0' "$backup_dir/meta/manifest.txt"

  for repo in gitolite-admin testing project-x; do
    rel="$repo.git"
    mirror="$backup_dir/repos/$rel"
    [[ -d $mirror ]] || { printf '  mirror missing: %s\n' "$rel"; return 1; }
    assert_eq "$(as_git git -C "$GL_HOME/repositories/$rel" for-each-ref --format='%(objectname) %(refname)')" \
      "$(refs_of "$mirror")" "refs differ for $rel"
    assert_eq 'root' "$(stat -c '%U' "$mirror")" "mirror $rel must be owned by root"
  done
  assert_eq 'refs/heads/trunk' "$(git -C "$backup_dir/repos/project-x.git" symbolic-ref HEAD)"
}

test_doctor_detects_and_repo_set_default_repairs_admin_branch() {
  local admin_repo="$GL_HOME/repositories/gitolite-admin.git" out
  as_git git -C "$admin_repo" symbolic-ref HEAD refs/heads/trunk

  out=$(timeout 120 "$SCRIPT" doctor --git-user "$GL_USER" </dev/null || true)
  printf '%s\n' "$out"
  assert_contains "$out" "[FAIL] gitolite-admin HEAD is 'refs/heads/trunk'"

  "$SCRIPT" repo-set-default --repo gitolite-admin --branch master --git-user "$GL_USER"
  out=$(timeout 120 "$SCRIPT" doctor --git-user "$GL_USER" </dev/null || true)
  printf '%s\n' "$out"
  assert_contains "$out" "[ OK ] gitolite-admin uses the 'master' branch"
}

# ---------------------------------------------------------------------------

mkdir -p "$KEYS" "$TMP/private"
chmod 0700 "$TMP" "$TMP/private"
ssh-keygen -q -t ed25519 -N '' -C admin -f "$KEYS/admin"
cat >"$CLIENT_GITCONFIG" <<'CONF'
[user]
	name = Integration Test
	email = integration@example.invalid
CONF

# Run everything from a directory the hosting account cannot read, so the
# tests also catch commands that depend on the caller's current directory.
cd "$TMP/private"

step 'install keeps gitolite-admin on master with --default-branch' test_init_keeps_admin_repo_on_master
step 'status and doctor work from a directory the hosting account cannot read' test_server_commands_from_unreadable_directory
step 'doctor lints authorized_keys when stdin is not a terminal' test_doctor_lints_authorized_keys_without_terminal
step 'documented admin workflow is applied by Gitolite' test_admin_workflow_is_applied
step 'Gitolite enforces the generated agent, writer and reader ACL' test_gitolite_enforces_agent_acl
step 'fsck checks every repository' test_fsck_checks_every_repository
step 'backup mirrors every repository as root' test_backup_mirrors_every_repository
step 'doctor detects a wrong admin branch and repo-set-default repairs it' test_doctor_detects_and_repo_set_default_repairs_admin_branch

printf '\n%d passed, 0 failed\n' "$PASS"
