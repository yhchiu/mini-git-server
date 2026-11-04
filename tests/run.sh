#!/usr/bin/env bash
# Test functions are intentionally invoked indirectly by run_test.
# shellcheck disable=SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/mini-git-server.sh"

PASS=0
FAIL=0
SKIP=0
CURRENT_TMP=""

cleanup() {
  if [[ -n ${CURRENT_TMP:-} && -d $CURRENT_TMP ]]; then
    rm -rf "$CURRENT_TMP"
  fi
}
trap cleanup EXIT

pass() {
  printf 'ok - %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local expected=$1 actual=$2 msg=${3:-"values differ"}
  [[ $actual == "$expected" ]] || {
    printf '  %s\n  expected: %q\n  actual:   %q\n' "$msg" "$expected" "$actual" >&2
    exit 1
  }
}

assert_contains() {
  local haystack=$1 needle=$2 msg=${3:-"missing expected text"}
  [[ $haystack == *"$needle"* ]] || {
    printf '  %s\n  missing: %s\n' "$msg" "$needle" >&2
    exit 1
  }
}

assert_not_contains() {
  local haystack=$1 needle=$2 msg=${3:-"unexpected text found"}
  [[ $haystack != *"$needle"* ]] || {
    printf '  %s\n  unexpected: %s\n' "$msg" "$needle" >&2
    exit 1
  }
}

new_tmp() {
  cleanup
  CURRENT_TMP=$(mktemp -d)
  printf '%s\n' "$CURRENT_TMP"
}

new_admin_repo() {
  local dir=$1
  mkdir -p "$dir/conf" "$dir/keydir"
  git -C "$dir" init -q -b master
  git -C "$dir" config user.name "Test User"
  git -C "$dir" config user.email "test@example.invalid"
  cat > "$dir/conf/gitolite.conf" <<'CONF'
repo gitolite-admin
    RW+ = admin

repo testing
    RW+ = @all
CONF
  touch "$dir/keydir/.gitkeep"
  git -C "$dir" add .
  git -C "$dir" commit -qm "Initial admin repo"
}


# Create a fake ssh-keygen in TMP/bin and print that directory. Tests use it
# to check key placement without needing openssh-client.
fake_ssh_keygen() {
  local tmp=$1
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/ssh-keygen" <<'SH'
#!/usr/bin/env sh
if [ "${1:-}" = "-l" ] || [ "${1:-}" = "-lf" ]; then
  echo "256 SHA256:test test@example.invalid (ED25519)"
  exit 0
fi
exit 0
SH
  chmod +x "$tmp/bin/ssh-keygen"
  printf '%s\n' "$tmp/bin"
}

# Run one test function in a subshell and record the result.
#
# The test must not run as the condition of an "if" (as in
# "if ( "$fn" ); then"): Bash turns errexit off there, so a failing check in
# the middle of a test would be ignored and only the last command would
# count. Instead, run it as a plain command with errexit switched on inside
# the subshell, and read its exit status afterwards.
run_test() {
  local name=$1 fn=$2 rc
  set +e
  ( set -e; "$fn" )
  rc=$?
  set -e
  if (( rc == 0 )); then
    pass "$name"
  else
    fail "$name"
  fi
}

# Like run_test, but skip the test when a command it needs is not
# installed. CI installs all of them, so there every test runs.
run_test_needing() {
  local name=$1 fn=$2 cmd
  shift 2
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'ok - %s # SKIP %s is not installed\n' "$name" "$cmd"
      SKIP=$((SKIP + 1))
      return 0
    fi
  done
  run_test "$name" "$fn"
}

test_run_test_catches_a_failed_check_in_the_middle() {
  fails_in_the_middle() {
    [[ -e /nonexistent/mini-git-server-test ]]
    true
  }
  local out
  # Run in a command substitution, so the inner result does not change the
  # pass/fail counters of this test run.
  out=$(run_test 'inner test' fails_in_the_middle 2>&1)
  assert_contains "$out" 'not ok - inner test'
}

test_bash_syntax() {
  bash -n "$SCRIPT"
}

test_version() {
  local out
  out=$("$SCRIPT" version)
  assert_contains "$out" "0.3.0"
}

test_branch_refex_exact_escaping() {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  local actual
  actual=$(branch_refex_exact 'release/1.2+hotfix')
  assert_eq 'refs/heads/release/1\.2\+hotfix$' "$actual"
}

test_repo_fragment_name() {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  local actual
  actual=$(repo_fragment_name 'team/project')
  assert_eq 'team%2Fproject' "$actual"
}

test_validate_port() {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  validate_port 22
  validate_port 65535
  if ( validate_port 0 ) >/dev/null 2>&1; then return 1; fi
  if ( validate_port 65536 ) >/dev/null 2>&1; then return 1; fi
  if ( validate_port abc ) >/dev/null 2>&1; then return 1; fi
}

test_admin_init_idempotent() {
  local tmp repo count
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"

  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null

  count=$(grep -Fxc 'include "repos/*.conf"' "$repo/conf/gitolite.conf")
  assert_eq 1 "$count"
  [[ -f "$repo/conf/repos/.gitkeep" ]]
}

test_repo_set_acl_and_no_hardcoded_main() {
  local tmp repo fragment content
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null

  "$SCRIPT" repo-set \
    --admin-dir "$repo" \
    --repo 'team/project' \
    --owner arthur \
    --writers developer1 \
    --agents 'agent-impl,agent-fix' \
    --readers 'agent-review,ci' >/dev/null

  fragment="$repo/conf/repos/team%2Fproject.conf"
  content=$(<"$fragment")
  assert_contains "$content" 'RW+                         =   arthur'
  assert_contains "$content" 'RW                          =   developer1'
  assert_contains "$content" 'RW      agent/USER/         =   agent-impl agent-fix'
  assert_contains "$content" 'R                           =   agent-impl agent-fix agent-review ci'
  assert_not_contains "$content" 'RW+     agent/USER/'
  assert_not_contains "$content" 'refs/heads/main$'
}

test_protected_branch_exact_and_escaped() {
  local tmp repo fragment content
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null

  "$SCRIPT" repo-set \
    --admin-dir "$repo" \
    --repo project-x \
    --owner arthur \
    --writers developer1 \
    --agents agent-impl \
    --protected-branch trunk \
    --protected-branch 'release/1.2' >/dev/null

  fragment="$repo/conf/repos/project-x.conf"
  content=$(<"$fragment")
  assert_contains "$content" 'refs/heads/trunk$'
  assert_contains "$content" 'refs/heads/release/1\.2$'
  assert_contains "$content" '=   developer1 agent-impl'
}

test_multi_device_user_key_layout() {
  local tmp repo key fakebin
  tmp=$(new_tmp)
  repo="$tmp/admin"
  key="$tmp/arthur.pub"
  fakebin="$tmp/bin"
  new_admin_repo "$repo"

  # This test verifies key placement and logical-user mapping, not OpenSSH's
  # key parser. Mock ssh-keygen so the suite does not require openssh-client.
  mkdir -p "$fakebin"
  cat > "$fakebin/ssh-keygen" <<'SH'
#!/usr/bin/env sh
if [ "${1:-}" = "-l" ]; then
  echo "256 SHA256:test test@example.invalid (ED25519)"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/ssh-keygen"
  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixture test@example.invalid' > "$key"

  PATH="$fakebin:$PATH" "$SCRIPT" user-add \
    --admin-dir "$repo" \
    --name arthur \
    --key "$key" \
    --key-id notebook >/dev/null

  [[ -f "$repo/keydir/notebook/arthur.pub" ]]
  cmp -s "$key" "$repo/keydir/notebook/arthur.pub"
}

test_repo_list_includes_fragments() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null
  "$SCRIPT" repo-set --admin-dir "$repo" --repo alpha --owner arthur >/dev/null
  "$SCRIPT" repo-set --admin-dir "$repo" --repo 'team/beta' --owner arthur >/dev/null

  out=$("$SCRIPT" repo-list --admin-dir "$repo")
  assert_contains "$out" 'alpha'
  assert_contains "$out" 'team/beta'
  assert_contains "$out" 'gitolite-admin'
}


test_repo_set_replaces_complete_desired_state() {
  local tmp repo fragment content
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null

  "$SCRIPT" repo-set \
    --admin-dir "$repo" \
    --repo project-x \
    --owner arthur \
    --writers developer1 \
    --agents agent-impl \
    --readers agent-review \
    --protected-branch trunk >/dev/null

  "$SCRIPT" repo-set \
    --admin-dir "$repo" \
    --repo project-x \
    --owner arthur \
    --writers developer2 >/dev/null

  fragment="$repo/conf/repos/project-x.conf"
  content=$(<"$fragment")
  assert_contains "$content" 'RW                          =   developer2'
  assert_not_contains "$content" 'developer1'
  assert_not_contains "$content" 'agent-impl'
  assert_not_contains "$content" 'agent-review'
  assert_not_contains "$content" 'refs/heads/trunk$'
}

test_repo_add_is_repo_set_alias() {
  local tmp repo fragment content
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null

  "$SCRIPT" repo-add \
    --admin-dir "$repo" \
    --repo alias-project \
    --owner arthur \
    --readers ci >/dev/null

  fragment="$repo/conf/repos/alias-project.conf"
  content=$(<"$fragment")
  assert_contains "$content" '# mini-git-server: owner=arthur'
  assert_contains "$content" '# mini-git-server: readers=ci'
}

test_repo_show_outputs_state_and_reusable_command() {
  local tmp repo out raw
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null

  "$SCRIPT" repo-set \
    --admin-dir "$repo" \
    --repo 'team/project' \
    --owner arthur \
    --writers 'developer1,developer2' \
    --agents 'agent-impl,agent-fix' \
    --readers 'agent-review,ci' \
    --protected-branch trunk \
    --protected-branch 'release/1.2' >/dev/null

  out=$("$SCRIPT" repo-show --admin-dir "$repo" --repo 'team/project')
  assert_contains "$out" 'Repository: team/project'
  assert_contains "$out" 'Owner: arthur'
  assert_contains "$out" 'Writers: developer1 developer2'
  assert_contains "$out" 'Agents: agent-impl agent-fix'
  assert_contains "$out" 'Readers: agent-review ci'
  assert_contains "$out" '  - trunk'
  assert_contains "$out" '  - release/1.2'
  assert_contains "$out" 'repo-set'
  assert_contains "$out" '--writers'
  assert_contains "$out" '--writers developer1,developer2'
  assert_contains "$out" '--admin-dir'

  raw=$("$SCRIPT" repo-show --admin-dir "$repo" --repo 'team/project' --raw)
  assert_contains "$raw" 'repo team/project'
  assert_contains "$raw" '# mini-git-server: agents=agent-impl agent-fix'
}

test_repo_show_parses_legacy_fragment() {
  local tmp repo fragment out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null
  fragment="$repo/conf/repos/legacy.conf"
  cat >"$fragment" <<'CONF'
# Managed by mini-git-server.sh
# Repository: legacy
repo legacy
    RW+                         =   arthur
    -       refs/heads/release/1\.2$ =   developer1 agent-impl
    RW                          =   developer1
    RW      agent/USER/         =   agent-impl
    R                           =   agent-impl agent-review ci
CONF

  out=$("$SCRIPT" repo-show --admin-dir "$repo" --repo legacy)
  assert_contains "$out" 'Owner: arthur'
  assert_contains "$out" 'Writers: developer1'
  assert_contains "$out" 'Agents: agent-impl'
  assert_contains "$out" 'Readers: agent-review ci'
  assert_contains "$out" '  - release/1.2'
}

test_apply_no_push_commits_staged_changes() {
  local tmp repo before after
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  before=$(git -C "$repo" rev-parse HEAD)
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null
  "$SCRIPT" apply --admin-dir "$repo" --no-push -m 'Initialize managed ACLs' >/dev/null
  after=$(git -C "$repo" rev-parse HEAD)
  [[ $before != "$after" ]]
  assert_eq 'Initialize managed ACLs' "$(git -C "$repo" log -1 --format=%s)"
}

test_apply_refuses_branch_other_than_master() {
  local tmp repo before out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  git -C "$repo" switch -q -c trunk
  before=$(git -C "$repo" rev-parse HEAD)
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null

  if out=$("$SCRIPT" apply --admin-dir "$repo" --no-push -m 'wrong branch' 2>&1); then
    return 1
  fi
  assert_contains "$out" "only applies changes pushed to 'master'"
  assert_eq "$before" "$(git -C "$repo" rev-parse HEAD)" 'apply must not commit on the wrong branch'
}

test_apply_refuses_detached_head() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  git -C "$repo" switch -q --detach
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null

  if out=$("$SCRIPT" apply --admin-dir "$repo" --no-push 2>&1); then
    return 1
  fi
  assert_contains "$out" 'detached HEAD'
}

test_repo_set_default_unborn_branch() {
  local tmp home bare actual
  tmp=$(new_tmp)
  home="$tmp/git-home"
  bare="$home/repositories/project-x.git"
  mkdir -p "$(dirname "$bare")"
  git init --bare -q "$bare"

  (
    # shellcheck source=/dev/null
    source "$SCRIPT"
    require_root() { :; }
    id() { return 0; }
    getent() {
      if [[ ${1:-} == passwd ]]; then
        printf 'git:x:1000:1000::%s:/usr/bin/git-shell\n' "$home"
        return 0
      fi
      return 1
    }
    runuser() {
      [[ ${1:-} == -u ]] || return 2
      shift 3
      "$@"
    }
    server_repo_set_default --repo project-x --branch trunk --git-user git >/dev/null
  )

  actual=$(git -C "$bare" symbolic-ref HEAD)
  assert_eq 'refs/heads/trunk' "$actual"
}

test_repo_set_default_require_existing_rejects_missing() {
  local tmp home bare
  tmp=$(new_tmp)
  home="$tmp/git-home"
  bare="$home/repositories/project-x.git"
  mkdir -p "$(dirname "$bare")"
  git init --bare -q "$bare"

  if (
    # shellcheck source=/dev/null
    source "$SCRIPT"
    require_root() { :; }
    id() { return 0; }
    getent() {
      if [[ ${1:-} == passwd ]]; then
        printf 'git:x:1000:1000::%s:/usr/bin/git-shell\n' "$home"
        return 0
      fi
      return 1
    }
    runuser() {
      [[ ${1:-} == -u ]] || return 2
      shift 3
      "$@"
    }
    server_repo_set_default --repo project-x --branch trunk --git-user git --require-existing
  ) >/dev/null 2>&1; then
    return 1
  fi
}

test_repo_set_default_keeps_admin_repo_on_master() {
  local tmp home bare out
  tmp=$(new_tmp)
  home="$tmp/git-home"
  bare="$home/repositories/gitolite-admin.git"
  mkdir -p "$(dirname "$bare")"
  git init --bare -q -b master "$bare"

  if out=$(
    # shellcheck source=/dev/null
    source "$SCRIPT"
    require_root() { :; }
    id() { return 0; }
    getent() {
      printf 'git:x:1000:1000::%s:/usr/bin/git-shell\n' "$home"
    }
    runuser() {
      shift 3
      "$@"
    }
    server_repo_set_default --repo gitolite-admin --branch trunk --git-user git 2>&1
  ); then
    return 1
  fi
  assert_contains "$out" "gitolite-admin must use the 'master' branch"
  assert_eq 'refs/heads/master' "$(git -C "$bare" symbolic-ref HEAD)"
}

test_gitolite_user_for_keyfile_matches_gitolite() {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  assert_eq 'arthur' "$(gitolite_user_for_keyfile keydir/desktop/arthur.pub)"
  assert_eq 'arthur' "$(gitolite_user_for_keyfile keydir/arthur@laptop.pub)"
  assert_eq 'a@example.com' "$(gitolite_user_for_keyfile keydir/a@example.com.pub)"
}

test_admin_identities_reads_gitolite_admin_block() {
  local tmp repo
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  cat >"$repo/conf/gitolite.conf" <<'CONF'
repo gitolite-admin
    RW+     =   arthur-admin @admins   # comment
    R       =   auditor

repo testing
    RW+     =   @all
CONF
  # shellcheck source=/dev/null
  source "$SCRIPT"
  assert_eq 'arthur-admin' "$(admin_identities "$repo")"
}

test_user_add_warns_for_admin_identity() {
  local tmp repo key fakebin out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  key="$tmp/admin2.pub"
  fakebin=$(fake_ssh_keygen "$tmp")
  new_admin_repo "$repo"
  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminSecondKey admin@example.invalid' >"$key"

  out=$(PATH="$fakebin:$PATH" "$SCRIPT" user-add --admin-dir "$repo" --name admin --key "$key" --key-id laptop 2>&1)
  assert_contains "$out" "'admin' can push to gitolite-admin"

  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIArthurDailyKey arthur@example.invalid' >"$tmp/arthur.pub"
  out=$(PATH="$fakebin:$PATH" "$SCRIPT" user-add --admin-dir "$repo" --name arthur --key "$tmp/arthur.pub" --key-id laptop 2>&1)
  assert_not_contains "$out" 'can push to gitolite-admin'
}

test_repo_set_warns_when_admin_identity_is_used() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1

  out=$("$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner admin 2>&1)
  assert_contains "$out" "'admin' is also a gitolite-admin identity"

  out=$("$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur 2>&1)
  assert_not_contains "$out" 'gitolite-admin identity'
}

# Write a placeholder public key file with a unique key blob.
write_key() {
  local path=$1 blob=$2
  mkdir -p "$(dirname "$path")"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5%s test@example.invalid\n' "$blob" >"$path"
}

test_user_add_rejects_names_gitolite_would_rename() {
  local tmp repo fakebin out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  fakebin=$(fake_ssh_keygen "$tmp")
  new_admin_repo "$repo"
  write_key "$tmp/k1.pub" KeyOne
  write_key "$tmp/k2.pub" KeyTwo

  if out=$(PATH="$fakebin:$PATH" "$SCRIPT" user-add --admin-dir "$repo" --name arthur@laptop --key "$tmp/k1.pub" 2>&1); then
    return 1
  fi
  assert_contains "$out" "as user 'arthur', not 'arthur@laptop'"

  # An e-mail style name is kept by Gitolite, so it is accepted.
  PATH="$fakebin:$PATH" "$SCRIPT" user-add --admin-dir "$repo" --name a@example.com --key "$tmp/k2.pub" >/dev/null 2>&1
  [[ -f "$repo/keydir/a@example.com.pub" ]]
}

test_user_add_rejects_key_used_by_another_identity() {
  local tmp repo fakebin out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  fakebin=$(fake_ssh_keygen "$tmp")
  new_admin_repo "$repo"
  write_key "$tmp/shared.pub" SharedKey

  PATH="$fakebin:$PATH" "$SCRIPT" user-add --admin-dir "$repo" --name agent-impl --key "$tmp/shared.pub" >/dev/null 2>&1
  if out=$(PATH="$fakebin:$PATH" "$SCRIPT" user-add --admin-dir "$repo" --name agent-fix --key "$tmp/shared.pub" 2>&1); then
    return 1
  fi
  assert_contains "$out" "already stored as keydir/agent-impl.pub (user 'agent-impl')"
  [[ ! -e "$repo/keydir/agent-fix.pub" ]]

  # Replacing a key file with the same key is still allowed.
  PATH="$fakebin:$PATH" "$SCRIPT" user-add --admin-dir "$repo" --name agent-impl --key "$tmp/shared.pub" --replace >/dev/null 2>&1
}

test_user_remove_refuses_last_admin_key() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  write_key "$repo/keydir/admin.pub" AdminKey
  git -C "$repo" add keydir && git -C "$repo" commit -qm 'admin key'

  if out=$("$SCRIPT" user-remove --admin-dir "$repo" --name admin 2>&1); then
    return 1
  fi
  assert_contains "$out" 'last key that can push to gitolite-admin'
  [[ -f "$repo/keydir/admin.pub" ]]
  git -C "$repo" diff --cached --quiet

  # With a second admin key, removing the first one is fine.
  write_key "$repo/keydir/laptop/admin.pub" AdminLaptopKey
  git -C "$repo" add keydir/laptop/admin.pub
  "$SCRIPT" user-remove --admin-dir "$repo" --name admin >/dev/null 2>&1
  [[ ! -e "$repo/keydir/admin.pub" && -f "$repo/keydir/laptop/admin.pub" ]]

  # --force removes the last one, but keydir itself stays.
  "$SCRIPT" user-remove --admin-dir "$repo" --name admin --key-id laptop --force >/dev/null 2>&1
  [[ ! -e "$repo/keydir/laptop" && -d "$repo/keydir" ]]
}

test_user_remove_all_warns_about_remaining_acl() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  write_key "$repo/keydir/admin.pub" AdminKey
  write_key "$repo/keydir/desktop/dev1.pub" DevDesktop
  write_key "$repo/keydir/notebook/dev1.pub" DevNotebook
  git -C "$repo" add keydir && git -C "$repo" commit -qm keys
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1
  "$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner admin2 --writers dev1 >/dev/null 2>&1

  out=$("$SCRIPT" user-remove --admin-dir "$repo" --name dev1 --all 2>&1)
  [[ ! -e "$repo/keydir/desktop" && ! -e "$repo/keydir/notebook" ]]
  assert_contains "$out" "'dev1' has no keys left but is still named in: conf/repos/project-x.conf"
}

test_repo_set_rejects_identity_with_two_roles() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1

  if out=$("$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur \
    --writers dev1,agent-fix --agents agent-impl,agent-fix 2>&1); then
    return 1
  fi
  assert_contains "$out" "'agent-fix' is both writer and agent"
  [[ ! -e "$repo/conf/repos/project-x.conf" ]]
}

test_repo_set_rejects_agent_names_with_special_characters() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1

  if out=$("$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur --agents agent.impl 2>&1); then
    return 1
  fi
  assert_contains "$out" "Agent name 'agent.impl'"
}

test_repo_set_warns_about_identities_without_keys() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  write_key "$repo/keydir/arthur.pub" ArthurKey
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1

  out=$("$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur --readers ci 2>&1)
  assert_contains "$out" "No key in keydir for 'ci'"
  assert_not_contains "$out" "No key in keydir for 'arthur'"
}

test_repo_set_and_group_set_know_gitolite_special_users() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  write_key "$repo/keydir/arthur.pub" ArthurKey
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1

  # daemon and gitweb have no key, but their rules work: say what they do
  # instead of warning that they have no effect.
  out=$("$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur --readers ci,daemon,gitweb 2>&1)
  assert_not_contains "$out" "No key in keydir for 'daemon'"
  assert_not_contains "$out" "No key in keydir for 'gitweb'"
  assert_contains "$out" "'daemon' is Gitolite's user for anonymous reading"
  assert_contains "$out" 'git-daemon-export-ok'
  assert_contains "$out" "'gitweb' is Gitolite's user for gitweb"
  assert_contains "$out" 'projects.list'
  # Real identities are still checked.
  assert_contains "$out" "No key in keydir for 'ci'"
  grep -Fxq '    R                           =   ci daemon gitweb' "$repo/conf/repos/project-x.conf"

  out=$("$SCRIPT" group-set --admin-dir "$repo" --name public --members daemon 2>&1)
  assert_not_contains "$out" "No key in keydir for 'daemon'"
  assert_contains "$out" "'daemon' is Gitolite's user for anonymous reading"
}

# Create TMP/origin.git (with admin-init applied) and two working trees,
# TMP/desktop and TMP/laptop, as if on two machines.
new_admin_origin_with_two_clones() {
  local tmp=$1 clone
  new_admin_repo "$tmp/seed"
  "$SCRIPT" admin-init --admin-dir "$tmp/seed" >/dev/null 2>&1
  git -C "$tmp/seed" commit -qm 'admin-init'
  git clone -q --bare "$tmp/seed" "$tmp/origin.git"
  for clone in desktop laptop; do
    git clone -q "$tmp/origin.git" "$tmp/$clone"
    git -C "$tmp/$clone" config user.name "Test User"
    git -C "$tmp/$clone" config user.email "test@example.invalid"
  done
}

test_apply_stops_when_behind_and_sync_keeps_staged_changes() {
  local tmp before out
  tmp=$(new_tmp)
  new_admin_origin_with_two_clones "$tmp"

  "$SCRIPT" repo-set --admin-dir "$tmp/desktop" --repo alpha --owner arthur >/dev/null 2>&1
  "$SCRIPT" apply --admin-dir "$tmp/desktop" -m 'Add alpha' >/dev/null 2>&1

  "$SCRIPT" repo-set --admin-dir "$tmp/laptop" --repo beta --owner arthur >/dev/null 2>&1
  before=$(git -C "$tmp/laptop" rev-parse HEAD)
  if out=$("$SCRIPT" apply --admin-dir "$tmp/laptop" -m 'Add beta' 2>&1); then
    return 1
  fi
  assert_contains "$out" 'Nothing was committed'
  assert_contains "$out" 'sync'
  assert_eq "$before" "$(git -C "$tmp/laptop" rev-parse HEAD)" 'apply must not commit when behind'

  "$SCRIPT" sync --admin-dir "$tmp/laptop" >/dev/null 2>&1
  assert_eq "$(git -C "$tmp/origin.git" rev-parse master)" "$(git -C "$tmp/laptop" rev-parse HEAD)"
  assert_eq 'conf/repos/beta.conf' "$(git -C "$tmp/laptop" diff --cached --name-only)" 'sync must keep staged changes'

  "$SCRIPT" apply --admin-dir "$tmp/laptop" -m 'Add beta' >/dev/null 2>&1
  out=$(git -C "$tmp/origin.git" ls-tree -r --name-only master conf/repos)
  assert_contains "$out" 'conf/repos/alpha.conf'
  assert_contains "$out" 'conf/repos/beta.conf'
}

test_sync_rebases_unpushed_commits() {
  local tmp out
  tmp=$(new_tmp)
  new_admin_origin_with_two_clones "$tmp"

  "$SCRIPT" repo-set --admin-dir "$tmp/laptop" --repo gamma --owner arthur >/dev/null 2>&1
  "$SCRIPT" apply --admin-dir "$tmp/laptop" --no-push -m 'Add gamma' >/dev/null 2>&1
  "$SCRIPT" repo-set --admin-dir "$tmp/desktop" --repo delta --owner arthur >/dev/null 2>&1
  "$SCRIPT" apply --admin-dir "$tmp/desktop" -m 'Add delta' >/dev/null 2>&1

  out=$("$SCRIPT" sync --admin-dir "$tmp/laptop" 2>&1)
  assert_contains "$out" 'Rebased local commits'
  git -C "$tmp/laptop" merge-base --is-ancestor origin/master HEAD
  git -C "$tmp/laptop" push -q origin master
  out=$(git -C "$tmp/origin.git" ls-tree -r --name-only master conf/repos)
  assert_contains "$out" 'conf/repos/gamma.conf'
  assert_contains "$out" 'conf/repos/delta.conf'

  out=$("$SCRIPT" sync --admin-dir "$tmp/laptop" 2>&1)
  assert_contains "$out" 'up to date'
}

test_host_keys_prints_fingerprints_and_known_hosts_lines() {
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    printf '  skipped: ssh-keygen is not installed\n' >&2
    return 0
  fi
  local tmp keydir out blob
  tmp=$(new_tmp)
  keydir="$tmp/etc-ssh"
  mkdir -p "$keydir"
  ssh-keygen -q -t ed25519 -N '' -C host -f "$keydir/ssh_host_ed25519_key"
  blob=$(awk '{print $2}' "$keydir/ssh_host_ed25519_key.pub")

  out=$(
    # shellcheck source=/dev/null
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by server_host_keys from the script
    SSH_HOST_KEY_DIR=$keydir
    server_host_keys --host git.example.internal --port 2222
  )
  assert_contains "$out" "$(ssh-keygen -lf "$keydir/ssh_host_ed25519_key.pub")"
  assert_contains "$out" "[git.example.internal]:2222 ssh-ed25519 $blob"

  out=$(
    # shellcheck source=/dev/null
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by server_host_keys from the script
    SSH_HOST_KEY_DIR=$keydir
    server_host_keys --host git.example.internal --port 22
  )
  assert_contains "$out" "git.example.internal ssh-ed25519 $blob"
  assert_not_contains "$out" '[git.example.internal]'
}

test_ssh_hardening_dropin_accepts_git_protocol_for_git_user_only() {
  local out
  # shellcheck source=/dev/null
  source "$SCRIPT"
  out=$(ssh_hardening_dropin git)
  # AcceptEnv must be inside "Match User git", before "Match all".
  printf '%s\n' "$out" | awk '
    /^Match User git$/ { in_git = 1; next }
    /^Match all$/ { in_git = 0 }
    in_git && $1 == "AcceptEnv" && $2 == "GIT_PROTOCOL" { found = 1 }
    END { exit !found }'
}

test_admin_init_puts_groups_include_before_repos_include() {
  local tmp repo order
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  # A working tree initialized by an older version: only the repos include.
  printf '\ninclude "repos/*.conf"\n' >>"$repo/conf/gitolite.conf"

  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1
  order=$(grep -E '^include ' "$repo/conf/gitolite.conf" | paste -sd '|' -)
  assert_eq 'include "groups/*.conf"|include "repos/*.conf"' "$order"
  [[ -f "$repo/conf/groups/.gitkeep" ]]
}

test_group_set_and_repo_set_with_group() {
  local tmp repo content out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1

  "$SCRIPT" group-set --admin-dir "$repo" --name @agents --members agent-impl,agent-fix >/dev/null 2>&1
  content=$(<"$repo/conf/groups/agents.conf")
  assert_contains "$content" '@agents = agent-impl agent-fix'
  assert_contains "$content" '# mini-git-server: members=agent-impl agent-fix'

  "$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur \
    --writers dev1 --agents @agents --protected-branch trunk >/dev/null 2>&1
  content=$(<"$repo/conf/repos/project-x.conf")
  assert_contains "$content" 'RW      agent/USER/         =   @agents'
  assert_contains "$content" '=   dev1 @agents'

  out=$("$SCRIPT" group-list --admin-dir "$repo")
  assert_eq '@agents: agent-impl agent-fix' "$out"
  out=$("$SCRIPT" repo-show --admin-dir "$repo" --repo project-x)
  assert_contains "$out" '--agents @agents'
}

test_group_members_are_checked_for_role_overlap() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1
  "$SCRIPT" group-set --admin-dir "$repo" --name agents --members agent-impl,dev1 >/dev/null 2>&1

  # repo-set expands the group: dev1 would be both writer and agent.
  if out=$("$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur \
    --writers dev1 --agents @agents 2>&1); then
    return 1
  fi
  assert_contains "$out" "'dev1' is both writer and agent"

  # group-set checks the repositories that already use the group.
  "$SCRIPT" group-set --admin-dir "$repo" --name agents --members agent-impl >/dev/null 2>&1
  "$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur \
    --writers dev1 --agents @agents >/dev/null 2>&1
  if out=$("$SCRIPT" group-set --admin-dir "$repo" --name agents --members agent-impl,dev1 2>&1); then
    return 1
  fi
  assert_contains "$out" "repository 'project-x' would be invalid"
  assert_contains "$out" "'dev1' is both writer and agent"
  assert_eq '@agents: agent-impl' "$("$SCRIPT" group-list --admin-dir "$repo")"

  # Agent name rules apply to group members too.
  if out=$("$SCRIPT" group-set --admin-dir "$repo" --name agents --members agent.x 2>&1); then
    return 1
  fi
  assert_contains "$out" "Agent name 'agent.x'"
}

test_group_remove_refuses_group_in_use() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1
  "$SCRIPT" group-set --admin-dir "$repo" --name readers --members ci >/dev/null 2>&1
  "$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur --readers @readers >/dev/null 2>&1

  if out=$("$SCRIPT" group-remove --admin-dir "$repo" --name readers 2>&1); then
    return 1
  fi
  assert_contains "$out" 'still used in: conf/repos/project-x.conf'

  "$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur --readers ci >/dev/null 2>&1
  "$SCRIPT" group-remove --admin-dir "$repo" --name readers >/dev/null 2>&1
  [[ ! -e "$repo/conf/groups/readers.conf" ]]
}

test_repo_set_warns_about_unmanaged_group() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1
  out=$("$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur --readers @all,@ops 2>&1)
  assert_contains "$out" "Group '@ops' is not managed by group-set"
  assert_not_contains "$out" "Group '@all'"
}

test_repo_set_agent_rewind_and_repo_show_round_trip() {
  local tmp repo fragment before out cmd
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1

  "$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur \
    --agents agent-impl --agent-rewind --protected-branch trunk >/dev/null 2>&1
  fragment="$repo/conf/repos/project-x.conf"
  before=$(<"$fragment")
  assert_contains "$before" 'RW+     agent/USER/         =   agent-impl'
  assert_contains "$before" '# mini-git-server: agent-rewind=yes'
  assert_contains "$before" 'refs/heads/trunk$'

  out=$("$SCRIPT" repo-show --admin-dir "$repo" --repo project-x)
  assert_contains "$out" 'Agent rewind: yes'
  assert_contains "$out" '--agent-rewind'

  # Running the printed reapply command must give the same fragment.
  cmd=$(printf '%s\n' "$out" | sed -n '/^Reapply command:$/,$p' | tail -n +2)
  bash -c "$cmd" >/dev/null 2>&1
  assert_eq "$before" "$(<"$fragment")" 'reapply command must reproduce the fragment'

  if out=$("$SCRIPT" repo-set --admin-dir "$repo" --repo project-y --owner arthur --agent-rewind 2>&1); then
    return 1
  fi
  assert_contains "$out" '--agent-rewind needs --agents'
}

# Print the line number of the first line in FILE that equals TEXT.
line_of() {
  awk -v t="$2" '$0 == t {print NR; exit}' "$1"
}

test_repo_set_reserves_tags_for_owner_and_agent_branches_for_agents() {
  local tmp repo fragment tags agent_ns writers_rw content
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  "$SCRIPT" admin-init --admin-dir "$repo" >/dev/null 2>&1
  fragment="$repo/conf/repos/project-x.conf"

  "$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur \
    --writers dev1 --agents agent-impl --readers ci >/dev/null 2>&1
  tags=$(line_of "$fragment" '    -       refs/tags/           =   dev1 agent-impl')
  agent_ns=$(line_of "$fragment" '    -       agent/               =   dev1')
  writers_rw=$(line_of "$fragment" '    RW                          =   dev1')
  [[ -n $tags && -n $agent_ns && -n $writers_rw ]]
  # Gitolite uses the first matching rule: both denials must come first.
  (( tags < writers_rw && agent_ns < writers_rw ))

  # Agents only: tags are still denied, but there is no writer rule.
  "$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur --agents agent-impl >/dev/null 2>&1
  content=$(<"$fragment")
  assert_contains "$content" '    -       refs/tags/           =   agent-impl'
  assert_not_contains "$content" '    -       agent/ '

  # Owner and readers only: no deny rules are needed.
  "$SCRIPT" repo-set --admin-dir "$repo" --repo project-x --owner arthur --readers ci >/dev/null 2>&1
  content=$(<"$fragment")
  assert_not_contains "$content" '    -       '
}

test_admin_identities_expands_groups() {
  local tmp repo
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  # A group defined in gitolite.conf, with a nested group and a loop.
  cat >"$repo/conf/gitolite.conf" <<'CONF'
@ops     = carol @admins
@admins  = arthur-admin backup-admin @ops

repo gitolite-admin
    RW+     =   @admins @all

repo testing
    RW+     =   @all
CONF
  # shellcheck source=/dev/null
  source "$SCRIPT"
  assert_eq $'arthur-admin\nbackup-admin\ncarol' "$(admin_identities "$repo")"

  # A group managed by group-set, in conf/groups/.
  cat >"$repo/conf/gitolite.conf" <<'CONF'
include "groups/*.conf"

repo gitolite-admin
    RW+     =   @keepers
CONF
  mkdir -p "$repo/conf/groups"
  printf '@keepers = dana\n' >"$repo/conf/groups/keepers.conf"
  assert_eq 'dana' "$(admin_identities "$repo")"
}

test_user_remove_lockout_check_uses_admin_groups() {
  local tmp repo out
  tmp=$(new_tmp)
  repo="$tmp/admin"
  new_admin_repo "$repo"
  cat >"$repo/conf/gitolite.conf" <<'CONF'
@admins = arthur-admin backup-admin

repo gitolite-admin
    RW+     =   @admins
CONF
  write_key "$repo/keydir/arthur-admin.pub" ArthurAdminKey
  write_key "$repo/keydir/backup-admin.pub" BackupAdminKey
  git -C "$repo" add . && git -C "$repo" commit -qm 'admins via a group'

  # backup-admin still has a key, so removing arthur-admin is fine.
  "$SCRIPT" user-remove --admin-dir "$repo" --name arthur-admin >/dev/null 2>&1
  [[ ! -e "$repo/keydir/arthur-admin.pub" ]]

  # Now backup-admin has the last admin key.
  if out=$("$SCRIPT" user-remove --admin-dir "$repo" --name backup-admin 2>&1); then
    return 1
  fi
  assert_contains "$out" 'last key that can push to gitolite-admin'
  assert_not_contains "$out" 'skipping the lockout check'
}

# Run server_status with mocked system commands. ROOT is 1 or 0.
status_with_mocks() {
  # Not named "root": server_status has a local variable with that name,
  # and Bash functions see the caller's local variables.
  local mock_root=$1 home=$2
  (
    # shellcheck source=/dev/null
    source "$SCRIPT"
    is_root() { (( mock_root )); }
    id() { return 0; }
    getent() { printf 'git:x:1000:1000::%s:/bin/bash\n' "$home"; }
    runuser() { shift 3; "$@"; }
    # sshd is stopped, and "sshd -T" fails.
    systemctl() { printf 'inactive\n'; return 3; }
    sshd() { return 1; }
    passwd() { printf '%s L 2026-01-01 0 99999 7 -1\n' "$2"; }
    gitolite() { printf '%s\n' "$home/gitolite-bin"; }
    server_status --git-user git 2>&1
  )
}

test_status_marks_fields_that_need_root() {
  local tmp home out
  tmp=$(new_tmp)
  home="$tmp/git-home"
  mkdir -p "$home/repositories/demo.git" "$home/gitolite-bin"
  printf '3.6.12-4 (Debian)\n' >"$home/gitolite-bin/VERSION"
  git config --file "$home/.gitconfig" init.defaultBranch trunk

  out=$(status_with_mocks 0 "$home")
  assert_contains "$out" "Not running as root"
  assert_contains "$out" 'SSH ports:           (needs root)'
  assert_contains "$out" 'SSH MaxStartups:     (needs root)'
  assert_contains "$out" 'Default branch:      (needs root)'
  assert_contains "$out" 'Password status:     (needs root)'
  assert_not_contains "$out" 'Git-default'
  # The test home is readable, so the repositories can still be counted.
  assert_contains "$out" 'Repository count:    1'
  assert_contains "$out" 'Gitolite:            3.6.12-4 (Debian)'

  out=$(status_with_mocks 1 "$home")
  assert_not_contains "$out" 'Not running as root'
  assert_contains "$out" 'Default branch:      trunk'
  assert_contains "$out" 'Password status:     L'
}

test_status_prints_one_line_per_field() {
  local tmp home out
  tmp=$(new_tmp)
  home="$tmp/git-home"
  mkdir -p "$home"
  out=$(status_with_mocks 1 "$home")
  # A failing command must not leave its output in front of the fallback.
  assert_contains "$out" $'SSH service:         inactive\nSSH ports:           unknown\nSSH MaxStartups:     unknown\nDefault branch:      Git-default\n'
  assert_contains "$out" 'Gitolite:            unknown'
  assert_contains "$out" 'Repository count:    0'
}

test_validate_max_startups() {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  local value
  for value in 10 10:30:100 50:30:200 20:100:20 1:1:1; do
    ( validate_max_startups "$value" ) >/dev/null 2>&1 || {
      printf '  rejected valid value %s\n' "$value"
      return 1
    }
  done
  # The same values that sshd itself rejects.
  for value in 0 abc 10:30 100:30:10 10:101:100 10:0:100 -5 '10:30:100 '; do
    if ( validate_max_startups "$value" ) >/dev/null 2>&1; then
      printf '  accepted invalid value %q\n' "$value"
      return 1
    fi
  done
  assert_eq '20:30:20' "$(normalize_max_startups 20)"
  assert_eq '50:30:200' "$(normalize_max_startups 50:30:200)"
}

test_ssh_limits_rejects_both_options() {
  local out
  if out=$("$SCRIPT" ssh-limits --max-startups 50:30:200 --reset 2>&1); then
    return 1
  fi
  assert_contains "$out" 'either --max-startups or --reset'
}

# Build TMP/origin.git (HEAD -> trunk) and a clone TMP/clone with:
#   agent/agent-fix/typo     merged into trunk with --no-ff (older)
#   agent/agent-impl/issue-1 two commits not in trunk (newest)
new_project_with_agent_branches() {
  local tmp=$1
  local work="$tmp/work"
  commit_at() {
    GIT_AUTHOR_DATE=$1 GIT_COMMITTER_DATE=$1 \
      git -C "$work" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m "$2"
  }
  git init -q -b trunk "$work"
  commit_at '2026-01-01T00:00:00Z' base
  git init -q --bare -b trunk "$tmp/origin.git"
  git -C "$work" push -q "$tmp/origin.git" trunk

  git -C "$work" switch -q -c fix
  commit_at '2026-01-02T00:00:00Z' 'Fix a typo'
  git -C "$work" push -q "$tmp/origin.git" fix:refs/heads/agent/agent-fix/typo
  git -C "$work" switch -q trunk
  GIT_COMMITTER_DATE='2026-01-03T00:00:00Z' \
    git -C "$work" -c user.name=Test -c user.email=test@example.invalid merge -q --no-ff -m 'Merge typo fix' fix
  git -C "$work" push -q "$tmp/origin.git" trunk

  git -C "$work" switch -q -c impl
  commit_at '2026-01-04T00:00:00Z' 'Step one'
  commit_at '2026-01-05T00:00:00Z' 'Step two'
  git -C "$work" push -q "$tmp/origin.git" impl:refs/heads/agent/agent-impl/issue-1

  git clone -q "$tmp/origin.git" "$tmp/clone"
}

test_agent_branches_lists_branches_against_the_default_branch() {
  local tmp out impl_line fix_line
  tmp=$(new_tmp)
  new_project_with_agent_branches "$tmp"

  out=$(cd "$tmp/clone" && "$SCRIPT" agent-branches)
  grep -Eq '^agent-impl +agent/agent-impl/issue-1 +2 +0 .*Step two$' <<<"$out"
  grep -Eq '^agent-fix +agent/agent-fix/typo +0 +1 .*Fix a typo$' <<<"$out"
  assert_contains "$out" 'counted against origin/trunk'
  # Newest first.
  impl_line=$(printf '%s\n' "$out" | grep -n 'agent/agent-impl/issue-1' | cut -d: -f1)
  fix_line=$(printf '%s\n' "$out" | grep -n 'agent/agent-fix/typo' | cut -d: -f1)
  (( impl_line < fix_line ))
}

test_agent_branches_merged_prints_delete_commands() {
  local tmp out
  tmp=$(new_tmp)
  new_project_with_agent_branches "$tmp"

  out=$(cd "$tmp/clone" && "$SCRIPT" agent-branches --merged)
  assert_contains "$out" 'agent/agent-fix/typo'
  assert_not_contains "$out" 'agent/agent-impl/issue-1'
  assert_contains "$out" '  git push origin --delete agent/agent-fix/typo'
}

test_agent_branches_finds_or_asks_for_the_base_branch() {
  local tmp out
  tmp=$(new_tmp)
  new_project_with_agent_branches "$tmp"
  git -C "$tmp/clone" remote set-head origin -d

  # Without origin/HEAD, it asks the remote (this needs a fetch).
  out=$(cd "$tmp/clone" && "$SCRIPT" agent-branches)
  assert_contains "$out" 'counted against origin/trunk'

  git -C "$tmp/clone" remote set-head origin -d
  if out=$(cd "$tmp/clone" && "$SCRIPT" agent-branches --no-fetch 2>&1); then
    return 1
  fi
  assert_contains "$out" 'Pass --base BRANCH'

  out=$(cd "$tmp/clone" && "$SCRIPT" agent-branches --no-fetch --base trunk)
  assert_contains "$out" 'agent/agent-impl/issue-1'

  if out=$(cd "$tmp/clone" && "$SCRIPT" agent-branches --base no-such-branch 2>&1); then
    return 1
  fi
  assert_contains "$out" "Branch 'no-such-branch' was not found on 'origin'"

  if out=$(cd "$tmp" && "$SCRIPT" agent-branches 2>&1); then
    return 1
  fi
  assert_contains "$out" 'inside a clone of a project repository'
}

# A bare repository for share: trunk with two commits, a tag v1 on the
# first one, and a branch with a slash in its name.
new_share_origin() {
  local tmp=$1
  local work="$tmp/share-work"
  git init -q -b trunk "$work"
  printf 'hello\n' >"$work/README"
  mkdir "$work/bin"
  printf '#!/bin/sh\necho run\n' >"$work/bin/run"
  chmod +x "$work/bin/run"
  ln -s README "$work/LINK"
  git -C "$work" add .
  git -C "$work" -c user.name=Test -c user.email=test@example.invalid commit -qm first
  git -C "$work" tag v1
  printf 'second\n' >>"$work/README"
  git -C "$work" -c user.name=Test -c user.email=test@example.invalid commit -qam second
  git -C "$work" branch release/1
  git init -q --bare -b trunk "$tmp/origin.git"
  git -C "$work" push -q "$tmp/origin.git" trunk release/1 v1
  # share creates its temporary directory here, so the tests can check
  # that nothing is left behind.
  mkdir "$tmp/tmpdir"
}

# Start share in the background, with TMP/tmpdir as its temporary
# directory, and wait until it prints the URL. Sets SHARE_PID and SHARE_URL.
# Output goes to TMP/share.out and TMP/share.out.err. Stops share when the
# test ends, also when it fails.
#
# A background command of a non-interactive shell starts with SIGINT
# ignored, and Bash cannot trap a signal that was ignored on entry. Reset it,
# so share sees Ctrl-C as it would in a terminal.
start_share() {
  local tmp=$1 i out="$1/share.out"
  shift
  env --default-signal=INT TMPDIR="$tmp/tmpdir" "$SCRIPT" share "$@" >"$out" 2>"$out.err" &
  SHARE_PID=$!
  trap 'kill "$SHARE_PID" 2>/dev/null || true' EXIT
  for ((i = 0; i < 300; i++)); do
    grep -q '^URL:' "$out" 2>/dev/null && break
    kill -0 "$SHARE_PID" 2>/dev/null || break
    sleep 0.1
  done
  SHARE_URL=$(awk '/^URL:/ {print $2}' "$out")
  [[ -n $SHARE_URL ]] || { cat "$out.err" >&2; return 1; }
}

# Wait up to SECONDS for share to end, and set SHARE_RC to its exit status.
# Do not call it in $(...): only the shell that started share can wait for it.
wait_for_share() {
  local seconds=$1 i
  for ((i = 0; i < seconds * 10; i++)); do
    kill -0 "$SHARE_PID" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$SHARE_PID" 2>/dev/null; then
    printf '  share is still running after %ss\n' "$seconds" >&2
    return 1
  fi
  SHARE_RC=0
  wait "$SHARE_PID" || SHARE_RC=$?
}

# The command that share prints for the target.
share_target_command() {
  grep -A1 '^On the target:' "$1" | tail -n 1
}

# Print the HTTP status of URL, or 000 when nothing answers.
http_status() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true
}

test_share_rejects_bad_options() {
  local tmp out
  tmp=$(new_tmp)
  new_share_origin "$tmp"
  local -a ok=(--from "$tmp/origin.git" --ref trunk --bind 127.0.0.1)
  export TMPDIR="$tmp/tmpdir"

  if out=$("$SCRIPT" share --from "$tmp/origin.git" --ref trunk 2>&1); then return 1; fi
  assert_contains "$out" '--from, --ref and --bind are required'
  if out=$("$SCRIPT" share --from "$tmp/origin.git" --ref -x --bind 127.0.0.1 2>&1); then return 1; fi
  assert_contains "$out" 'Invalid --ref'
  if out=$("$SCRIPT" share --from '-oProxyCommand=x' --ref trunk --bind 127.0.0.1 2>&1); then return 1; fi
  assert_contains "$out" 'Invalid --from'
  if out=$("$SCRIPT" share --from "$tmp/origin.git" --ref trunk --bind 'a b' 2>&1); then return 1; fi
  assert_contains "$out" 'Invalid --bind'
  if out=$("$SCRIPT" share "${ok[@]}" --format rar 2>&1); then return 1; fi
  assert_contains "$out" '--format must be tar.gz or zip'
  if out=$("$SCRIPT" share "${ok[@]}" --depth 0 2>&1); then return 1; fi
  assert_contains "$out" '--depth must be a positive number'
  if out=$("$SCRIPT" share "${ok[@]}" --port 70000 2>&1); then return 1; fi
  assert_contains "$out" 'Invalid --port'
  if out=$("$SCRIPT" share "${ok[@]}" --ttl 25h 2>&1); then return 1; fi
  assert_contains "$out" '--ttl must be between 1s and 24h'
  if out=$("$SCRIPT" share "${ok[@]}" --ttl 5x 2>&1); then return 1; fi
  assert_contains "$out" 'Invalid --ttl'
  if out=$("$SCRIPT" share "${ok[@]}" --max-downloads -1 2>&1); then return 1; fi
  assert_contains "$out" '--max-downloads must be a number'
  # Nothing was created for any of them.
  assert_eq '' "$(ls -A "$tmp/tmpdir")"
}

test_share_serves_one_download_and_removes_everything() {
  local tmp out token target
  tmp=$(new_tmp)
  new_share_origin "$tmp"
  out="$tmp/share.out"
  start_share "$tmp" --from "$tmp/origin.git" --ref trunk --bind 127.0.0.1
  token=$(cut -d/ -f4 <<<"$SHARE_URL")
  [[ $token =~ ^[0-9a-f]{32}$ ]]
  [[ $SHARE_URL == http://127.0.0.1:*/"$token"/origin-trunk.tar.gz ]]

  # Only the exact URL works.
  assert_eq 404 "$(http_status "${SHARE_URL/$token/00000000000000000000000000000000}")"
  assert_eq 404 "$(http_status "${SHARE_URL%/"$token"/*}/")"
  # While it is served, the archive is not on the disk, and the token is
  # not in the arguments of any process.
  assert_eq '' "$(find "$tmp/tmpdir" -type f)"
  # Read the token from a file, so this grep does not find its own arguments.
  printf '%s\n' "$token" >"$tmp/token"
  if grep -qsFf "$tmp/token" /proc/[0-9]*/cmdline; then
    printf '  the token is visible in a process command line\n' >&2
    return 1
  fi

  # The printed command downloads, checks and extracts the archive.
  target="$tmp/target"
  mkdir "$target"
  (cd "$target" && bash -c "$(share_target_command "$out")" >/dev/null)
  assert_eq $'hello\nsecond' "$(cat "$target/origin-trunk/README")"
  [[ -x $target/origin-trunk/bin/run ]]
  [[ -L $target/origin-trunk/LINK ]]
  [[ ! -e $target/origin-trunk/.git ]]

  # One download is the default limit: share stops and removes everything.
  wait_for_share 10
  assert_eq 0 "$SHARE_RC"
  assert_eq 000 "$(http_status "$SHARE_URL")"
  assert_eq '' "$(ls -A "$tmp/tmpdir")"
  assert_contains "$(cat "$out.err")" 'downloaded origin-trunk.tar.gz (1 of 1)'
  assert_contains "$(cat "$out.err")" 'Stopped. Removed'
}

test_share_depth_gives_a_shallow_clone_without_the_remote() {
  local tmp out target dir
  tmp=$(new_tmp)
  new_share_origin "$tmp"
  out="$tmp/share.out"
  start_share "$tmp" --from "$tmp/origin.git" --ref v1 --depth 1 --bind 127.0.0.1
  target="$tmp/target"
  mkdir "$target"
  (cd "$target" && bash -c "$(share_target_command "$out")" >/dev/null)
  dir="$target/origin-v1"
  assert_eq hello "$(cat "$dir/README")"
  assert_eq true "$(git -C "$dir" rev-parse --is-shallow-repository)"
  assert_eq 1 "$(git -C "$dir" rev-list --count HEAD)"
  assert_eq first "$(git -C "$dir" log -1 --format=%s)"
  assert_eq '' "$(git -C "$dir" remote)"
  [[ ! -e $dir/.git/logs ]]
  assert_eq '' "$(git -C "$dir" status --porcelain)"
  wait_for_share 10
  assert_eq 0 "$SHARE_RC"
}

test_share_zip_allows_several_downloads() {
  local tmp out listing
  tmp=$(new_tmp)
  new_share_origin "$tmp"
  out="$tmp/share.out"
  start_share "$tmp" --from "$tmp/origin.git" --ref release/1 --format zip --max-downloads 2 --bind 127.0.0.1
  [[ $SHARE_URL == */origin-release-1.zip ]]
  assert_contains "$(cat "$out")" "unzip -q 'origin-release-1.zip'"
  curl -fsS -o "$tmp/1.zip" "$SHARE_URL"
  curl -fsS -o "$tmp/2.zip" "$SHARE_URL"
  cmp "$tmp/1.zip" "$tmp/2.zip"
  listing=$(python3 -m zipfile -l "$tmp/1.zip")
  assert_contains "$listing" 'origin-release-1/README'
  assert_contains "$listing" 'origin-release-1/bin/run'
  wait_for_share 10
  assert_eq 0 "$SHARE_RC"
  assert_contains "$(cat "$out.err")" '(2 of 2)'
  assert_eq '' "$(ls -A "$tmp/tmpdir")"
}

test_share_stops_on_ctrl_c_on_hangup_and_after_kill_9() {
  local tmp out signal
  tmp=$(new_tmp)
  new_share_origin "$tmp"
  out="$tmp/share.out"
  for signal in INT:130 HUP:129; do
    start_share "$tmp" --from "$tmp/origin.git" --ref trunk --bind 127.0.0.1
    # HEAD requests do not count as downloads.
    assert_eq 200 "$(http_status -I "$SHARE_URL")"
    kill -s "${signal%:*}" "$SHARE_PID"
    wait_for_share 10
    assert_eq "${signal#*:}" "$SHARE_RC" "exit status after SIG${signal%:*}"
    assert_eq 000 "$(http_status -I "$SHARE_URL")"
    assert_eq '' "$(ls -A "$tmp/tmpdir")"
  done

  # kill -9 cannot be caught. The server notices that share is gone and
  # stops; the archive was never on the disk, so only an empty directory
  # is left.
  start_share "$tmp" --from "$tmp/origin.git" --ref trunk --bind 127.0.0.1
  kill -9 "$SHARE_PID"
  { wait "$SHARE_PID"; } 2>/dev/null || true
  local i status
  for ((i = 0; i < 50; i++)); do
    status=$(http_status -I "$SHARE_URL")
    [[ $status == 000 ]] && break
    sleep 0.1
  done
  assert_eq 000 "$status" 'the server kept running after kill -9'
  assert_eq '' "$(find "$tmp/tmpdir" -type f)"
}

test_share_stops_after_the_time_limit() {
  local tmp out
  tmp=$(new_tmp)
  new_share_origin "$tmp"
  out="$tmp/share.out"
  start_share "$tmp" --from "$tmp/origin.git" --ref trunk --ttl 1s --max-downloads 0 --bind 127.0.0.1
  wait_for_share 10
  assert_eq 0 "$SHARE_RC"
  assert_contains "$(cat "$out.err")" 'the time limit is reached'
  assert_eq '' "$(ls -A "$tmp/tmpdir")"
}

test_share_tls_pins_the_certificate() {
  local tmp out target command
  tmp=$(new_tmp)
  new_share_origin "$tmp"
  out="$tmp/share.out"
  start_share "$tmp" --from "$tmp/origin.git" --ref trunk --tls --bind 127.0.0.1
  [[ $SHARE_URL == https://* ]]
  command=$(share_target_command "$out")
  assert_contains "$command" "--pinnedpubkey 'sha256//"
  # An unpinned client refuses the self-signed certificate, and a wrong pin
  # is refused too. Neither counts as a download.
  assert_eq 000 "$(http_status "$SHARE_URL")"
  assert_eq 000 "$(http_status -k --pinnedpubkey 'sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$SHARE_URL")"
  target="$tmp/target"
  mkdir "$target"
  (cd "$target" && bash -c "$command" >/dev/null)
  assert_eq $'hello\nsecond' "$(cat "$target/origin-trunk/README")"
  wait_for_share 10
  assert_eq 0 "$SHARE_RC"
  assert_eq '' "$(ls -A "$tmp/tmpdir")"
}

run_test 'run_test fails a test when a check in the middle fails' test_run_test_catches_a_failed_check_in_the_middle
run_test 'bash syntax' test_bash_syntax
run_test 'version reports 0.3.0' test_version
run_test 'protected branch refex escapes regex characters' test_branch_refex_exact_escaping
run_test 'repository fragment names encode slashes' test_repo_fragment_name
run_test 'SSH port validation accepts only 1..65535' test_validate_port
run_test 'MaxStartups validation matches what sshd accepts' test_validate_max_startups
run_test 'ssh-limits refuses --max-startups together with --reset' test_ssh_limits_rejects_both_options
run_test 'admin-init is idempotent' test_admin_init_idempotent
run_test 'repo-set generates least-privilege agent ACL without hardcoded main' test_repo_set_acl_and_no_hardcoded_main
run_test 'protected branches are exact and escaped' test_protected_branch_exact_and_escaped
run_test 'repo-set reserves tags for the owner and agent/ for agents' test_repo_set_reserves_tags_for_owner_and_agent_branches_for_agents
run_test 'repo-set replaces the complete desired ACL state' test_repo_set_replaces_complete_desired_state
run_test 'repo-add remains a backward-compatible repo-set alias' test_repo_add_is_repo_set_alias
run_test 'repo-show prints state, reusable command, and raw fragment' test_repo_show_outputs_state_and_reusable_command
run_test 'repo-show parses legacy managed fragments' test_repo_show_parses_legacy_fragment
run_test 'multiple device keys map to one logical user' test_multi_device_user_key_layout
run_test 'repo-list includes managed repository fragments' test_repo_list_includes_fragments
run_test 'apply --no-push commits staged admin changes' test_apply_no_push_commits_staged_changes
run_test 'apply refuses a branch other than master' test_apply_refuses_branch_other_than_master
run_test 'apply refuses a detached HEAD' test_apply_refuses_detached_head
run_test 'repo-set-default supports an unborn branch' test_repo_set_default_unborn_branch
run_test 'repo-set-default --require-existing rejects a missing branch' test_repo_set_default_require_existing_rejects_missing
run_test 'repo-set-default keeps gitolite-admin on master' test_repo_set_default_keeps_admin_repo_on_master
run_test 'status marks the fields that need root' test_status_marks_fields_that_need_root
run_test 'status prints one line per field when commands fail' test_status_prints_one_line_per_field
run_test 'keydir file names map to users like Gitolite does' test_gitolite_user_for_keyfile_matches_gitolite
run_test 'admin identities are read from the gitolite-admin block' test_admin_identities_reads_gitolite_admin_block
run_test 'admin identities expand groups, nested groups and group-set groups' test_admin_identities_expands_groups
run_test 'user-remove lockout check works when admins are given as a group' test_user_remove_lockout_check_uses_admin_groups
run_test 'user-add warns when adding a key to an admin identity' test_user_add_warns_for_admin_identity
run_test 'repo-set warns when an admin identity is used in an ACL' test_repo_set_warns_when_admin_identity_is_used
run_test 'user-add rejects names that Gitolite would map to another user' test_user_add_rejects_names_gitolite_would_rename
run_test 'user-add rejects a key already used by another identity' test_user_add_rejects_key_used_by_another_identity
run_test 'user-remove refuses to remove the last admin key' test_user_remove_refuses_last_admin_key
run_test 'user-remove --all removes every key and warns about remaining ACL entries' test_user_remove_all_warns_about_remaining_acl
run_test 'repo-set rejects an identity with two roles' test_repo_set_rejects_identity_with_two_roles
run_test 'repo-set rejects agent names with special characters' test_repo_set_rejects_agent_names_with_special_characters
run_test 'repo-set warns about identities without keys' test_repo_set_warns_about_identities_without_keys
run_test 'repo-set and group-set do not warn about the keyless daemon and gitweb users' test_repo_set_and_group_set_know_gitolite_special_users
run_test 'apply stops when origin is newer, and sync keeps staged changes' test_apply_stops_when_behind_and_sync_keeps_staged_changes
run_test 'sync rebases local commits that were not pushed' test_sync_rebases_unpushed_commits
run_test 'host-keys prints fingerprints and known_hosts lines' test_host_keys_prints_fingerprints_and_known_hosts_lines
run_test 'SSH hardening accepts GIT_PROTOCOL for the hosting user only' test_ssh_hardening_dropin_accepts_git_protocol_for_git_user_only
run_test 'admin-init puts the groups include before the repos include' test_admin_init_puts_groups_include_before_repos_include
run_test 'group-set creates a group that repo-set can use' test_group_set_and_repo_set_with_group
run_test 'group members are checked for role overlap and agent names' test_group_members_are_checked_for_role_overlap
run_test 'group-remove refuses a group that is still used' test_group_remove_refuses_group_in_use
run_test 'repo-set warns about a group not managed by group-set' test_repo_set_warns_about_unmanaged_group
run_test 'repo-set --agent-rewind round-trips through repo-show' test_repo_set_agent_rewind_and_repo_show_round_trip
run_test 'agent-branches lists agent branches against the default branch' test_agent_branches_lists_branches_against_the_default_branch
run_test 'agent-branches --merged prints delete commands' test_agent_branches_merged_prints_delete_commands
run_test 'agent-branches finds the base branch, or asks for it' test_agent_branches_finds_or_asks_for_the_base_branch
run_test 'share rejects invalid options before creating anything' test_share_rejects_bad_options
run_test_needing 'share serves one download, then stops and removes everything' test_share_serves_one_download_and_removes_everything python3 curl
run_test_needing 'share --depth gives a shallow clone without the remote' test_share_depth_gives_a_shallow_clone_without_the_remote python3 curl
run_test_needing 'share --format zip with --max-downloads 2' test_share_zip_allows_several_downloads python3 curl
run_test_needing 'share stops on Ctrl-C, on hangup and after kill -9' test_share_stops_on_ctrl_c_on_hangup_and_after_kill_9 python3 curl
run_test_needing 'share stops after the time limit' test_share_stops_after_the_time_limit python3 curl
run_test_needing 'share --tls pins the throwaway certificate' test_share_tls_pins_the_certificate python3 curl openssl

if (( SKIP )); then
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
else
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
fi
(( FAIL == 0 ))
