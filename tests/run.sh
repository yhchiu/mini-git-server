#!/usr/bin/env bash
# Test functions are intentionally invoked indirectly by run_test.
# shellcheck disable=SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/mini-git-server.sh"

PASS=0
FAIL=0
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
