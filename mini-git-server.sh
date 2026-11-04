#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM=${0##*/}
VERSION="0.3.0"
DEFAULT_GIT_USER="git"
DEFAULT_SSH_PORT="22"
DEFAULT_SSHD_DROPIN="/etc/ssh/sshd_config.d/90-gitolite.conf"
DEFAULT_SSHD_PORT_DROPIN="/etc/ssh/sshd_config.d/00-gitolite-port.conf"
# Named to sort last: in OpenSSH 10 the last MaxStartups setting wins, unlike
# most options, where the first one wins. ssh-limits checks the effective
# value after writing it, so either order is detected.
DEFAULT_SSHD_LIMITS_DROPIN="/etc/ssh/sshd_config.d/99-gitolite-limits.conf"
# Gitolite 3.6.12 (the Debian 13 package) only compiles pushes to this branch
# of gitolite-admin. Newer upstream releases follow the admin repository HEAD,
# which also works as long as HEAD points here.
GITOLITE_ADMIN_BRANCH="master"
SSH_HOST_KEY_DIR="/etc/ssh"

log()  { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
mini-git-server - minimal Git/Gitolite installation and administration helper

Usage:
  mini-git-server.sh <command> [options]

Server commands (run on the Git server):
  install         Install OpenSSH, Git and Gitolite, then initialize Gitolite
  status          Show Git/Gitolite/SSH status
  doctor          Run configuration and permission checks
  backup          Create a Git-aware mirror backup of all repositories
  fsck            Run git fsck on hosted repositories
  repo-set-default Set a repository HEAD/default branch
  host-keys       Print SSH host key fingerprints and known_hosts lines
  ssh-limits      Show or set how many SSH logins sshd accepts at once

Admin-workstation commands (run inside or against a gitolite-admin clone):
  admin-clone     Clone gitolite-admin from the server
  admin-init      Enable script-managed per-repository config fragments
  user-add        Add an SSH public key to gitolite-admin/keydir
  user-remove     Remove an SSH public key from gitolite-admin/keydir
  user-list       List Gitolite key identities
  repo-set        Create/replace a script-managed repository ACL
  repo-add        Alias for repo-set (backward compatibility)
  repo-show       Show repository ACL state and a reusable repo-set command
  repo-list       List configured repositories
  group-set       Create/replace a script-managed group (@NAME)
  group-remove    Remove a script-managed group
  group-list      List script-managed groups
  sync            Update gitolite-admin from origin, keeping staged changes
  apply           Review, commit and push gitolite-admin changes

Project commands (run inside a clone of a project repository):
  agent-branches  List agent branches and how far they are from the base branch

Deploy commands (run on any machine that can read the repository):
  share           Serve an archive of a branch or tag at a temporary random URL

Other:
  version         Show script version
  help            Show this help

Run '<command> --help' for command-specific usage.
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]]
}

require_root() {
  is_root || die "This command must be run as root."
}

# Print the Gitolite version, or "missing". Gitolite has no --version option;
# its version is in the VERSION file next to its programs.
gitolite_version() {
  local bindir
  bindir=$(cd / && gitolite query-rc GL_BINDIR 2>/dev/null) || { printf 'missing\n'; return 0; }
  head -n 1 "$bindir/VERSION" 2>/dev/null || printf 'unknown\n'
}

validate_simple_name() {
  local value=$1 label=$2
  [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]] || \
    die "$label contains unsupported characters: $value"
}

validate_unix_user() {
  local value=$1
  [[ $value =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid Unix user name: $value"
}

validate_repo_name() {
  local repo=$1
  [[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9_./-]*$ ]] || \
    die "Invalid repository name: $repo"
  [[ $repo != */ ]] || die "Repository name must not end with '/': $repo"
  [[ $repo != *".."* ]] || die "Repository name must not contain '..': $repo"
}

validate_port() {
  local port=$1
  if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    die "Invalid SSH port: $port"
  fi
}

validate_branch_name() {
  local branch=$1
  need_cmd git
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "Invalid branch name: $branch"
}

regex_escape() {
  local value=$1 out="" ch i
  for ((i=0; i<${#value}; i++)); do
    ch=${value:i:1}
    case "$ch" in
      '.'|$'\\'|'+'|'*'|'?'|'['|']'|'('|')'|'{'|'}'|'^'|'$'|'|') out+="\\$ch" ;;
      *) out+="$ch" ;;
    esac
  done
  printf '%s' "$out"
}

branch_refex_exact() {
  local branch=$1
  printf 'refs/heads/%s$' "$(regex_escape "$branch")"
}

csv_to_spaces() {
  local value=${1:-}
  printf '%s\n' "$value" \
    | tr ',' ' ' \
    | awk '{ for (i=1; i<=NF; i++) if (!seen[$i]++) out = out (out ? " " : "") $i } END { print out }'
}

validate_user_list() {
  local value=${1:-} item
  [[ -z $value ]] && return 0
  while IFS= read -r item; do
    [[ -z $item ]] && continue
    validate_simple_name "$item" "ACL user"
  done < <(printf '%s\n' "$value" | tr ' ' '\n')
}

repo_fragment_name() {
  local repo=$1
  printf '%s' "$repo" | sed 's/%/%25/g; s#/#%2F#g'
}

find_admin_dir() {
  local requested=${1:-}
  local dir
  if [[ -n $requested ]]; then
    dir=$(cd "$requested" 2>/dev/null && pwd) || die "Admin directory not found: $requested"
  else
    dir=$(pwd)
  fi

  [[ -d "$dir/.git" ]] || die "Not a gitolite-admin working tree: $dir"
  [[ -d "$dir/keydir" && -f "$dir/conf/gitolite.conf" ]] || \
    die "Missing keydir/ or conf/gitolite.conf in: $dir"
  printf '%s\n' "$dir"
}

# Print the Gitolite user that a keydir file name maps to. This copies
# Gitolite's own rule: "foo.pub" and "foo@laptop.pub" map to "foo", while
# "foo@example.com.pub" (a dot after the '@') maps to "foo@example.com".
gitolite_user_for_keyfile() {
  local base=${1##*/}
  printf '%s\n' "$base" | sed -E 's/(@[^.]+)?\.pub$//'
}

# Print every keydir file (relative to the admin directory) that maps to
# the Gitolite user NAME.
identity_key_files() {
  local dir=$1 name=$2 file
  [[ -d "$dir/keydir" ]] || return 0
  while IFS= read -r -d '' file; do
    if [[ $(gitolite_user_for_keyfile "$file") == "$name" ]]; then
      printf '%s\n' "${file#"$dir/"}"
    fi
  done < <(find "$dir/keydir" -type f -name '*.pub' -print0 | sort -z)
}

# Print the users that may push to gitolite-admin. The rules are read from
# the gitolite-admin block, and @groups in those rules are replaced by their
# members, using the group definitions in every conf file (including groups
# managed by group-set, and groups inside groups). @all is skipped, because
# it cannot be listed.
admin_identities() {
  local dir=$1
  local -a files=("$dir/conf/gitolite.conf")
  mapfile -t -O 1 files < <(find "$dir/conf" -type f -name '*.conf' ! -path "$dir/conf/gitolite.conf" | sort)
  awk '
    function add(name,    i, n, list) {
      if (name == "@all") return
      if (name !~ /^@/) {
        if (!seen[name]++) print name
        return
      }
      if (expanded[name]++) return
      n = split(members[name], list, " ")
      for (i = 1; i <= n; i++) add(list[i])
    }
    FNR == 1 { in_admin = 0 }
    { line = $0; sub(/#.*/, "", line) }
    line ~ /^[[:space:]]*@[^[:space:]=]+[[:space:]]*=/ {
      split(line, parts, "=")
      name = parts[1]
      gsub(/[[:space:]]/, "", name)
      members[name] = members[name] " " parts[2]
      next
    }
    line ~ /^[[:space:]]*repo[[:space:]]/ {
      n = split(line, words, " ")
      in_admin = 0
      for (i = 2; i <= n; i++) if (words[i] == "gitolite-admin") in_admin = 1
      next
    }
    in_admin && line ~ /^[[:space:]]*RW/ && index(line, "=") {
      split(line, parts, "=")
      n = split(parts[2], users, " ")
      for (i = 1; i <= n; i++) rule_users[++count] = users[i]
    }
    END { for (i = 1; i <= count; i++) add(rule_users[i]) }
  ' "${files[@]}"
}

# Succeed if NAME is one of the words in the space-separated LIST.
list_has() {
  local list=$1 name=$2 item
  local -a items=()
  IFS=' ' read -r -a items <<<"$list"
  for item in "${items[@]}"; do
    [[ $item == "$name" ]] && return 0
  done
  return 1
}

# Print the conf files (relative to the admin directory) whose access rules
# or group definitions name USER. Comment lines are ignored.
acl_references() {
  local dir=$1 name=$2 file
  while IFS= read -r -d '' file; do
    if awk -v n="$name" '
      /^[[:space:]]*#/ { next }
      index($0, "=") {
        sub(/#.*/, "")
        split($0, parts, "=")
        m = split(parts[2], users, " ")
        for (i = 1; i <= m; i++) if (users[i] == n) found = 1
      }
      END { exit !found }
    ' "$file"; then
      printf '%s\n' "${file#"$dir/"}"
    fi
  done < <(find "$dir/conf" -type f -name '*.conf' -print0 | sort -z)
}

# Agent names are inserted into the refex agent/USER/, so they must not
# contain characters with a special meaning there.
validate_agent_names() {
  local item
  local -a items=()
  IFS=' ' read -r -a items <<<"$1"
  for item in "${items[@]}"; do
    [[ $item == @* ]] && continue
    [[ $item =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || \
      die "Agent name '$item' may only use letters, digits, '-' and '_'. Gitolite puts it into the branch rule agent/USER/, where '.' or '@' would change what the rule matches."
  done
}

# Arguments: ROLE LIST [ROLE LIST]... Stop when one identity has two roles.
# For example, an agent that is also a writer could push to every branch.
check_role_overlap() {
  local role list item conflicts=""
  local -A role_of=()
  local -a items=()
  while (($#)); do
    role=$1 list=$2
    shift 2
    IFS=' ' read -r -a items <<<"$list"
    for item in "${items[@]}"; do
      if [[ -z ${role_of[$item]:-} ]]; then
        role_of[$item]=$role
      elif [[ ${role_of[$item]} != "$role" ]]; then
        conflicts+="${conflicts:+; }'$item' is both ${role_of[$item]} and $role"
      fi
    done
  done
  [[ -z $conflicts ]] || \
    die "Each identity may have only one role in a repository: $conflicts. Give each identity one role."
}

ensure_clean_or_staged_admin_repo() {
  local dir=$1
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a Git working tree: $dir"
}

validate_pubkey() {
  local key=$1
  [[ -f $key ]] || die "Public key file not found: $key"
  need_cmd ssh-keygen
  ssh-keygen -l -f "$key" >/dev/null 2>&1 || die "Invalid OpenSSH public key: $key"
  local key_type
  key_type=$(awk 'NF && $1 !~ /^#/ {print $1; exit}' "$key")
  case "$key_type" in
    ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa)
      ;;
    *) warn "Uncommon SSH public key type: ${key_type:-unknown}" ;;
  esac
}

# MaxStartups is START, or START:RATE:FULL (see sshd_config(5)).
validate_max_startups() {
  local value=$1 start rate full
  if [[ $value =~ ^([0-9]+)$ ]]; then
    start=${BASH_REMATCH[1]} rate=30 full=$start
  elif [[ $value =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    start=${BASH_REMATCH[1]} rate=${BASH_REMATCH[2]} full=${BASH_REMATCH[3]}
  else
    die "Invalid MaxStartups value: $value (use START or START:RATE:FULL, for example 50:30:200)"
  fi
  (( 10#$start >= 1 && 10#$rate >= 1 && 10#$rate <= 100 && 10#$start <= 10#$full )) || \
    die "Invalid MaxStartups value: $value (START must be at least 1 and at most FULL, and RATE between 1 and 100)"
}

# Print the MaxStartups value as sshd -T reports it ("20" becomes "20:30:20").
normalize_max_startups() {
  local value=$1
  [[ $value == *:* ]] || value="$value:30:$value"
  printf '%s\n' "$value"
}

effective_max_startups() {
  sshd -T 2>/dev/null | awk '$1 == "maxstartups" {print $2; exit}'
}

# Reload sshd when systemd runs it. Without systemd (for example in a
# container), systemctl cannot reload it, so only warn.
reload_sshd() {
  if [[ -d /run/systemd/system ]]; then
    systemctl reload ssh || systemctl restart ssh
  else
    warn "systemd is not running, so sshd was not reloaded. Start or reload sshd yourself to use the new SSH settings."
  fi
}

# Write MaxStartups to the managed drop-in. Restore the previous file when
# sshd rejects the result, or when another setting makes the value not apply.
write_max_startups_dropin() {
  local value=$1 previous="" effective expected
  expected=$(normalize_max_startups "$value")
  install -d -m 0755 /etc/ssh/sshd_config.d
  if [[ -f $DEFAULT_SSHD_LIMITS_DROPIN ]]; then
    previous=$(mktemp)
    cp -a "$DEFAULT_SSHD_LIMITS_DROPIN" "$previous"
  fi
  {
    printf '# Managed by mini-git-server.sh (ssh-limits)\n'
    printf '# Unauthenticated connections sshd accepts at once: START:RATE:FULL.\n'
    printf 'MaxStartups %s\n' "$value"
  } >"$DEFAULT_SSHD_LIMITS_DROPIN"
  chmod 0644 "$DEFAULT_SSHD_LIMITS_DROPIN"

  local problem=""
  if ! sshd -t; then
    problem="sshd rejected 'MaxStartups $value'"
  else
    effective=$(effective_max_startups)
    if [[ $effective != "$expected" ]]; then
      problem="sshd uses MaxStartups ${effective:-unknown}, not $expected: another MaxStartups line in the sshd configuration (for example in /etc/ssh/sshd_config after its Include line) overrides $DEFAULT_SSHD_LIMITS_DROPIN"
    fi
  fi
  if [[ -n $problem ]]; then
    if [[ -n $previous ]]; then
      cp -a "$previous" "$DEFAULT_SSHD_LIMITS_DROPIN"
      rm -f "$previous"
    else
      rm -f "$DEFAULT_SSHD_LIMITS_DROPIN"
    fi
    die "$problem. The previous setting was restored."
  fi
  [[ -z $previous ]] || rm -f "$previous"
}

server_install_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh install --admin-key FILE [options]

Required:
  --admin-key FILE       Admin OpenSSH public key

Options:
  --admin-name NAME      Gitolite admin identity (default: admin)
  --git-user USER        Hosting Unix account (default: git)
  --ssh-port PORT        Configure sshd listening port (default: 22)
  --default-branch NAME  Set Git init.defaultBranch for newly created repositories
  --max-startups VALUE   Set sshd MaxStartups (default: sshd's 10:30:100).
                         See 'ssh-limits --help'.
  --no-ssh-hardening     Do not install the Match User SSH hardening drop-in
  -h, --help

Notes:
  - Intended for a fresh Debian server.
  - The hosting account password is locked.
  - Gitolite controls ~/.ssh/authorized_keys; do not edit it manually later.
USAGE
}

# Stop if Gitolite is already set up for GIT_USER. install calls this before
# it changes anything, so a refused second run leaves the server unchanged.
refuse_if_initialized() {
  local git_user=$1 git_home="/home/$1"
  if id "$git_user" >/dev/null 2>&1; then
    git_home=$(getent passwd "$git_user" | cut -d: -f6)
    [[ -n $git_home ]] || die "Cannot determine home directory for user: $git_user"
  fi
  if [[ -e "$git_home/.gitolite" || -e "$git_home/repositories/gitolite-admin.git" ]]; then
    die "Gitolite already appears initialized for $git_user at $git_home; refusing to overwrite it."
  fi
  if [[ -s "$git_home/.ssh/authorized_keys" ]]; then
    die "$git_home/.ssh/authorized_keys is not empty. Use a fresh hosting account or migrate carefully."
  fi
}

# Create the hosting account if needed, then initialize Gitolite for it.
# Arguments: GIT_USER ADMIN_KEY ADMIN_NAME DEFAULT_BRANCH (may be empty).
init_hosting_account() {
  local git_user=$1 admin_key=$2 admin_name=$3 default_branch=$4
  local git_home
  refuse_if_initialized "$git_user"
  if id "$git_user" >/dev/null 2>&1; then
    git_home=$(getent passwd "$git_user" | cut -d: -f6)
    [[ -n $git_home ]] || die "Cannot determine home directory for user: $git_user"
  else
    git_home="/home/$git_user"
    log "Creating dedicated hosting account: $git_user"
    useradd --create-home --home-dir "$git_home" --shell /bin/bash "$git_user"
  fi

  passwd -l "$git_user" >/dev/null 2>&1 || true
  install -d -m 0700 -o "$git_user" -g "$git_user" "$git_home/.ssh"

  local temp_key="$git_home/${admin_name}.pub"
  install -m 0600 -o "$git_user" -g "$git_user" "$admin_key" "$temp_key"

  # Pin init.defaultBranch for setup only. Otherwise --default-branch, or an
  # init.defaultBranch already set for this account or system-wide, would put
  # gitolite-admin on a branch that Gitolite never compiles. GIT_CONFIG_COUNT
  # overrides both the global and the system Git configuration.
  log "Initializing Gitolite as '$git_user' with admin identity '$admin_name'"
  runuser -u "$git_user" -- env HOME="$git_home" \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=init.defaultBranch \
    GIT_CONFIG_VALUE_0="$GITOLITE_ADMIN_BRANCH" \
    gitolite setup -pk "$temp_key"
  rm -f "$temp_key"

  local admin_head
  admin_head=$(runuser -u "$git_user" -- git -C "$git_home/repositories/gitolite-admin.git" symbolic-ref HEAD)
  [[ $admin_head == "refs/heads/$GITOLITE_ADMIN_BRANCH" ]] || \
    die "gitolite-admin HEAD is '$admin_head', expected 'refs/heads/$GITOLITE_ADMIN_BRANCH'. Gitolite would ignore admin pushes."

  # Keep a reflog in every hosted repository, so commits that were
  # force-pushed away stay listed (and safe from gc) for a while.
  runuser -u "$git_user" -- env HOME="$git_home" git -C "$git_home" config --global core.logAllRefUpdates always

  # Set the default branch only after setup, so it affects repositories
  # created later (through gitolite-admin) but never gitolite-admin itself.
  # Use -C so Git does not try to read the caller's current directory, which
  # the hosting account may not be allowed to read (for example /root).
  if [[ -n $default_branch ]]; then
    log "Setting Git default branch for new repositories to '$default_branch'"
    runuser -u "$git_user" -- env HOME="$git_home" git -C "$git_home" config --global init.defaultBranch "$default_branch"
  fi
}

# Print the sshd drop-in that restricts the hosting account.
ssh_hardening_dropin() {
  local git_user=$1
  cat <<EOF_HARDEN
# Managed by mini-git-server.sh
# Gitolite itself installs per-key forced commands in authorized_keys.
# Do not add ForceCommand here.
Match User $git_user
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    X11Forwarding no
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTunnel no
    PermitTTY no
    # Let Git clients use protocol v2, which is faster for repositories
    # with many branches (for example many agent branches).
    AcceptEnv GIT_PROTOCOL

Match all
EOF_HARDEN
}

server_install() {
  require_root
  local admin_key="" admin_name="admin" git_user=$DEFAULT_GIT_USER ssh_port=$DEFAULT_SSH_PORT
  local default_branch="" harden=1 max_startups=""

  while (($#)); do
    case "$1" in
      --admin-key) [[ $# -ge 2 ]] || die "--admin-key requires a value"; admin_key=$2; shift 2 ;;
      --admin-name) [[ $# -ge 2 ]] || die "--admin-name requires a value"; admin_name=$2; shift 2 ;;
      --git-user) [[ $# -ge 2 ]] || die "--git-user requires a value"; git_user=$2; shift 2 ;;
      --ssh-port) [[ $# -ge 2 ]] || die "--ssh-port requires a value"; ssh_port=$2; shift 2 ;;
      --default-branch) [[ $# -ge 2 ]] || die "--default-branch requires a value"; default_branch=$2; shift 2 ;;
      --max-startups) [[ $# -ge 2 ]] || die "--max-startups requires a value"; max_startups=$2; shift 2 ;;
      --no-ssh-hardening) harden=0; shift ;;
      -h|--help) server_install_usage; return 0 ;;
      *) die "Unknown install option: $1" ;;
    esac
  done

  [[ -n $admin_key ]] || die "--admin-key is required"
  validate_pubkey "$admin_key"
  validate_simple_name "$admin_name" "Admin name"
  validate_unix_user "$git_user"
  validate_port "$ssh_port"
  [[ -z $max_startups ]] || validate_max_startups "$max_startups"

  [[ -r /etc/os-release ]] || die "Cannot identify operating system"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == "debian" ]] || die "This installer currently supports Debian only (detected: ${ID:-unknown})"
  if [[ ${VERSION_ID:-} != "13" ]]; then
    warn "Designed for Debian 13; detected Debian ${VERSION_ID:-unknown}. Continuing with distro packages."
  fi
  # Check before installing packages or touching the SSH configuration.
  refuse_if_initialized "$git_user"

  export DEBIAN_FRONTEND=noninteractive
  log "Installing Debian packages: openssh-server git gitolite3 ca-certificates"
  apt-get update
  apt-get install -y openssh-server git gitolite3 ca-certificates

  need_cmd git
  need_cmd sshd
  need_cmd runuser
  need_cmd gitolite
  [[ -z $default_branch ]] || validate_branch_name "$default_branch"

  install -d -m 0755 /etc/ssh/sshd_config.d
  local previous_port_dropin=""
  if [[ -f $DEFAULT_SSHD_PORT_DROPIN ]]; then
    previous_port_dropin=$(mktemp)
    cp -a "$DEFAULT_SSHD_PORT_DROPIN" "$previous_port_dropin"
  fi
  cat >"$DEFAULT_SSHD_PORT_DROPIN" <<EOF_PORT
# Managed by mini-git-server.sh
Port $ssh_port
EOF_PORT
  chmod 0644 "$DEFAULT_SSHD_PORT_DROPIN"

  if ! sshd -t; then
    if [[ -n $previous_port_dropin ]]; then
      cp -a "$previous_port_dropin" "$DEFAULT_SSHD_PORT_DROPIN"
      rm -f "$previous_port_dropin"
    else
      rm -f "$DEFAULT_SSHD_PORT_DROPIN"
    fi
    die "sshd validation failed after configuring SSH port $ssh_port; previous SSH port configuration was restored."
  fi

  local effective_ports
  effective_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -nu | paste -sd, -)
  if [[ -n $effective_ports && ",$effective_ports," != *",$ssh_port,"* ]]; then
    if [[ -n $previous_port_dropin ]]; then
      cp -a "$previous_port_dropin" "$DEFAULT_SSHD_PORT_DROPIN"
      rm -f "$previous_port_dropin"
    else
      rm -f "$DEFAULT_SSHD_PORT_DROPIN"
    fi
    die "sshd does not report requested port $ssh_port as active configuration (effective ports: $effective_ports). Previous SSH port configuration was restored; check Include ordering in /etc/ssh/sshd_config."
  fi
  if [[ $effective_ports == *,* ]]; then
    warn "sshd has multiple configured ports ($effective_ports). Another active Port directive exists outside $DEFAULT_SSHD_PORT_DROPIN."
  fi
  [[ -z $previous_port_dropin ]] || rm -f "$previous_port_dropin"
  [[ -z $max_startups ]] || write_max_startups_dropin "$max_startups"

  init_hosting_account "$git_user" "$admin_key" "$admin_name" "$default_branch"
  local git_home
  git_home=$(getent passwd "$git_user" | cut -d: -f6)

  if (( harden )); then
    install -d -m 0755 /etc/ssh/sshd_config.d
    local tmp_dropin
    tmp_dropin=$(mktemp)
    ssh_hardening_dropin "$git_user" >"$tmp_dropin"
    install -m 0644 "$tmp_dropin" "$DEFAULT_SSHD_DROPIN"
    rm -f "$tmp_dropin"

    if ! sshd -t; then
      rm -f "$DEFAULT_SSHD_DROPIN"
      die "sshd validation failed; hardening drop-in was removed. Gitolite itself is installed."
    fi
  fi

  reload_sshd
  log "Installation complete."
  cat <<EOF_RESULT

Server summary
  Hosting user : $git_user
  Home         : $git_home
  SSH port     : $ssh_port
  Default branch: ${default_branch:-Git default}
  Admin user   : $admin_name
  Repositories : $git_home/repositories

From the admin workstation (using the private key matching $admin_key):
  ssh -p $ssh_port $git_user@<server> info
  GIT_SSH_COMMAND="ssh -p $ssh_port" git clone $git_user@<server>:gitolite-admin

Recommended next step:
  mini-git-server.sh admin-init --admin-dir ./gitolite-admin

EOF_RESULT
  server_host_keys --port "$ssh_port"
}

server_host_keys_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh host-keys [--host NAME] [--port PORT]

Print this server's SSH host key fingerprints and known_hosts lines.

Options:
  --host NAME   Host name that clients use (default: this host's FQDN)
  --port PORT   SSH port that clients use (default: the port sshd uses)
  -h, --help

Copy the known_hosts lines to admin workstations and agent hosts over a
channel you trust, and use 'StrictHostKeyChecking yes' there. Then no
machine has to accept an unknown host key, and an agent that runs without
a terminal does not get stuck at the host key prompt.
USAGE
}

server_host_keys() {
  local host="" port=""
  while (($#)); do
    case "$1" in
      --host) [[ $# -ge 2 ]] || die "--host requires a value"; host=$2; shift 2 ;;
      --port) [[ $# -ge 2 ]] || die "--port requires a value"; port=$2; shift 2 ;;
      -h|--help) server_host_keys_usage; return 0 ;;
      *) die "Unknown host-keys option: $1" ;;
    esac
  done
  need_cmd ssh-keygen
  [[ -n $host ]] || host=$(hostname -f 2>/dev/null || hostname)
  [[ -n $host && $host != *[[:space:]]* ]] || die "Invalid host name: $host"
  if [[ -z $port ]]; then
    port=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)
    if [[ -z $port ]]; then
      port=$DEFAULT_SSH_PORT
      warn "Could not read the SSH port from sshd (run as root, or pass --port). Using $port."
    fi
  fi
  validate_port "$port"

  local key_file known_host=$host
  local -a key_files=()
  mapfile -t key_files < <(find "$SSH_HOST_KEY_DIR" -maxdepth 1 -type f -name 'ssh_host_*_key.pub' | sort)
  (( ${#key_files[@]} > 0 )) || die "No SSH host keys found in $SSH_HOST_KEY_DIR"
  [[ $port == 22 ]] || known_host="[$host]:$port"

  printf 'SSH host key fingerprints for %s:\n' "$host"
  for key_file in "${key_files[@]}"; do
    printf '  %s\n' "$(ssh-keygen -lf "$key_file")"
  done
  printf '\nknown_hosts lines (replace %s with the name clients use, if different):\n' "$host"
  for key_file in "${key_files[@]}"; do
    awk -v h="$known_host" 'NF && $1 !~ /^#/ {print h, $1, $2; exit}' "$key_file"
  done
}

server_ssh_limits_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh ssh-limits                         Show the current value
  mini-git-server.sh ssh-limits --max-startups VALUE    Set it
  mini-git-server.sh ssh-limits --reset                 Go back to sshd's default

MaxStartups limits how many SSH connections may be waiting to log in at the
same time. VALUE is START:RATE:FULL: once START connections are waiting,
sshd drops new ones at random (RATE percent), and at FULL it drops all of
them. The sshd default is 10:30:100. When many agents connect at the same
moment and some fail with "Connection closed", raise it, for example to
50:30:200.

The value is written to /etc/ssh/sshd_config.d/99-gitolite-limits.conf and
checked with sshd before sshd is reloaded. If sshd rejects it, or another
MaxStartups line overrides it, the previous setting is restored.
USAGE
}

server_ssh_limits() {
  local value="" reset=0
  while (($#)); do
    case "$1" in
      --max-startups) [[ $# -ge 2 ]] || die "--max-startups requires a value"; value=$2; shift 2 ;;
      --reset) reset=1; shift ;;
      -h|--help) server_ssh_limits_usage; return 0 ;;
      *) die "Unknown ssh-limits option: $1" ;;
    esac
  done
  [[ -z $value || $reset -eq 0 ]] || die "Use either --max-startups or --reset, not both"
  require_root
  need_cmd sshd

  if [[ -n $value ]]; then
    validate_max_startups "$value"
    write_max_startups_dropin "$value"
    reload_sshd
    log "MaxStartups is now $(effective_max_startups)."
  elif (( reset )); then
    if [[ -f $DEFAULT_SSHD_LIMITS_DROPIN ]]; then
      rm -f "$DEFAULT_SSHD_LIMITS_DROPIN"
      sshd -t || die "sshd configuration is invalid after removing $DEFAULT_SSHD_LIMITS_DROPIN"
      reload_sshd
    fi
    log "MaxStartups is now $(effective_max_startups) (no managed setting)."
  else
    local source="sshd default or other configuration"
    [[ -f $DEFAULT_SSHD_LIMITS_DROPIN ]] && source=$DEFAULT_SSHD_LIMITS_DROPIN
    printf 'MaxStartups: %s (%s)\n' "$(effective_max_startups)" "$source"
  fi
}

server_status_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh status [--git-user USER]
USAGE
}

server_status() {
  local git_user=$DEFAULT_GIT_USER
  while (($#)); do
    case "$1" in
      --git-user) [[ $# -ge 2 ]] || die "--git-user requires a value"; git_user=$2; shift 2 ;;
      -h|--help) server_status_usage; return 0 ;;
      *) die "Unknown status option: $1" ;;
    esac
  done
  validate_unix_user "$git_user"
  id "$git_user" >/dev/null 2>&1 || die "User does not exist: $git_user"

  local git_home root=1 needs_root="(needs root)" value
  git_home=$(getent passwd "$git_user" | cut -d: -f6)
  is_root || root=0
  if (( ! root )); then
    warn "Not running as root: fields that only root can read show '$needs_root'. Run it with sudo for complete results."
  fi
  printf 'mini-git-server %s\n\n' "$VERSION"
  printf '%-20s %s\n' "Hosting user:" "$git_user"
  printf '%-20s %s\n' "Home:" "$git_home"
  printf '%-20s %s\n' "Git:" "$(git --version 2>/dev/null || echo missing)"
  printf '%-20s %s\n' "Gitolite:" "$(gitolite_version)"

  # Each field prints exactly one value. A failing command must not leave
  # its partial output in front of the fallback text.
  value=$(systemctl is-active ssh 2>/dev/null | head -n 1) || true
  printf '%-20s %s\n' "SSH service:" "${value:-unknown}"

  value=$needs_root
  if (( root )); then
    value=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -nu | paste -sd, -) || true
    value=${value:-unknown}
  fi
  printf '%-20s %s\n' "SSH ports:" "$value"

  value=$needs_root
  if (( root )); then
    value=$(effective_max_startups) || true
    value=${value:-unknown}
  fi
  printf '%-20s %s\n' "SSH MaxStartups:" "$value"

  value=$needs_root
  if (( root )); then
    value=$(runuser -u "$git_user" -- env HOME="$git_home" git -C "$git_home" config --global --get init.defaultBranch 2>/dev/null) || true
    value=${value:-Git-default}
  fi
  printf '%-20s %s\n' "Default branch:" "$value"

  value=$needs_root
  if (( root )); then
    value=$(passwd -S "$git_user" 2>/dev/null | awk '{print $2}') || true
    value=${value:-unknown}
  fi
  printf '%-20s %s\n' "Password status:" "$value"

  # The hosting account's home is often not readable by other users.
  local repo_count=$needs_root repo_storage=$needs_root
  if (( root )) || [[ -x $git_home ]]; then
    repo_count=0
    repo_storage=n/a
    if [[ -d "$git_home/repositories" ]]; then
      repo_count=$(find "$git_home/repositories" -type d -name '*.git' -prune 2>/dev/null | wc -l)
      repo_storage=$(du -sh "$git_home/repositories" 2>/dev/null | awk '{print $1}') || true
      repo_storage=${repo_storage:-n/a}
    fi
  fi
  printf '%-20s %s\n' "Repository count:" "$repo_count"
  printf '%-20s %s\n' "Repository storage:" "$repo_storage"
  local ssh_port_config="unmanaged" ssh_hardening="not-installed"
  [[ -f $DEFAULT_SSHD_PORT_DROPIN ]] && ssh_port_config="managed"
  [[ -f $DEFAULT_SSHD_DROPIN ]] && ssh_hardening="installed"
  printf '%-20s %s\n' "SSH port config:" "$ssh_port_config"
  printf '%-20s %s\n' "SSH hardening:" "$ssh_hardening"
}

server_doctor_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh doctor [--git-user USER]
USAGE
}

server_doctor() {
  require_root
  local git_user=$DEFAULT_GIT_USER errors=0 warnings=0
  while (($#)); do
    case "$1" in
      --git-user) [[ $# -ge 2 ]] || die "--git-user requires a value"; git_user=$2; shift 2 ;;
      -h|--help) server_doctor_usage; return 0 ;;
      *) die "Unknown doctor option: $1" ;;
    esac
  done

  check_ok()   { printf '[ OK ] %s\n' "$*"; }
  check_warn() { printf '[WARN] %s\n' "$*"; warnings=$((warnings+1)); }
  check_bad()  { printf '[FAIL] %s\n' "$*"; errors=$((errors+1)); }

  for dependency in git gitolite sshd; do
    if command -v "$dependency" >/dev/null 2>&1; then
      check_ok "$dependency is installed"
    else
      check_bad "$dependency is missing"
    fi
  done

  if sshd -t; then check_ok "sshd configuration is valid"; else check_bad "sshd configuration is invalid"; fi
  if systemctl is-active --quiet ssh; then check_ok "ssh service is active"; else check_bad "ssh service is not active"; fi

  if ! id "$git_user" >/dev/null 2>&1; then
    check_bad "hosting user '$git_user' does not exist"
    printf '\nDoctor summary: %d failure(s), %d warning(s)\n' "$errors" "$warnings"
    return 1
  fi

  local git_home
  git_home=$(getent passwd "$git_user" | cut -d: -f6)
  if [[ -d "$git_home/.gitolite" ]]; then
    check_ok ".gitolite exists"
  else
    check_bad ".gitolite is missing"
  fi
  if [[ -d "$git_home/repositories/gitolite-admin.git" ]]; then
    check_ok "gitolite-admin repository exists"
    local admin_repo="$git_home/repositories/gitolite-admin.git" admin_head
    admin_head=$(runuser -u "$git_user" -- git -C "$admin_repo" symbolic-ref --quiet HEAD 2>/dev/null || true)
    if [[ $admin_head != "refs/heads/$GITOLITE_ADMIN_BRANCH" ]]; then
      check_bad "gitolite-admin HEAD is '${admin_head:-unknown}', expected refs/heads/$GITOLITE_ADMIN_BRANCH; Gitolite ignores admin pushes (see README: Repair an admin repository on the wrong branch)"
    elif ! runuser -u "$git_user" -- git -C "$admin_repo" show-ref --verify --quiet "refs/heads/$GITOLITE_ADMIN_BRANCH"; then
      check_bad "gitolite-admin has no '$GITOLITE_ADMIN_BRANCH' branch yet (see README: Repair an admin repository on the wrong branch)"
    else
      check_ok "gitolite-admin uses the '$GITOLITE_ADMIN_BRANCH' branch"
    fi
  else
    check_bad "gitolite-admin repository is missing"
  fi
  if [[ -f "$git_home/.ssh/authorized_keys" ]]; then
    check_ok "authorized_keys exists"
  else
    check_bad "authorized_keys is missing"
  fi

  if [[ -f "$git_home/.ssh/authorized_keys" ]]; then
    local unforced
    unforced=$(awk 'NF && $1 !~ /^#/ && $0 !~ /command=/ {n++} END {print n+0}' "$git_home/.ssh/authorized_keys")
    if (( unforced == 0 )); then
      check_ok "all non-comment authorized_keys entries have forced commands"
    else
      local entry_word="entries"
      (( unforced == 1 )) && entry_word="entry"
      check_warn "$unforced authorized_keys $entry_word lack command= restrictions"
    fi
  fi

  local home_owner
  home_owner=$(stat -c '%U:%G' "$git_home")
  if [[ $home_owner == "$git_user:$git_user" ]]; then
    check_ok "home directory owner is $git_user:$git_user"
  else
    check_warn "home owner is $home_owner"
  fi

  if [[ -d "$git_home/repositories" ]]; then
    local foreign_owned
    foreign_owned=$(find "$git_home/repositories" \! -user "$git_user" -print -quit 2>/dev/null || true)
    if [[ -z $foreign_owned ]]; then
      check_ok "repository tree is owned by $git_user"
    else
      check_warn "repository tree contains files not owned by $git_user (example: $foreign_owned)"
    fi
  fi

  local pass_state
  pass_state=$(passwd -S "$git_user" 2>/dev/null | awk '{print $2}')
  case "$pass_state" in
    L|LK) check_ok "hosting account password is locked" ;;
    *) check_warn "hosting account password state is '$pass_state' (expected locked)" ;;
  esac

  local log_refs
  log_refs=$(runuser -u "$git_user" -- env HOME="$git_home" git -C "$git_home" config --global --get core.logAllRefUpdates 2>/dev/null || true)
  if [[ $log_refs == always ]]; then
    check_ok "hosted repositories keep reflogs (core.logAllRefUpdates=always)"
  else
    check_warn "hosted repositories keep no reflog, so force-pushed commits are harder to recover; enable it with: sudo runuser -u $git_user -- git -C $git_home config --global core.logAllRefUpdates always"
  fi

  if [[ -f $DEFAULT_SSHD_PORT_DROPIN ]]; then
    check_ok "managed SSH port drop-in is installed"
  else
    check_warn "managed SSH port drop-in is not installed"
  fi

  if [[ -f $DEFAULT_SSHD_DROPIN ]]; then
    check_ok "SSH hardening drop-in is installed"
  else
    check_warn "SSH hardening drop-in is not installed"
  fi

  # Ask sshd for the effective settings of a connection as the hosting user.
  if command -v sshd >/dev/null 2>&1; then
    if sshd -T -C "user=$git_user,host=localhost,addr=127.0.0.1" 2>/dev/null \
      | awk '$1 == "acceptenv" && $2 == "GIT_PROTOCOL" {found = 1} END {exit !found}'; then
      check_ok "sshd accepts GIT_PROTOCOL for $git_user (Git protocol v2)"
    else
      check_warn "sshd does not accept GIT_PROTOCOL for $git_user, so Git uses the slower protocol v0 (see README: Many agents at once)"
    fi
  fi

  # sshkeys-lint reads ~/.ssh/authorized_keys only when stdin is a terminal.
  # Otherwise it reads the keys from stdin, so under cron or CI it either
  # waits forever or checks nothing. Pass the file on stdin explicitly.
  if [[ -f "$git_home/.ssh/authorized_keys" ]] && \
    runuser -u "$git_user" -- env HOME="$git_home" gitolite sshkeys-lint \
      <"$git_home/.ssh/authorized_keys" >/dev/null 2>&1; then
    check_ok "gitolite sshkeys-lint passed"
  else
    check_warn "gitolite sshkeys-lint returned a non-zero status; run it manually for details"
  fi

  printf '\nDoctor summary: %d failure(s), %d warning(s)\n' "$errors" "$warnings"
  (( errors == 0 ))
}

server_backup_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh backup [options]

Options:
  --git-user USER      Hosting Unix account (default: git)
  --output DIR         Backup parent directory (default: /var/backups/gitolite)
  -h, --help

The backup uses 'git clone --mirror' via file:// for each repository, avoiding
filesystem-level copies of repositories while pushes may be occurring. The
source repositories are read by 'git upload-pack' running as the hosting
account; the backup itself is written and checked by root.
USAGE
}

server_backup() {
  require_root
  local git_user=$DEFAULT_GIT_USER output="/var/backups/gitolite"
  while (($#)); do
    case "$1" in
      --git-user) [[ $# -ge 2 ]] || die "--git-user requires a value"; git_user=$2; shift 2 ;;
      --output) [[ $# -ge 2 ]] || die "--output requires a value"; output=$2; shift 2 ;;
      -h|--help) server_backup_usage; return 0 ;;
      *) die "Unknown backup option: $1" ;;
    esac
  done

  validate_unix_user "$git_user"
  id "$git_user" >/dev/null 2>&1 || die "User does not exist: $git_user"
  need_cmd runuser
  local git_home repos_root stamp backup_dir upload_pack
  git_home=$(getent passwd "$git_user" | cut -d: -f6)
  repos_root="$git_home/repositories"
  [[ -d $repos_root ]] || die "Repository directory not found: $repos_root"

  # Read each repository through git upload-pack running as the hosting
  # account. Git refuses to open a repository owned by another user
  # ("detected dubious ownership"), so a plain clone as root fails. This
  # also means root never runs Git inside a repository it does not own;
  # root only writes and checks its own new mirror.
  printf -v upload_pack 'runuser -u %q -- env HOME=%q git upload-pack' "$git_user" "$git_home"

  stamp=$(date '+%Y%m%d-%H%M%S')
  backup_dir="$output/$stamp"
  install -d -m 0700 "$backup_dir/repos" "$backup_dir/meta"

  log "Creating mirror backup in $backup_dir"
  local repo rel dest count=0 failed=0
  while IFS= read -r -d '' repo; do
    rel=${repo#"$repos_root/"}
    dest="$backup_dir/repos/$rel"
    mkdir -p "$(dirname "$dest")"
    log "Backing up $rel"
    if git clone --quiet --mirror --upload-pack="$upload_pack" "file://$repo" "$dest" \
      && git -C "$dest" fsck --full --no-dangling >/dev/null; then
      count=$((count+1))
    else
      warn "Backup failed for $rel"
      failed=$((failed+1))
    fi
  done < <(find "$repos_root" -type d -name '*.git' -prune -print0)

  if [[ -f "$git_home/.gitolite.rc" ]]; then
    cp -a "$git_home/.gitolite.rc" "$backup_dir/meta/"
  fi
  if [[ -f $DEFAULT_SSHD_PORT_DROPIN ]]; then
    cp -a "$DEFAULT_SSHD_PORT_DROPIN" "$backup_dir/meta/"
  fi
  if [[ -f $DEFAULT_SSHD_DROPIN ]]; then
    cp -a "$DEFAULT_SSHD_DROPIN" "$backup_dir/meta/"
  fi
  if [[ -f $DEFAULT_SSHD_LIMITS_DROPIN ]]; then
    cp -a "$DEFAULT_SSHD_LIMITS_DROPIN" "$backup_dir/meta/"
  fi
  {
    printf 'created=%s\n' "$(date --iso-8601=seconds)"
    printf 'host=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'git_user=%s\n' "$git_user"
    printf 'git_version=%s\n' "$(git --version)"
    printf 'gitolite_version=%s\n' "$(gitolite_version)"
    printf 'repositories=%d\n' "$count"
    printf 'failed=%d\n' "$failed"
    dpkg-query -W -f='package=${binary:Package} version=${Version}\n' git openssh-server gitolite3 2>/dev/null || true
  } >"$backup_dir/meta/manifest.txt"

  if (( failed > 0 )); then
    die "Backup completed with $failed failed repository/repositories. Partial backup: $backup_dir"
  fi
  printf '%s\n' "$backup_dir"
}

server_fsck_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh fsck [--git-user USER] [--repo REPO]

Without --repo, checks every hosted repository.
USAGE
}

server_fsck() {
  require_root
  local git_user=$DEFAULT_GIT_USER only_repo=""
  while (($#)); do
    case "$1" in
      --git-user) [[ $# -ge 2 ]] || die "--git-user requires a value"; git_user=$2; shift 2 ;;
      --repo) [[ $# -ge 2 ]] || die "--repo requires a value"; only_repo=$2; shift 2 ;;
      -h|--help) server_fsck_usage; return 0 ;;
      *) die "Unknown fsck option: $1" ;;
    esac
  done
  id "$git_user" >/dev/null 2>&1 || die "User does not exist: $git_user"
  local git_home repos_root failures=0
  git_home=$(getent passwd "$git_user" | cut -d: -f6)
  repos_root="$git_home/repositories"

  if [[ -n $only_repo ]]; then
    validate_repo_name "$only_repo"
    local path="$repos_root/$only_repo.git"
    [[ -d $path ]] || die "Repository not found: $only_repo"
    runuser -u "$git_user" -- git -C "$path" fsck --full
    return
  fi

  local repo rel
  while IFS= read -r -d '' repo; do
    rel=${repo#"$repos_root/"}
    printf '== %s ==\n' "$rel"
    if ! runuser -u "$git_user" -- git -C "$repo" fsck --full; then
      failures=$((failures+1))
    fi
  done < <(find "$repos_root" -type d -name '*.git' -prune -print0)

  (( failures == 0 )) || die "$failures repository/repositories failed fsck"
}

server_repo_set_default_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh repo-set-default --repo NAME --branch BRANCH [options]

Options:
  --repo NAME          Repository name (required)
  --branch BRANCH      Branch to point repository HEAD at (required)
  --git-user USER      Hosting Unix account (default: git)
  --require-existing   Fail unless refs/heads/BRANCH already exists
  -h, --help

By default, HEAD may point to an unborn branch. This is useful for an empty
repository before its first push.
USAGE
}

server_repo_set_default() {
  require_root
  local repo="" branch="" git_user=$DEFAULT_GIT_USER require_existing=0
  while (($#)); do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die "--repo requires a value"; repo=$2; shift 2 ;;
      --branch) [[ $# -ge 2 ]] || die "--branch requires a value"; branch=$2; shift 2 ;;
      --git-user) [[ $# -ge 2 ]] || die "--git-user requires a value"; git_user=$2; shift 2 ;;
      --require-existing) require_existing=1; shift ;;
      -h|--help) server_repo_set_default_usage; return 0 ;;
      *) die "Unknown repo-set-default option: $1" ;;
    esac
  done

  [[ -n $repo && -n $branch ]] || die "--repo and --branch are required"
  validate_repo_name "$repo"
  validate_branch_name "$branch"
  validate_unix_user "$git_user"
  if [[ $repo == gitolite-admin && $branch != "$GITOLITE_ADMIN_BRANCH" ]]; then
    die "gitolite-admin must use the '$GITOLITE_ADMIN_BRANCH' branch; Gitolite ignores pushes to any other branch of it."
  fi
  id "$git_user" >/dev/null 2>&1 || die "User does not exist: $git_user"

  local git_home path
  git_home=$(getent passwd "$git_user" | cut -d: -f6)
  path="$git_home/repositories/$repo.git"
  [[ -d $path ]] || die "Repository not found: $repo"

  if (( require_existing )) && ! runuser -u "$git_user" -- git -C "$path" show-ref --verify --quiet "refs/heads/$branch"; then
    die "Branch does not exist in repository: $branch"
  fi

  runuser -u "$git_user" -- git -C "$path" symbolic-ref HEAD "refs/heads/$branch"
  log "Default branch for '$repo' is now '$branch'."
}

admin_clone_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh admin-clone --host HOST [options]

Options:
  --host HOST           Git server hostname/IP (required)
  --ssh-user USER       SSH hosting user (default: git)
  --port PORT           SSH port (default: 22)
  --dir DIR             Destination (default: ./gitolite-admin)
  --identity FILE       SSH private key to use
  -h, --help
USAGE
}

admin_clone() {
  local host="" ssh_user=$DEFAULT_GIT_USER port=$DEFAULT_SSH_PORT dir="gitolite-admin" identity=""
  while (($#)); do
    case "$1" in
      --host) [[ $# -ge 2 ]] || die "--host requires a value"; host=$2; shift 2 ;;
      --ssh-user) [[ $# -ge 2 ]] || die "--ssh-user requires a value"; ssh_user=$2; shift 2 ;;
      --port) [[ $# -ge 2 ]] || die "--port requires a value"; port=$2; shift 2 ;;
      --dir) [[ $# -ge 2 ]] || die "--dir requires a value"; dir=$2; shift 2 ;;
      --identity) [[ $# -ge 2 ]] || die "--identity requires a value"; identity=$2; shift 2 ;;
      -h|--help) admin_clone_usage; return 0 ;;
      *) die "Unknown admin-clone option: $1" ;;
    esac
  done
  [[ -n $host ]] || die "--host is required"
  [[ $host != *[[:space:]]* ]] || die "Host must not contain whitespace"
  validate_unix_user "$ssh_user"
  validate_port "$port"
  need_cmd git
  need_cmd ssh
  [[ ! -e $dir ]] || die "Destination already exists: $dir"

  local ssh_cmd="ssh -p $port" quoted_identity
  if [[ -n $identity ]]; then
    [[ -f $identity ]] || die "Identity file not found: $identity"
    printf -v quoted_identity '%q' "$identity"
    ssh_cmd+=" -o IdentitiesOnly=yes -i $quoted_identity"
  fi

  GIT_SSH_COMMAND="$ssh_cmd" git clone "$ssh_user@$host:gitolite-admin" "$dir"
  log "Cloned gitolite-admin to $dir"
}

admin_init_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh admin-init [--admin-dir DIR]

Makes sure conf/gitolite.conf contains these lines, in this order:
  include "groups/*.conf"
  include "repos/*.conf"

and creates conf/groups/ and conf/repos/. Script-managed groups and
repository ACLs are stored there. Gitolite needs a group to be defined
before a rule uses it, so the groups include always comes first.

Running it again is safe. On a working tree set up before 0.3.0, it
adds the groups include in front of the existing repos include.
USAGE
}

ADMIN_GROUPS_INCLUDE='include "groups/*.conf"'
ADMIN_REPOS_INCLUDE='include "repos/*.conf"'

admin_init() {
  local requested=""
  while (($#)); do
    case "$1" in
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -h|--help) admin_init_usage; return 0 ;;
      *) die "Unknown admin-init option: $1" ;;
    esac
  done
  local dir conf tmp
  dir=$(find_admin_dir "$requested")
  ensure_clean_or_staged_admin_repo "$dir"
  conf="$dir/conf/gitolite.conf"
  mkdir -p "$dir/conf/repos" "$dir/conf/groups"

  if ! grep -Fqx "$ADMIN_REPOS_INCLUDE" "$conf"; then
    printf '\n# Script-managed groups and repository ACLs\n%s\n' "$ADMIN_REPOS_INCLUDE" >>"$conf"
    log "Added $ADMIN_REPOS_INCLUDE to conf/gitolite.conf"
  else
    log "Repository fragment include already present"
  fi

  # Put the groups include directly before the first repos include, and
  # nowhere else.
  tmp=$(mktemp)
  awk -v g="$ADMIN_GROUPS_INCLUDE" -v r="$ADMIN_REPOS_INCLUDE" '
    $0 == g { next }
    $0 == r && !done { print g; done = 1 }
    { print }
  ' "$conf" >"$tmp"
  if ! cmp -s "$tmp" "$conf"; then
    cat "$tmp" >"$conf"
    log "Placed $ADMIN_GROUPS_INCLUDE before $ADMIN_REPOS_INCLUDE in conf/gitolite.conf"
  fi
  rm -f "$tmp"

  touch "$dir/conf/repos/.gitkeep" "$dir/conf/groups/.gitkeep"
  git -C "$dir" add conf/gitolite.conf conf/repos/.gitkeep conf/groups/.gitkeep
  git -C "$dir" status --short
}

user_add_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh user-add --name USER --key FILE [options]

Options:
  --name USER           Logical Gitolite identity (required)
  --key FILE            OpenSSH public key (required)
  --key-id ID           Device/key label. Stores keydir/ID/USER.pub
                        so several keys can map to the same USER.
  --admin-dir DIR       gitolite-admin working tree (default: current dir)
  --replace             Replace an existing key at the same key path
  -h, --help
USAGE
}

user_add() {
  local name="" key="" key_id="" requested="" replace=0
  while (($#)); do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "--name requires a value"; name=$2; shift 2 ;;
      --key) [[ $# -ge 2 ]] || die "--key requires a value"; key=$2; shift 2 ;;
      --key-id) [[ $# -ge 2 ]] || die "--key-id requires a value"; key_id=$2; shift 2 ;;
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      --replace) replace=1; shift ;;
      -h|--help) user_add_usage; return 0 ;;
      *) die "Unknown user-add option: $1" ;;
    esac
  done
  [[ -n $name && -n $key ]] || die "--name and --key are required"
  validate_simple_name "$name" "User name"
  [[ -z $key_id ]] || validate_simple_name "$key_id" "Key ID"
  local mapped
  mapped=$(gitolite_user_for_keyfile "$name.pub")
  [[ $mapped == "$name" ]] || \
    die "Gitolite would read the key file '$name.pub' as user '$mapped', not '$name'. Use --key-id to label a device instead of '@'."
  validate_pubkey "$key"
  local dir dest
  dir=$(find_admin_dir "$requested")
  if [[ -n $key_id ]]; then
    dest="$dir/keydir/$key_id/$name.pub"
  else
    dest="$dir/keydir/$name.pub"
  fi
  if [[ -e $dest && $replace -ne 1 ]]; then
    die "Key already exists: ${dest#"$dir/"} (use --replace to replace it)"
  fi

  # sshd uses the first matching key, so a key stored for two identities
  # silently acts as only one of them.
  local blob existing
  blob=$(awk 'NF && $1 !~ /^#/ {print $2; exit}' "$key")
  while IFS= read -r -d '' existing; do
    [[ $existing == "$dest" ]] && continue
    if [[ $(awk 'NF && $1 !~ /^#/ {print $2; exit}' "$existing") == "$blob" ]]; then
      die "This key is already stored as ${existing#"$dir/"} (user '$(gitolite_user_for_keyfile "$existing")'). Each identity, and each agent, needs its own key."
    fi
  done < <(find "$dir/keydir" -type f -name '*.pub' -print0)
  if list_has "$(admin_identities "$dir" | tr '\n' ' ')" "$name"; then
    warn "'$name' can push to gitolite-admin and change every access rule. Keep this key off machines where AI agents run (see README: Identities and keys)."
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$key" "$dest"
  chmod 0644 "$dest"
  git -C "$dir" add "${dest#"$dir/"}"
  log "Staged key for Gitolite identity '$name': ${dest#"$dir/"}"
}

user_remove_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh user-remove --name USER [options]

Options:
  --name USER           Logical Gitolite identity (required)
  --key-id ID           Remove only keydir/ID/USER.pub
  --all                 Remove every key of USER, in any keydir subdirectory
  --force               Allow removing the last key that can push to
                        gitolite-admin (this locks out every admin)
  --admin-dir DIR       gitolite-admin working tree (default: current dir)
  -h, --help

Without --key-id or --all, removes keydir/USER.pub only.

When USER has no keys left but is still named in an access rule, a warning
lists those files: a key added later under the same name would get that
access again.
USAGE
}

user_remove() {
  local name="" key_id="" requested="" all=0 force=0
  while (($#)); do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "--name requires a value"; name=$2; shift 2 ;;
      --key-id) [[ $# -ge 2 ]] || die "--key-id requires a value"; key_id=$2; shift 2 ;;
      --all) all=1; shift ;;
      --force) force=1; shift ;;
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -h|--help) user_remove_usage; return 0 ;;
      *) die "Unknown user-remove option: $1" ;;
    esac
  done
  [[ -n $name ]] || die "--name is required"
  validate_simple_name "$name" "User name"
  [[ -z $key_id ]] || validate_simple_name "$key_id" "Key ID"
  [[ -z $key_id || $all -eq 0 ]] || die "Use either --key-id or --all, not both"
  local dir target
  local -a targets=()
  dir=$(find_admin_dir "$requested")
  if (( all )); then
    mapfile -t targets < <(identity_key_files "$dir" "$name")
    (( ${#targets[@]} > 0 )) || die "No keys found for user: $name"
  else
    if [[ -n $key_id ]]; then target="keydir/$key_id/$name.pub"; else target="keydir/$name.pub"; fi
    [[ -e "$dir/$target" ]] || die "Key not found: $target"
    targets=("$target")
  fi

  # Refuse to remove the last key that can push to gitolite-admin.
  local admins admin file remaining=0
  admins=$(admin_identities "$dir")
  if [[ -z $admins ]]; then
    warn "No user with write access to gitolite-admin was found in the gitolite-admin rules (for example only @all); skipping the lockout check."
  else
    while IFS= read -r admin; do
      while IFS= read -r file; do
        [[ -n $file ]] || continue
        for target in "${targets[@]}"; do
          [[ $file == "$target" ]] && continue 2
        done
        remaining=$((remaining + 1))
      done < <(identity_key_files "$dir" "$admin")
    done <<<"$admins"
    if (( remaining == 0 )); then
      if (( force )); then
        warn "Removing the last key that can push to gitolite-admin (--force)."
      else
        die "This would remove the last key that can push to gitolite-admin, and nobody could change access rules any more. Add another admin key first, or use --force."
      fi
    fi
  fi

  for target in "${targets[@]}"; do
    if git -C "$dir" ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
      # -f also handles a key that was staged by user-add but never applied.
      git -C "$dir" rm --quiet -f -- "$target"
    else
      rm -f -- "$dir/$target"
    fi
    # Remove an empty key-id directory, but never keydir itself.
    if [[ $(dirname "$target") != keydir ]]; then
      rmdir "$dir/$(dirname "$target")" 2>/dev/null || true
    fi
    log "Staged removal of key: $target"
  done

  local refs
  if [[ -z $(identity_key_files "$dir" "$name") ]]; then
    refs=$(acl_references "$dir" "$name" | paste -sd ' ' -)
    if [[ -n $refs ]]; then
      warn "'$name' has no keys left but is still named in: $refs"
      warn "A key added later under the name '$name' would get that access again. Remove '$name' from those rules (for example with repo-set)."
    fi
  fi
}

user_list_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh user-list [--admin-dir DIR]
USAGE
}

user_list() {
  local requested=""
  while (($#)); do
    case "$1" in
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -h|--help) user_list_usage; return 0 ;;
      *) die "Unknown user-list option: $1" ;;
    esac
  done
  local dir file rel user fp
  need_cmd ssh-keygen
  dir=$(find_admin_dir "$requested")
  printf '%-24s %-36s %s\n' "USER" "KEY PATH" "FINGERPRINT"
  while IFS= read -r -d '' file; do
    rel=${file#"$dir/keydir/"}
    user=$(gitolite_user_for_keyfile "$file")
    fp=$(ssh-keygen -lf "$file" 2>/dev/null | awk '{print $2}' || echo invalid)
    printf '%-24s %-36s %s\n' "$user" "$rel" "$fp"
  done < <(find "$dir/keydir" -type f -name '*.pub' -print0 | sort -z)
}

GROUP_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

validate_group_name() {
  local name=$1
  [[ $name =~ $GROUP_NAME_RE ]] || die "Invalid group name: $name"
  [[ $name != all ]] || die "'all' is Gitolite's built-in group @all. Choose another name."
}

# A space-separated ACL list may contain users and @groups.
validate_acl_list() {
  local item
  local -a items=()
  IFS=' ' read -r -a items <<<"${1:-}"
  for item in "${items[@]}"; do
    if [[ $item == @* ]]; then
      [[ $item == @all || ${item#@} =~ $GROUP_NAME_RE ]] || die "Invalid group name in ACL: $item"
    else
      validate_simple_name "$item" "ACL user"
    fi
  done
}

group_fragment_path() {
  printf '%s/conf/groups/%s.conf' "$1" "$2"
}

# Print the members of a group managed by group-set. Fails if the group is
# not managed by this script.
managed_group_members() {
  local file
  file=$(group_fragment_path "$1" "$2")
  [[ -f $file ]] || return 1
  sed -n 's/^# mini-git-server: members=//p' "$file"
}

# Print LIST with every managed @group replaced by its members. @all and
# groups not managed by group-set stay as they are. With OVERRIDE_NAME and
# OVERRIDE_MEMBERS, that group uses those members instead (group-set uses
# this to check a change before writing it).
expand_groups() {
  local dir=$1 list=$2 override_name=${3:-} override_members=${4:-}
  local item name members out=""
  local -a items=()
  IFS=' ' read -r -a items <<<"$list"
  for item in "${items[@]}"; do
    members=$item
    if [[ $item == @* && $item != @all ]]; then
      name=${item#@}
      if [[ -n $override_name && $name == "$override_name" ]]; then
        members=$override_members
      elif ! members=$(managed_group_members "$dir" "$name"); then
        members=$item
      fi
    fi
    out+="${out:+ }$members"
  done
  csv_to_spaces "$out"
}

# Check the roles of one repository ACL, with managed groups replaced by
# their members. Extra arguments are passed on to expand_groups.
check_repo_roles() {
  local dir=$1 owner=$2 writers=$3 agents=$4 readers=$5
  shift 5
  writers=$(expand_groups "$dir" "$writers" "$@")
  agents=$(expand_groups "$dir" "$agents" "$@")
  readers=$(expand_groups "$dir" "$readers" "$@")
  validate_agent_names "$agents"
  check_role_overlap owner "$owner" writer "$writers" agent "$agents" reader "$readers"
}

# Print one "# mini-git-server: KEY=" metadata value of a repo fragment.
fragment_meta() {
  sed -n "s/^# mini-git-server: $2=//p" "$1" | head -n 1
}

# Warn about identities that have no key, or that are admin identities.
warn_about_identities() {
  local dir=$1 list=$2 admins identity
  local -a identities=()
  admins=$(admin_identities "$dir" | tr '\n' ' ')
  IFS=' ' read -r -a identities <<<"$list"
  for identity in "${identities[@]}"; do
    [[ $identity == @* ]] && continue
    # Gitolite's special users have no key. Its triggers act on their read
    # access instead, so say what that does rather than warn.
    case $identity in
      daemon)
        log "'daemon' is Gitolite's user for anonymous reading and needs no key. Gitolite marks every repository that daemon can read with git-daemon-export-ok, and git daemon or git http-backend, if one runs on the server, serves it to anyone who can reach it."
        continue
        ;;
      gitweb)
        log "'gitweb' is Gitolite's user for gitweb and needs no key. Gitolite lists every repository that gitweb can read in projects.list, and gitweb, if it runs on the server, shows it."
        continue
        ;;
    esac
    if list_has "$admins" "$identity"; then
      warn "'$identity' is also a gitolite-admin identity. Use a separate identity for daily work and agents, so their keys cannot change access rules (see README: Identities and keys)."
    fi
    if [[ -z $(identity_key_files "$dir" "$identity") ]]; then
      warn "No key in keydir for '$identity'. Its rules have no effect until a key is added with user-add. Check the spelling."
    fi
  done
}

group_set_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh group-set --name NAME --members LIST [--admin-dir DIR]

Create or replace the Gitolite group @NAME in conf/groups/NAME.conf.

Options:
  --name NAME        Group name, with or without the leading '@'
  --members LIST     Comma/space-separated users (no nested groups)
  --admin-dir DIR    gitolite-admin working tree (default: current dir)
  -h, --help

Use the group in repo-set lists, for example '--agents @agents'. Changing the
members later changes every repository that uses the group, without running
repo-set again. Every managed repository that uses the group is checked with
the new members first, so no member ends up with two roles in one
repository. The change is staged; run 'apply' after reviewing it.
USAGE
}

group_set() {
  local name="" members="" requested=""
  while (($#)); do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "--name requires a value"; name=$2; shift 2 ;;
      --members) [[ $# -ge 2 ]] || die "--members requires a value"; members=$2; shift 2 ;;
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -h|--help) group_set_usage; return 0 ;;
      *) die "Unknown group-set option: $1" ;;
    esac
  done
  [[ -n $name ]] || die "--name is required"
  name=${name#@}
  validate_group_name "$name"
  members=$(csv_to_spaces "$members")
  [[ -n $members ]] || die "--members must list at least one user. Use group-remove to delete a group."
  validate_user_list "$members"

  local dir fragment repo err
  dir=$(find_admin_dir "$requested")
  grep -Fqx "$ADMIN_GROUPS_INCLUDE" "$dir/conf/gitolite.conf" || \
    die "Group fragments are not enabled. Run 'admin-init' first (it is safe to run again)."

  # Check every managed repository that uses this group, with the new members.
  while IFS= read -r -d '' fragment; do
    grep -Fq '# mini-git-server: owner=' "$fragment" || continue
    if ! list_has "$(fragment_meta "$fragment" writers) $(fragment_meta "$fragment" agents) $(fragment_meta "$fragment" readers)" "@$name"; then
      continue
    fi
    repo=$(sed -n 's/^# Repository: //p' "$fragment" | head -n 1)
    if ! err=$( (check_repo_roles "$dir" \
      "$(fragment_meta "$fragment" owner)" \
      "$(fragment_meta "$fragment" writers)" \
      "$(fragment_meta "$fragment" agents)" \
      "$(fragment_meta "$fragment" readers)" \
      "$name" "$members") 2>&1 ); then
      die "With these members, the ACL of repository '$repo' would be invalid: ${err#\[ERROR\] }"
    fi
  done < <(find "$dir/conf/repos" -type f -name '*.conf' -print0 2>/dev/null | sort -z)

  warn_about_identities "$dir" "$members"

  mkdir -p "$dir/conf/groups"
  fragment=$(group_fragment_path "$dir" "$name")
  {
    printf '# Managed by mini-git-server.sh\n'
    printf '# Group: @%s\n' "$name"
    printf '# mini-git-server: members=%s\n' "$members"
    printf '@%s = %s\n' "$name" "$members"
  } >"$fragment"
  git -C "$dir" add "${fragment#"$dir/"}"
  log "Staged group @$name: ${fragment#"$dir/"}"
}

group_remove_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh group-remove --name NAME [--admin-dir DIR]

Remove a group created by group-set. Refused while an access rule still uses
the group.
USAGE
}

group_remove() {
  local name="" requested=""
  while (($#)); do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "--name requires a value"; name=$2; shift 2 ;;
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -h|--help) group_remove_usage; return 0 ;;
      *) die "Unknown group-remove option: $1" ;;
    esac
  done
  [[ -n $name ]] || die "--name is required"
  name=${name#@}
  validate_group_name "$name"
  local dir fragment refs
  dir=$(find_admin_dir "$requested")
  fragment=$(group_fragment_path "$dir" "$name")
  [[ -f $fragment ]] || die "Group @$name is not managed by group-set (no ${fragment#"$dir/"})"
  refs=$(acl_references "$dir" "@$name" | paste -sd ' ' -)
  [[ -z $refs ]] || die "Group @$name is still used in: $refs. Remove it from those ACLs first."
  if git -C "$dir" ls-files --error-unmatch -- "${fragment#"$dir/"}" >/dev/null 2>&1; then
    git -C "$dir" rm --quiet -f -- "${fragment#"$dir/"}"
  else
    rm -f -- "$fragment"
  fi
  log "Staged removal of group @$name"
}

group_list_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh group-list [--admin-dir DIR]

List the groups managed by group-set and their members.
USAGE
}

group_list() {
  local requested=""
  while (($#)); do
    case "$1" in
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -h|--help) group_list_usage; return 0 ;;
      *) die "Unknown group-list option: $1" ;;
    esac
  done
  local dir file name
  dir=$(find_admin_dir "$requested")
  while IFS= read -r -d '' file; do
    name=$(basename "$file" .conf)
    printf '@%s: %s\n' "$name" "$(managed_group_members "$dir" "$name")"
  done < <(find "$dir/conf/groups" -type f -name '*.conf' -print0 2>/dev/null | sort -z)
}

repo_set_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh repo-set --repo NAME --owner USER [options]

Options:
  --repo NAME            Repository name, e.g. project or team/project
  --owner USER           Human with RW+ to the whole repository. The owner
                         is the only identity that can push tags.
  --writers LIST         Comma/space-separated users with RW (no force push),
                         except tags and agent/* branches
  --readers LIST         Comma/space-separated read-only users
  --agents LIST          Comma/space-separated agents. Each gets:
                           RW  agent/USER/*
                           R   everywhere else
  --agent-rewind         Let agents force-push and delete, but only their
                         own agent/USER/* branches (RW+ instead of RW)
  --protected-branch B   Exact branch protected from --writers/--agents.
                         Repeat this option for multiple protected branches.
  --admin-dir DIR        gitolite-admin working tree (default: current dir)
  -h, --help

This command declares the complete desired ACL state for a repository. Omitted
writers, readers, agents, and protected branches are removed from the managed
fragment. It writes conf/repos/<encoded-name>.conf and stages the change, but
never pushes; run 'apply' after reviewing the staged diff.

Each identity may have only one role (owner, writer, agent or reader). Agent
names may only use letters, digits, '-' and '_'. A warning is shown for any
identity that has no key in keydir yet.

Lists may contain groups created by group-set, for example '--agents @agents'.
Group members are checked like users listed directly.
USAGE
}

repo_set() {
  local repo="" owner="" writers="" readers="" agents="" requested="" agent_rewind=0
  local -a protected_branches=()
  while (($#)); do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die "--repo requires a value"; repo=$2; shift 2 ;;
      --owner) [[ $# -ge 2 ]] || die "--owner requires a value"; owner=$2; shift 2 ;;
      --writers) [[ $# -ge 2 ]] || die "--writers requires a value"; writers=$2; shift 2 ;;
      --readers) [[ $# -ge 2 ]] || die "--readers requires a value"; readers=$2; shift 2 ;;
      --agents) [[ $# -ge 2 ]] || die "--agents requires a value"; agents=$2; shift 2 ;;
      --agent-rewind) agent_rewind=1; shift ;;
      --protected-branch) [[ $# -ge 2 ]] || die "--protected-branch requires a value"; protected_branches+=("$2"); shift 2 ;;
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -h|--help) repo_set_usage; return 0 ;;
      *) die "Unknown repo-set option: $1" ;;
    esac
  done
  [[ -n $repo && -n $owner ]] || die "--repo and --owner are required"
  validate_repo_name "$repo"
  validate_simple_name "$owner" "Owner"
  writers=$(csv_to_spaces "$writers")
  readers=$(csv_to_spaces "$readers")
  agents=$(csv_to_spaces "$agents")
  validate_acl_list "$writers"
  validate_acl_list "$readers"
  validate_acl_list "$agents"
  [[ $agent_rewind -eq 0 || -n $agents ]] || die "--agent-rewind needs --agents"
  local branch
  for branch in "${protected_branches[@]}"; do
    validate_branch_name "$branch"
  done

  local dir encoded fragment
  dir=$(find_admin_dir "$requested")
  mkdir -p "$dir/conf/repos"
  if ! grep -Fqx 'include "repos/*.conf"' "$dir/conf/gitolite.conf"; then
    die "Script-managed repo fragments are not enabled. Run 'admin-init' first."
  fi
  encoded=$(repo_fragment_name "$repo")
  fragment="$dir/conf/repos/$encoded.conf"

  check_repo_roles "$dir" "$owner" "$writers" "$agents" "$readers"
  warn_about_identities "$dir" "$(expand_groups "$dir" "$owner $writers $agents $readers")"
  local item
  local -a items=()
  IFS=' ' read -r -a items <<<"$writers $agents $readers"
  for item in "${items[@]}"; do
    if [[ $item == @* && $item != @all ]] && ! managed_group_members "$dir" "${item#@}" >/dev/null; then
      warn "Group '$item' is not managed by group-set. Make sure conf/gitolite.conf defines it before the repos include, or rules that use it match nobody."
    fi
  done

  {
    printf '# Managed by mini-git-server.sh\n'
    printf '# Repository: %s\n' "$repo"
    printf '# mini-git-server: owner=%s\n' "$owner"
    printf '# mini-git-server: writers=%s\n' "$writers"
    printf '# mini-git-server: agents=%s\n' "$agents"
    printf '# mini-git-server: readers=%s\n' "$readers"
    (( agent_rewind )) && printf '# mini-git-server: agent-rewind=yes\n'
    for branch in "${protected_branches[@]}"; do
      printf '# mini-git-server: protected-branch=%s\n' "$branch"
    done
    printf 'repo %s\n' "$repo"
    printf '    RW+                         =   %s\n' "$owner"
    # Gitolite uses the first rule that matches, so every deny rule must
    # come before the RW rule of the writers.
    if [[ -n ${writers}${agents} ]]; then
      local non_owners refex
      non_owners=$(csv_to_spaces "$writers $agents")
      for branch in "${protected_branches[@]}"; do
        refex=$(branch_refex_exact "$branch")
        printf '    -       %-20s =   %s\n' "$refex" "$non_owners"
      done
      # Only the owner may create, move or delete tags.
      printf '    -       %-20s =   %s\n' 'refs/tags/' "$non_owners"
    fi
    if [[ -n $writers ]]; then
      # agent/ is reserved for agents; writers may not write there.
      printf '    -       %-20s =   %s\n' 'agent/' "$writers"
      printf '    RW                          =   %s\n' "$writers"
    fi
    if [[ -n $agents ]]; then
      if (( agent_rewind )); then
        printf '    RW+     agent/USER/         =   %s\n' "$agents"
      else
        printf '    RW      agent/USER/         =   %s\n' "$agents"
      fi
      local reader_sep=""
      [[ -n $agents && -n $readers ]] && reader_sep=" "
      printf '    R                           =   %s%s%s\n' "$agents" "$reader_sep" "$readers"
    elif [[ -n $readers ]]; then
      printf '    R                           =   %s\n' "$readers"
    fi
  } >"$fragment"

  git -C "$dir" add "${fragment#"$dir/"}"
  log "Staged repository ACL: ${fragment#"$dir/"}"
}

repo_add_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh repo-add --repo NAME --owner USER [options]

'repo-add' is a backward-compatible alias for 'repo-set'.
Run 'mini-git-server.sh repo-set --help' for the complete option list.
USAGE
}

repo_add() {
  if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    repo_add_usage
    return 0
  fi
  repo_set "$@"
}

spaces_to_csv() {
  local value=${1:-}
  printf '%s\n' "$value" | awk '{$1=$1; gsub(/ /, ","); print}'
}

shell_quote() {
  local value=$1
  if [[ $value =~ ^[A-Za-z0-9_./,@%+=:-]+$ ]]; then
    printf '%s' "$value"
  else
    printf '%q' "$value"
  fi
}

regex_unescape_literal() {
  local value=$1 out="" ch i escaped=0
  for ((i=0; i<${#value}; i++)); do
    ch=${value:i:1}
    if (( escaped )); then
      out+="$ch"
      escaped=0
    elif [[ $ch == $'\\' ]]; then
      escaped=1
    else
      out+="$ch"
    fi
  done
  (( escaped == 0 )) || out+=$'\\'
  printf '%s' "$out"
}

repo_show_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh repo-show --repo NAME [options]

Options:
  --repo NAME       Repository name (required)
  --admin-dir DIR   gitolite-admin working tree (default: current dir)
  --raw             Print the managed Gitolite fragment exactly as stored
  -h, --help

By default, repo-show prints the current declarative ACL state and a reusable
repo-set command that can be edited and run again. --raw preserves the old
behavior of printing only the Gitolite fragment.
USAGE
}

repo_show() {
  local repo="" requested="" raw=0
  while (($#)); do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die "--repo requires a value"; repo=$2; shift 2 ;;
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      --raw) raw=1; shift ;;
      -h|--help) repo_show_usage; return 0 ;;
      *) die "Unknown repo-show option: $1" ;;
    esac
  done
  [[ -n $repo ]] || die "--repo is required"
  validate_repo_name "$repo"
  local dir fragment
  dir=$(find_admin_dir "$requested")
  fragment="$dir/conf/repos/$(repo_fragment_name "$repo").conf"
  [[ -f $fragment ]] || die "Script-managed ACL not found for repository: $repo"

  if (( raw )); then
    cat "$fragment"
    return 0
  fi

  local owner="" writers="" agents="" readers="" line value refex branch agent_rewind=no
  local -a protected_branches=()

  # Prefer explicit metadata written by repo-set. Fall back to parsing the
  # legacy v0.2.x generated ACL format so existing fragments remain readable.
  if grep -Fq '# mini-git-server: owner=' "$fragment"; then
    while IFS= read -r line; do
      case "$line" in
        '# mini-git-server: owner='*) owner=${line#*=} ;;
        '# mini-git-server: writers='*) writers=${line#*=} ;;
        '# mini-git-server: agents='*) agents=${line#*=} ;;
        '# mini-git-server: readers='*) readers=${line#*=} ;;
        '# mini-git-server: agent-rewind='*) agent_rewind=${line#*=} ;;
        '# mini-git-server: protected-branch='*) protected_branches+=("${line#*=}") ;;
      esac
    done <"$fragment"
  else
    while IFS= read -r line; do
      if [[ $line =~ ^[[:space:]]*RW\+[[:space:]]*=[[:space:]]*(.+)$ ]]; then
        owner=${BASH_REMATCH[1]}
      elif [[ $line =~ ^[[:space:]]*RW[[:space:]]+agent/USER/[[:space:]]*=[[:space:]]*(.+)$ ]]; then
        agents=${BASH_REMATCH[1]}
      elif [[ $line =~ ^[[:space:]]*RW[[:space:]]*=[[:space:]]*(.+)$ ]]; then
        writers=${BASH_REMATCH[1]}
      elif [[ $line =~ ^[[:space:]]*R[[:space:]]*=[[:space:]]*(.+)$ ]]; then
        value=${BASH_REMATCH[1]}
        readers=$value
      elif [[ $line =~ ^[[:space:]]*-[[:space:]]+(refs/heads/.+\$)[[:space:]]*=[[:space:]]*.+$ ]]; then
        refex=${BASH_REMATCH[1]}
        refex=${refex#refs/heads/}
        refex=${refex%$}
        branch=$(regex_unescape_literal "$refex")
        protected_branches+=("$branch")
      fi
    done <"$fragment"

    # In generated legacy fragments the read rule contains agents first,
    # followed by readers. Remove the agent identities to recover readers.
    if [[ -n $agents && -n $readers ]]; then
      local item filtered="" agent_item is_agent
      local -a reader_items=() agent_items=()
      IFS=' ' read -r -a reader_items <<<"$readers"
      IFS=' ' read -r -a agent_items <<<"$agents"
      for item in "${reader_items[@]}"; do
        is_agent=0
        for agent_item in "${agent_items[@]}"; do
          [[ $item == "$agent_item" ]] && is_agent=1 && break
        done
        (( is_agent )) || filtered+="${filtered:+ }$item"
      done
      readers=$filtered
    fi
  fi

  [[ -n $owner ]] || die "Unable to parse managed ACL owner for repository: $repo"

  printf 'Repository: %s\n' "$repo"
  printf 'Owner: %s\n' "$owner"
  printf 'Writers: %s\n' "${writers:-(none)}"
  printf 'Agents: %s\n' "${agents:-(none)}"
  printf 'Readers: %s\n' "${readers:-(none)}"
  printf 'Agent rewind: %s\n' "$agent_rewind"
  printf 'Protected branches:'
  if (( ${#protected_branches[@]} == 0 )); then
    printf ' (none)\n'
  else
    printf '\n'
    for branch in "${protected_branches[@]}"; do
      printf '  - %s\n' "$branch"
    done
  fi

  local -a reapply_cmd=("$0" repo-set --repo "$repo" --owner "$owner")
  [[ -n $writers ]] && reapply_cmd+=(--writers "$(spaces_to_csv "$writers")")
  [[ -n $agents ]] && reapply_cmd+=(--agents "$(spaces_to_csv "$agents")")
  [[ -n $readers ]] && reapply_cmd+=(--readers "$(spaces_to_csv "$readers")")
  for branch in "${protected_branches[@]}"; do
    reapply_cmd+=(--protected-branch "$branch")
  done
  [[ -n $requested ]] && reapply_cmd+=(--admin-dir "$dir")

  printf '\nReapply command:\n'
  shell_quote "${reapply_cmd[0]}"
  printf ' '
  shell_quote "${reapply_cmd[1]}"
  local i
  for ((i=2; i<${#reapply_cmd[@]}; i+=2)); do
    printf ' \\\n  '
    shell_quote "${reapply_cmd[i]}"
    printf ' '
    shell_quote "${reapply_cmd[i+1]}"
  done
  [[ $agent_rewind == yes ]] && printf ' \\\n  --agent-rewind'
  printf '\n'
}

repo_list_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh repo-list [--admin-dir DIR]
USAGE
}

repo_list() {
  local requested=""
  while (($#)); do
    case "$1" in
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -h|--help) repo_list_usage; return 0 ;;
      *) die "Unknown repo-list option: $1" ;;
    esac
  done
  local dir
  dir=$(find_admin_dir "$requested")
  grep -RhsE '^[[:space:]]*repo[[:space:]]+' "$dir/conf" \
    | sed -E 's/^[[:space:]]*repo[[:space:]]+//' \
    | awk '{for (i=1;i<=NF;i++) print $i}' \
    | sort -u
}

# Stop unless the gitolite-admin working tree is on the branch that Gitolite
# applies.
require_admin_branch() {
  local dir=$1 branch
  branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD) || \
    die "gitolite-admin has a detached HEAD. Run 'git switch $GITOLITE_ADMIN_BRANCH' first."
  [[ $branch == "$GITOLITE_ADMIN_BRANCH" ]] || \
    die "gitolite-admin is on branch '$branch', but Gitolite only applies changes pushed to '$GITOLITE_ADMIN_BRANCH'. Switch to '$GITOLITE_ADMIN_BRANCH', or see 'Repair an admin repository on the wrong branch' in README.md."
}

# Fetch the admin branch from origin, then print how HEAD relates to it:
# up-to-date, ahead, behind or diverged.
admin_remote_state() {
  local dir=$1 remote_ref="refs/remotes/origin/$GITOLITE_ADMIN_BRANCH" head remote
  git -C "$dir" fetch --quiet origin "+refs/heads/$GITOLITE_ADMIN_BRANCH:$remote_ref" || \
    die "Could not fetch '$GITOLITE_ADMIN_BRANCH' from origin."
  head=$(git -C "$dir" rev-parse HEAD)
  remote=$(git -C "$dir" rev-parse "$remote_ref")
  if [[ $head == "$remote" ]]; then
    printf 'up-to-date\n'
  elif git -C "$dir" merge-base --is-ancestor "$remote" "$head"; then
    printf 'ahead\n'
  elif git -C "$dir" merge-base --is-ancestor "$head" "$remote"; then
    printf 'behind\n'
  else
    printf 'diverged\n'
  fi
}

admin_tree_clean() {
  git -C "$1" diff --quiet && git -C "$1" diff --cached --quiet
}

admin_sync_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh sync [--admin-dir DIR]

Bring the gitolite-admin working tree up to date with origin, for example
after another machine applied changes:

  - behind origin: fast-forward, keeping staged changes that were not
    applied yet;
  - local commits that were not pushed (for example after a failed push):
    rebase them onto origin.

sync never pushes. Run 'apply' (or 'git push origin master') afterwards.
USAGE
}

admin_sync() {
  local requested=""
  while (($#)); do
    case "$1" in
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -h|--help) admin_sync_usage; return 0 ;;
      *) die "Unknown sync option: $1" ;;
    esac
  done
  local dir state remote_ref="refs/remotes/origin/$GITOLITE_ADMIN_BRANCH" ahead
  dir=$(find_admin_dir "$requested")
  require_admin_branch "$dir"
  state=$(admin_remote_state "$dir")
  case $state in
    up-to-date)
      log "gitolite-admin is up to date with origin."
      ;;
    ahead)
      ahead=$(git -C "$dir" rev-list --count "$remote_ref..HEAD")
      log "gitolite-admin is up to date, with $ahead local commit(s) not pushed yet. Push them with: git -C '$dir' push origin $GITOLITE_ADMIN_BRANCH"
      ;;
    behind)
      if admin_tree_clean "$dir"; then
        git -C "$dir" merge --ff-only --quiet "$remote_ref"
      else
        git -C "$dir" stash push --quiet -m "mini-git-server sync"
        if ! git -C "$dir" merge --ff-only --quiet "$remote_ref"; then
          git -C "$dir" stash pop --index --quiet || true
          die "Could not fast-forward to origin (see the Git message above). Nothing was changed."
        fi
        if ! git -C "$dir" stash pop --index --quiet; then
          die "Updated to origin, but your staged changes conflict with the new changes. They are saved as the latest entry in 'git -C $dir stash list'. Run 'git -C $dir reset --hard', redo the changes with the mini-git-server commands, then 'git -C $dir stash drop'."
        fi
      fi
      log "Updated gitolite-admin to origin/$GITOLITE_ADMIN_BRANCH. Staged changes were kept."
      ;;
    diverged)
      admin_tree_clean "$dir" || \
        die "Both origin and your local commits changed, and there are also uncommitted changes. Commit them with 'apply --no-push' or remove them, then run sync again."
      if ! git -C "$dir" rebase --quiet "$remote_ref"; then
        die "Rebase stopped on a conflict. Resolve it and run 'git -C $dir rebase --continue', or undo it with 'git -C $dir rebase --abort'."
      fi
      log "Rebased local commits onto origin/$GITOLITE_ADMIN_BRANCH. Push them with: git -C '$dir' push origin $GITOLITE_ADMIN_BRANCH"
      ;;
  esac
}

apply_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh apply [options]

Options:
  --admin-dir DIR       gitolite-admin working tree (default: current dir)
  -m, --message TEXT    Commit message (default: 'Update Gitolite configuration')
  --no-push             Commit locally but do not push
  -h, --help

The command shows the staged diff, runs 'git diff --check', commits it, and
pushes it to the 'master' branch of origin unless --no-push is used. It must
run on the local 'master' branch, because Gitolite only applies that branch.

Before committing, apply fetches origin. If another machine has pushed newer
changes, it stops without committing; run 'sync' and then apply again.
USAGE
}

admin_apply() {
  local requested="" message="Update Gitolite configuration" push=1
  while (($#)); do
    case "$1" in
      --admin-dir) [[ $# -ge 2 ]] || die "--admin-dir requires a value"; requested=$2; shift 2 ;;
      -m|--message) [[ $# -ge 2 ]] || die "$1 requires a value"; message=$2; shift 2 ;;
      --no-push) push=0; shift ;;
      -h|--help) apply_usage; return 0 ;;
      *) die "Unknown apply option: $1" ;;
    esac
  done
  local dir state
  dir=$(find_admin_dir "$requested")
  # Check the branch before committing, so nothing is committed to a branch
  # that Gitolite would silently ignore.
  require_admin_branch "$dir"
  git -C "$dir" diff --check --cached
  if git -C "$dir" diff --cached --quiet; then
    die "No staged changes to apply."
  fi
  # Do not commit on top of an old state: the push would be rejected and
  # leave a local commit behind.
  if (( push )); then
    state=$(admin_remote_state "$dir")
    case $state in
      behind|diverged)
        die "origin has newer gitolite-admin changes (for example from another machine). Nothing was committed. Run '$PROGRAM sync', check 'git diff --cached' again, then run apply again."
        ;;
    esac
  fi

  printf '%s\n' '--- staged changes ---'
  git -C "$dir" diff --cached --stat
  git -C "$dir" diff --cached
  printf '%s\n' '--- end staged changes ---'

  git -C "$dir" commit -m "$message"
  if (( push )); then
    if ! git -C "$dir" push origin "HEAD:refs/heads/$GITOLITE_ADMIN_BRANCH"; then
      die "Push failed, but the change is committed locally. Run '$PROGRAM sync', then push with: git -C '$dir' push origin $GITOLITE_ADMIN_BRANCH"
    fi
    log "Changes pushed to Gitolite."
  else
    log "Committed locally; push skipped by --no-push."
  fi
}

agent_branches_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh agent-branches [options]

Run inside a clone of a project repository. Fetches the remote, then lists
every agent branch (agent/<name>/*) with how many commits it is ahead of and
behind the base branch, when it was last updated, and its newest commit.

Options:
  --remote NAME   Remote to read (default: origin)
  --base BRANCH   Branch to compare with (default: the remote's default
                  branch, that is its HEAD)
  --merged        List only branches that have no commits missing from the
                  base branch, and print the commands that delete them
  --no-fetch      Use the remote-tracking branches as they are
  -h, --help

Branches merged with squash or rebase still show commits ahead, because
their own commits are not in the base branch.
USAGE
}

agent_branches() {
  local remote=origin base="" merged=0 fetch=1
  while (($#)); do
    case "$1" in
      --remote) [[ $# -ge 2 ]] || die "--remote requires a value"; remote=$2; shift 2 ;;
      --base) [[ $# -ge 2 ]] || die "--base requires a value"; base=$2; shift 2 ;;
      --merged) merged=1; shift ;;
      --no-fetch) fetch=0; shift ;;
      -h|--help) agent_branches_usage; return 0 ;;
      *) die "Unknown agent-branches option: $1" ;;
    esac
  done
  [[ $remote =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid remote name: $remote"
  [[ -z $base ]] || validate_branch_name "$base"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "Run agent-branches inside a clone of a project repository."
  git remote get-url "$remote" >/dev/null 2>&1 || die "No remote named '$remote' in this repository."

  if (( fetch )); then
    git fetch --quiet --prune "$remote" || die "Could not fetch from '$remote'."
  fi

  # Do not assume a branch name: use the remote's HEAD unless --base is given.
  if [[ -z $base ]]; then
    base=$(git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null) || true
    if [[ -z $base ]] && (( fetch )); then
      git remote set-head "$remote" --auto >/dev/null 2>&1 || true
      base=$(git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null) || true
    fi
    [[ -n $base ]] || die "Cannot tell the default branch of '$remote'. Pass --base BRANCH."
    base=${base#"$remote/"}
  fi
  local base_ref="refs/remotes/$remote/$base"
  git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || \
    die "Branch '$base' was not found on '$remote' ($base_ref)."

  local ref updated subject counts behind ahead short agent
  local -a rows=()
  local agent_width=5 branch_width=6
  while IFS=$'\t' read -r ref updated subject; do
    [[ -n $ref ]] || continue
    counts=$(git rev-list --left-right --count "$base_ref...$ref")
    behind=${counts%%[[:space:]]*}
    ahead=${counts##*[[:space:]]}
    (( merged && ahead > 0 )) && continue
    short=${ref#"refs/remotes/$remote/"}
    agent=${short#agent/}
    agent=${agent%%/*}
    (( ${#agent} > agent_width )) && agent_width=${#agent}
    (( ${#short} > branch_width )) && branch_width=${#short}
    rows+=("$agent"$'\t'"$short"$'\t'"$ahead"$'\t'"$behind"$'\t'"$updated"$'\t'"$subject")
  done < <(git for-each-ref --sort=-committerdate \
    --format='%(refname)%09%(committerdate:relative)%09%(subject)' "refs/remotes/$remote/agent/")

  if (( ${#rows[@]} == 0 )); then
    if (( merged )); then
      log "No merged agent branches on '$remote' (base: $base)."
    else
      log "No agent branches on '$remote'."
    fi
    return 0
  fi

  local row
  printf "%-${agent_width}s  %-${branch_width}s  %5s  %6s  %-16s  %s\n" AGENT BRANCH AHEAD BEHIND UPDATED SUBJECT
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r agent short ahead behind updated subject <<<"$row"
    printf "%-${agent_width}s  %-${branch_width}s  %5s  %6s  %-16s  %s\n" \
      "$agent" "$short" "$ahead" "$behind" "$updated" "$subject"
  done
  printf '\nAhead and behind are counted against %s/%s.\n' "$remote" "$base"

  if (( merged )); then
    printf '\nAll their commits are in %s. The owner can delete them with:\n' "$base"
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r agent short _ <<<"$row"
      printf '  git push %s --delete %s\n' "$remote" "$short"
    done
  fi
}

share_usage() {
  cat <<'USAGE'
Usage:
  mini-git-server.sh share --from LOCATION --ref REF --bind ADDRESS [options]

Builds a tar.gz or zip archive of one branch or tag and serves it at a
random URL. It stops when the time limit or the download limit is reached,
or on Ctrl-C, and then removes everything it created. Use it for a one-off
deploy to a machine that has no key for the Git server: the target only
needs curl, sha256sum and tar (or unzip).

Required:
  --from LOCATION     Repository to read, as given to git clone, for example
                      internal-git:project-x. It is read with your own
                      identity, so you can only share what you can read.
  --ref REF           Branch or tag to share
  --bind ADDRESS      Address to listen on, for example 10.0.0.5. Use
                      0.0.0.0 or :: only if every network this machine is
                      on may reach it.

Options:
  --depth N           Include .git with the last N commits, so the target
                      gets a shallow clone. By default the archive holds
                      only the files.
  --format FORMAT     tar.gz (default) or zip
  --tls               Serve HTTPS with a throwaway self-signed certificate.
                      The printed curl command pins its key, so no CA is
                      needed. Use this on networks you do not trust.
  --port PORT         Port to listen on (default: a random free port)
  --url-host NAME     Host name or address to print in the URL (default:
                      the --bind address, or this machine's first address)
  --ttl TIME          Stop after TIME, for example 90s, 30m or 2h; at most
                      24h (default: 30m). Downloads in progress may finish.
  --max-downloads N   Stop after N complete downloads; 0 means no limit
                      within --ttl (default: 1)
  -h, --help

Without --tls, anyone on the network path can read the archive and change
it in transit. The printed command checks the SHA-256 checksum, so send it
to the target over a channel you trust, for example your SSH session.

The URL is a secret: anyone who has it can download the archive until the
share stops. Needs python3, and openssl for --tls. Submodules are not
included, and Git LFS files contain only their pointers.
USAGE
}

# share keeps its state here, so that share_cleanup can run from a trap.
SHARE_WORK=""
SHARE_SERVER_PID=""

share_cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [[ -n $SHARE_SERVER_PID ]]; then
    kill "$SHARE_SERVER_PID" 2>/dev/null || true
    wait "$SHARE_SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n $SHARE_WORK ]]; then
    rm -rf -- "$SHARE_WORK"
    log "Stopped. Removed $SHARE_WORK"
  fi
  exit "$rc"
}

# Print TIME (90, 90s, 30m or 2h) in seconds.
share_ttl_seconds() {
  local value=$1 seconds
  [[ $value =~ ^([0-9]{1,6})([smh]?)$ ]] || die "Invalid --ttl: $value (use for example 90s, 30m or 2h)"
  seconds=$((10#${BASH_REMATCH[1]}))
  case ${BASH_REMATCH[2]} in
    m) seconds=$((seconds * 60)) ;;
    h) seconds=$((seconds * 3600)) ;;
  esac
  (( seconds >= 1 && seconds <= 86400 )) || die "--ttl must be between 1s and 24h: $value"
  printf '%s\n' "$seconds"
}

# Print an epoch time as local date and time, with GNU or BSD date.
share_clock() {
  date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M:%S'
}

# The HTTP server behind share, run with python3. Arguments: BIND PORT
# ARCHIVE TTL MAX_DOWNLOADS CERT KEY PORT_FILE (CERT and KEY empty without
# TLS). The secret URL path comes in MGS_SHARE_PATH, because other users can
# read the arguments of a process but not its environment. It writes the
# port it listens on to PORT_FILE.
share_server_program() {
  cat <<'PY'
import http.server, os, socket, ssl, sys, threading, time

bind, port, archive, ttl, max_downloads, cert, key, port_file = sys.argv[1:]
path = os.environ.pop("MGS_SHARE_PATH")
ttl, max_downloads = float(ttl), int(max_downloads)
name = os.path.basename(archive)


def note(message):
    sys.stderr.write("[INFO] %s\n" % message)
    sys.stderr.flush()


# Keep the archive open and remove it from the disk at once. The data stays
# readable through this descriptor, and the kernel frees it when this
# process ends in any way, even with kill -9.
fd = os.open(archive, os.O_RDONLY)
size = os.fstat(fd).st_size
os.unlink(archive)

lock = threading.Lock()
count = {"started": 0, "done": 0}
stopping = threading.Event()


def stop(reason):
    if not stopping.is_set():
        stopping.set()
        note("Stopping: %s." % reason)
        threading.Thread(target=server.shutdown, daemon=True).start()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "mini-git-server-share"
    sys_version = ""
    timeout = 60

    def setup(self):
        self.request.settimeout(self.timeout)
        if cert:
            self.request.do_handshake()
        super().setup()

    def log_message(self, format, *args):
        pass  # requests are logged below, without the token

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        client = self.client_address[0]
        if self.path != path:
            note("%s asked for an unknown path (404)" % client)
            self.send_error(404)
            return
        if body:
            with lock:
                full = max_downloads and count["started"] >= max_downloads
                if not full:
                    count["started"] += 1
            if full:
                note("%s was refused: the download limit is reached (410)" % client)
                self.send_error(410)
                return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not body:
            return
        note("%s started a download" % client)
        offset = 0
        try:
            while offset < size:
                chunk = os.pread(fd, 1 << 20, offset)
                if not chunk:
                    break
                self.wfile.write(chunk)
                offset += len(chunk)
            self.wfile.flush()
        except OSError:
            with lock:
                count["started"] -= 1  # give the slot back
            note("%s stopped before the end of the download" % client)
            return
        with lock:
            count["done"] += 1
            done = count["done"]
        if max_downloads:
            note("%s downloaded %s (%d of %d)" % (client, name, done, max_downloads))
            if done >= max_downloads:
                stop("the download limit is reached")
        else:
            note("%s downloaded %s (%d)" % (client, name, done))


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6 if ":" in bind else socket.AF_INET
    # Let downloads in progress finish when the share stops.
    daemon_threads = False

    def handle_error(self, request, client_address):
        note("%s: connection failed: %s" % (client_address[0], sys.exc_info()[1]))


try:
    server = Server((bind, int(port)), Handler)
except OSError as error:
    sys.stderr.write("[ERROR] Cannot listen on %s port %s: %s\n" % (bind, port, error.strerror))
    sys.exit(1)
if cert:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    os.unlink(cert)
    os.unlink(key)
    # Handshake in each connection's own thread, so that one client that
    # never completes it cannot hold up the others.
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)

if ttl > 0:
    timer = threading.Timer(ttl, stop, args=("the time limit is reached",))
    timer.daemon = True
    timer.start()

# Stop when the share command is gone, for example after kill -9.
parent = os.getppid()


def watch_parent():
    while not stopping.is_set():
        if os.getppid() != parent:
            stop("the share command is gone")
            return
        time.sleep(1)


threading.Thread(target=watch_parent, daemon=True).start()

with open(port_file + ".tmp", "w") as f:
    f.write("%d\n" % server.server_address[1])
os.rename(port_file + ".tmp", port_file)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
server.server_close()
PY
}

share() {
  local from="" ref="" bind="" depth="" format="tar.gz" tls=0 port=0 url_host=""
  local ttl="30m" max_downloads=1
  while (($#)); do
    case "$1" in
      --from) [[ $# -ge 2 ]] || die "--from requires a value"; from=$2; shift 2 ;;
      --ref) [[ $# -ge 2 ]] || die "--ref requires a value"; ref=$2; shift 2 ;;
      --bind) [[ $# -ge 2 ]] || die "--bind requires a value"; bind=$2; shift 2 ;;
      --depth) [[ $# -ge 2 ]] || die "--depth requires a value"; depth=$2; shift 2 ;;
      --format) [[ $# -ge 2 ]] || die "--format requires a value"; format=$2; shift 2 ;;
      --tls) tls=1; shift ;;
      --port) [[ $# -ge 2 ]] || die "--port requires a value"; port=$2; shift 2 ;;
      --url-host) [[ $# -ge 2 ]] || die "--url-host requires a value"; url_host=$2; shift 2 ;;
      --ttl) [[ $# -ge 2 ]] || die "--ttl requires a value"; ttl=$2; shift 2 ;;
      --max-downloads) [[ $# -ge 2 ]] || die "--max-downloads requires a value"; max_downloads=$2; shift 2 ;;
      -h|--help) share_usage; return 0 ;;
      *) die "Unknown share option: $1" ;;
    esac
  done
  [[ -n $from && -n $ref && -n $bind ]] || die "--from, --ref and --bind are required"
  need_cmd git
  [[ $from != -* ]] || die "Invalid --from: $from"
  git check-ref-format --branch "$ref" >/dev/null 2>&1 || die "Invalid --ref (expected a branch or tag name): $ref"
  [[ $bind =~ ^[A-Za-z0-9._:-]+$ && $bind != -* ]] || die "Invalid --bind address: $bind"
  [[ -z $url_host || ( $url_host =~ ^[A-Za-z0-9._:-]+$ && $url_host != -* ) ]] || die "Invalid --url-host: $url_host"
  [[ -z $depth || $depth =~ ^[1-9][0-9]{0,8}$ ]] || die "--depth must be a positive number: $depth"
  [[ $format == tar.gz || $format == zip ]] || die "--format must be tar.gz or zip: $format"
  if [[ ! $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port > 65535 )); then
    die "Invalid --port: $port"
  fi
  [[ $max_downloads =~ ^[0-9]{1,6}$ ]] || die "--max-downloads must be a number: $max_downloads"
  max_downloads=$((10#$max_downloads))
  local ttl_seconds
  ttl_seconds=$(share_ttl_seconds "$ttl")

  need_cmd python3
  need_cmd sha256sum
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 7))' || die "share needs Python 3.7 or newer."
  (( tls )) && need_cmd openssl
  [[ -n $depth && $format == zip ]] && need_cmd zip

  # Name the archive after the repository and the ref, using only
  # characters that need no quoting on the target.
  local name base
  name=${from%/}
  name=${name##*[:/]}
  name=${name%.git}
  base=$(printf '%s-%s' "$name" "$ref" | tr -c 'A-Za-z0-9._-' '-')
  [[ $base =~ ^[A-Za-z0-9] ]] || base="repo-$base"

  SHARE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/mgs-share.XXXXXXXX")
  trap share_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  local file="$SHARE_WORK/$base.$format"
  if [[ -z $depth ]]; then
    log "Exporting '$ref' from $from"
    git archive --remote="$from" --format="$format" --prefix="$base/" "$ref" >"$file" || \
      die "Could not export '$ref' from $from."
  else
    local src="$SHARE_WORK/src/$base"
    log "Cloning '$ref' from $from with depth $depth"
    # --no-local: Git ignores --depth when it copies a local repository.
    git clone --quiet --no-local --depth "$depth" --single-branch --branch "$ref" -- "$from" "$src" || \
      die "Could not clone '$ref' from $from."
    # The target cannot reach the Git server with this URL anyway, so do
    # not hand it over: drop the remote and the reflog that names it.
    git -C "$src" remote remove origin
    rm -rf -- "$src/.git/logs"
    if [[ $format == tar.gz ]]; then
      tar -C "$SHARE_WORK/src" -czf "$file" "$base"
    else
      (cd "$SHARE_WORK/src" && zip -qry "$file" "$base")
    fi
    rm -rf -- "$SHARE_WORK/src"
  fi
  local sha size
  sha=$(sha256sum "$file" | cut -d' ' -f1)
  size=$(du -h "$file" | cut -f1)

  local cert="" key="" pin=""
  if (( tls )); then
    cert="$SHARE_WORK/cert.pem" key="$SHARE_WORK/key.pem"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "$key" -out "$cert" -days 1 -subj '/CN=mini-git-server share' >/dev/null 2>&1 || \
      die "Could not create a TLS certificate with openssl."
    pin=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform der \
      | openssl dgst -sha256 -binary | openssl enc -base64)
  fi

  # 128 random bits: the URL itself is the only secret.
  local token url_path
  token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [[ $token =~ ^[0-9a-f]{32}$ ]] || die "Could not read random bytes for the URL."
  url_path="/$token/$base.$format"

  MGS_SHARE_PATH=$url_path python3 -c "$(share_server_program)" "$bind" "$port" "$file" \
    "$ttl_seconds" "$max_downloads" "$cert" "$key" "$SHARE_WORK/port" &
  SHARE_SERVER_PID=$!
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -s $SHARE_WORK/port ]] && break
    kill -0 "$SHARE_SERVER_PID" 2>/dev/null || break
    sleep 0.1
  done
  [[ -s $SHARE_WORK/port ]] || die "The HTTP server did not start."
  port=$(<"$SHARE_WORK/port")
  rm -f "$SHARE_WORK/port"

  if [[ -z $url_host ]]; then
    case $bind in
      0.0.0.0|::|0:0:0:0:0:0:0:0)
        url_host=$(hostname -I 2>/dev/null | awk '{print $1}') || true
        [[ -n $url_host ]] || url_host=$(hostname)
        ;;
      *) url_host=$bind ;;
    esac
  fi
  [[ $url_host != *:* ]] || url_host="[$url_host]"

  local scheme=http curl_opts="-fsS" extract limits
  if (( tls )); then
    scheme=https
    curl_opts="-fsSk --pinnedpubkey 'sha256//$pin'"
  fi
  if [[ $format == zip ]]; then
    extract="unzip -q '$base.$format'"
  else
    extract="tar -xzf '$base.$format'"
  fi
  limits="until $(share_clock "$(( $(date +%s) + ttl_seconds ))")"
  if (( max_downloads == 1 )); then
    limits+=", or after 1 download"
  elif (( max_downloads > 1 )); then
    limits+=", or after $max_downloads downloads"
  fi

  local url="$scheme://$url_host:$port$url_path"
  printf 'Sharing %s (%s) %s. Press Ctrl-C to stop earlier.\n\n' "$base.$format" "$size" "$limits"
  printf 'URL:     %s\n' "$url"
  printf 'SHA-256: %s\n\n' "$sha"
  printf 'On the target:\n'
  printf "  curl %s -o '%s' '%s' && echo '%s  %s' | sha256sum -c - && %s\n\n" \
    "$curl_opts" "$base.$format" "$url" "$sha" "$base.$format" "$extract"
  if (( tls )); then
    printf 'Send this command to the target over a channel you trust.\n'
  else
    printf 'Plain HTTP: the network can read the archive. The checksum only protects\n'
    printf 'it if this command reaches the target over a channel you trust. Use --tls\n'
    printf 'on networks you do not trust.\n'
  fi

  local rc=0
  wait "$SHARE_SERVER_PID" || rc=$?
  SHARE_SERVER_PID=""
  return "$rc"
}

main() {
  local command_name=${1:-help}
  [[ $# -eq 0 ]] || shift
  case "$command_name" in
    install)      server_install "$@" ;;
    status)       server_status "$@" ;;
    doctor)       server_doctor "$@" ;;
    backup)       server_backup "$@" ;;
    fsck)         server_fsck "$@" ;;
    repo-set-default) server_repo_set_default "$@" ;;
    host-keys)    server_host_keys "$@" ;;
    ssh-limits)   server_ssh_limits "$@" ;;
    admin-clone)  admin_clone "$@" ;;
    admin-init)   admin_init "$@" ;;
    user-add)     user_add "$@" ;;
    user-remove)  user_remove "$@" ;;
    user-list)    user_list "$@" ;;
    repo-set)     repo_set "$@" ;;
    repo-add)     repo_add "$@" ;;
    repo-show)    repo_show "$@" ;;
    repo-list)    repo_list "$@" ;;
    group-set)    group_set "$@" ;;
    group-remove) group_remove "$@" ;;
    group-list)   group_list "$@" ;;
    sync)         admin_sync "$@" ;;
    apply)        admin_apply "$@" ;;
    agent-branches) agent_branches "$@" ;;
    share)        share "$@" ;;
    version|--version|-V) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "Unknown command: $command_name" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
