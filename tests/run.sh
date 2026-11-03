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


run_test() {
  local name=$1 fn=$2
  if ( "$fn" ); then
    pass "$name"
  else
    fail "$name"
  fi
}

test_bash_syntax() {
  bash -n "$SCRIPT"
}

test_version() {
  local out
  out=$("$SCRIPT" version)
  assert_contains "$out" "0.2.6"
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

run_test 'bash syntax' test_bash_syntax
run_test 'version reports 0.2.6' test_version
run_test 'protected branch refex escapes regex characters' test_branch_refex_exact_escaping
run_test 'repository fragment names encode slashes' test_repo_fragment_name
run_test 'SSH port validation accepts only 1..65535' test_validate_port
run_test 'admin-init is idempotent' test_admin_init_idempotent
run_test 'repo-set generates least-privilege agent ACL without hardcoded main' test_repo_set_acl_and_no_hardcoded_main
run_test 'protected branches are exact and escaped' test_protected_branch_exact_and_escaped
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
