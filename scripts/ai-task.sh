#!/usr/bin/env bash
# ai-task: start, resume, list, finish and restore isolated task worktrees for AI agents.
#
#   bash scripts/ai-task.sh start <task-name> [--no-install] [--no-claude]
#   bash scripts/ai-task.sh resume <task-name>
#   bash scripts/ai-task.sh list
#   bash scripts/ai-task.sh finish <task-name> [--rescue] [--allow-open] [--drop-db]
#   bash scripts/ai-task.sh restore <rescue-folder> [new-task-name]
#
# start    Fetches the default branch; creates a worktree on a new branch from it; copies the
#          COPY_FILES; picks a free port; if configured, creates a task database, writes its
#          connection settings and verifies the app resolves to it BEFORE installing anything;
#          installs; starts Claude Code with .ai-task.env loaded. If any step fails, the
#          worktree, branch and any database it created are removed again.
# resume   Reloads saved task settings, verifies its database when configured, and resumes
#          Claude Code. Use this after reopening a terminal or restoring a task.
# list     Each task worktree: branch, uncommitted files, unpushed commits, PR state, port.
# finish   Removes a task only when nothing would be lost: no uncommitted changes, no unpushed
#          commits, no gitignored files except DISPOSABLE ones and unchanged copies, and a
#          pull request state that could be confirmed (not open, unless --allow-open).
#          --rescue saves everything first: commits and pushes code to rescue/<date>-<task>,
#          copies other local files to a private folder outside the repository (never pushed),
#          verifies both, writes a manifest with restore steps, and only then removes.
#          Task databases are kept unless --drop-db; with --drop-db and DB_DUMP_CMD, a dump is
#          written and checked first. Any failure leaves the worktree untouched.
# restore  Recreates a task from a rescue folder: branch, local files, a new port.
#
# Settings: .ai-build/project.env in the main checkout. Written for bash 3.2 (macOS).
# Local tooling only: it does not watch anything after it exits, and it does not open cmux
# workspaces.
set -euo pipefail

die() { echo "ai-task: $*" >&2; exit 1; }

ROOT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || die "not inside a git repository"
ROOT="$(dirname "$ROOT")"
cd "$ROOT"

DEFAULT_BRANCH="main"; BRANCH_PREFIX="task/"; WORKTREE_DIR=".claude/worktrees"
INSTALL_CMD=""; PORT_BASE=3100; PORT_RANGE=100; COPY_FILES=""; DISPOSABLE=""; DEV_CMD=""
DB_PREFIX=""; DB_CREATE_CMD=""; DB_ENV_CMD=""; DB_VERIFY_CMD=""; DB_DUMP_CMD=""; DB_DROP_CMD=""
RESCUE_DIR=""; CLAUDE_MODE="plain"
# shellcheck disable=SC1091
[ -f .ai-build/project.env ] && . .ai-build/project.env
RESCUE_DIR="${RESCUE_DIR:-$HOME/.ai-task-rescue}"

cmd="${1:-}"; shift || true

valid_name() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,39}$'; }
wt_path() { printf '%s/%s/%s' "$ROOT" "$WORKTREE_DIR" "$1"; }
registered_worktree() { # dir : true only for a worktree git lists whose top level is dir itself
  local want top p
  want="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$want" ] || return 1
  while IFS= read -r p; do
    [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$want" ] && return 0
  done <<< "$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,""); print}')"
  return 1
}
with_task_env() { # dir command... : runs a command with .ai-task.env loaded
  local d="$1"; shift
  ( cd "$d" && set -a && . ./.ai-task.env && set +a && bash -c "$*" )
}

port_busy() { # port -> 0 if something listens on it or the test hook marks it busy
  case " ${AI_TASK_BUSY_PORTS:-} " in *" $1 "*) return 0 ;; esac
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
  return 1
}
port_taken_by_task() {
  local f
  for f in "$ROOT/$WORKTREE_DIR"/*/.ai-task.env; do
    [ -f "$f" ] || continue
    grep -qx "PORT=$1" "$f" && return 0
  done
  return 1
}
# Port reservation: picking a port and writing it to .ai-task.env happen under one exclusive
# lock, so two tasks started at the same moment cannot pick the same port. The lock is a kernel
# file lock (flock via perl, which macOS ships), held on file descriptor 9: the system releases
# it when this process exits for any reason, so a crashed launcher never leaves a stale lock.
# The lock file itself stays in place and is never removed.
PORT_LOCK="$(git rev-parse --path-format=absolute --git-common-dir)/ai-task-port.lock"
port_lock() {
  local tries=0
  command -v perl >/dev/null 2>&1 || die "perl is needed to lock port selection"
  exec 9>>"$PORT_LOCK" || die "cannot open $PORT_LOCK"
  until perl -e 'use Fcntl qw(:flock); open(my $f, ">&=", 9) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 1'; do
    tries=$((tries + 1)); [ "$tries" -le 300 ] || die "another ai-task start or restore is still choosing a port"
    sleep 0.1
  done
}
port_unlock() { exec 9>&-; }
# Keep each task's .ai-task.env (port, database and connection settings) out of git, so a
# rescue commit can never include it. Called by start and restore before the file is written.
exclude_task_env() {
  local exclude
  exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  grep -qx '.ai-task.env' "$exclude" 2>/dev/null || echo '.ai-task.env' >> "$exclude"
}
pick_port() { # name
  local h i p
  h=$(printf '%s' "$1" | cksum | awk '{print $1}')
  i=0
  while [ "$i" -lt "$PORT_RANGE" ]; do
    p=$((PORT_BASE + (h + i) % PORT_RANGE))
    if ! port_taken_by_task "$p" && ! port_busy "$p"; then echo "$p"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# Pull request state for a branch: "OPEN 12 <sha>", "MERGED 9 <sha>", "CLOSED 4 <sha>",
# "none" (GitHub confirmed there is no pull request) or "unknown" (could not ask GitHub).
pr_info() {
  local out
  command -v gh >/dev/null 2>&1 || { echo unknown; return; }
  if ! out="$(gh pr list --head "$1" --state all --limit 50 --json state,number,headRefOid \
        --jq 'if length == 0 then "none" else ((map(select(.state == "OPEN")) + .)[0] | "\(.state) \(.number) \(.headRefOid)") end')"; then
    echo unknown; return
  fi
  case "$out" in none|OPEN\ *|MERGED\ *|CLOSED\ *) echo "$out" ;; *) echo unknown ;; esac
}
pr_label() {
  local s n _h
  read -r s n _h <<< "$(pr_info "$1")"
  case "$s" in OPEN|MERGED|CLOSED) echo "$s #$n" ;; *) echo "$s" ;; esac
}
unpushed_count() { git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null || echo "?"; }

ignored_entries() { # worktree -> ignored paths (folders end in "/"), one per line
  local rec
  git -C "$1" status --porcelain=v1 --ignored --untracked-files=normal -z | while IFS= read -r -d '' rec; do
    case "$rec" in '!! '*) printf '%s\n' "${rec#!! }" ;; esac
  done
}
ignored_files_in() { # worktree folder/ -> every ignored file under it, one per line
  git -C "$1" ls-files --others --ignored --exclude-standard -z -- "$2" | tr '\0' '\n'
}
is_disposable() { # worktree entry
  local wt="$1" e="$2" f pat
  [ "$e" = ".ai-task.env" ] && return 0
  set -f
  for f in $COPY_FILES; do
    if [ "$e" = "$f" ] && [ -f "$ROOT/$f" ] && cmp -s "$wt/$e" "$ROOT/$f"; then set +f; return 0; fi
  done
  for pat in $DISPOSABLE; do
    # shellcheck disable=SC2254
    case "$e" in $pat) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

case "$cmd" in
start)
  name="${1:-}"; shift || true
  install=1; launch=1
  for a in "$@"; do
    case "$a" in --no-install) install=0 ;; --no-claude) launch=0 ;; *) die "unknown option $a" ;; esac
  done
  valid_name "$name" || die "task name must be lowercase letters, digits and dashes (max 40)"
  wt="$(wt_path "$name")"; branch="$BRANCH_PREFIX$name"
  [ -e "$wt" ] && die "worktree already exists: $wt (resume: bash scripts/ai-task.sh resume $name)"
  git show-ref --quiet "refs/heads/$branch" && die "branch $branch already exists locally"
  git fetch --quiet origin "$DEFAULT_BRANCH" || die "could not fetch origin/$DEFAULT_BRANCH"
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 && die "branch $branch already exists on origin"
  if [ -n "$DB_PREFIX" ] && [ -z "$DB_VERIFY_CMD" ]; then
    die "DB_PREFIX is set but DB_VERIFY_CMD is empty; the launcher will not run installs or migrations without proof the app uses the task database"
  fi
  port_lock
  port="$(pick_port "$name")" || die "no free port in $PORT_BASE..$((PORT_BASE + PORT_RANGE - 1))"

  git check-ignore -q "$WORKTREE_DIR/probe" || echo "warning: $WORKTREE_DIR/ is not gitignored; add it to .gitignore" >&2
  exclude_task_env

  db=""; db_created=0
  [ -n "$DB_PREFIX" ] && db="${DB_PREFIX}_$(printf '%s' "$name" | tr '-' '_')"
  rollback() { # undo everything start created, then stop
    echo "ai-task: $1" >&2
    git worktree remove --force "$wt" >/dev/null 2>&1 || true
    git branch -D "$branch" >/dev/null 2>&1 || true
    if [ "$db_created" = 1 ] && [ -n "$DB_DROP_CMD" ]; then
      AI_TASK_DB="$db" bash -c "$DB_DROP_CMD" >/dev/null 2>&1 || echo "ai-task: could not drop $db" >&2
    fi
    echo "ai-task: start undone; nothing was installed" >&2
    exit 1
  }

  mkdir -p "$ROOT/$WORKTREE_DIR"
  git worktree add --quiet -b "$branch" "$wt" "origin/$DEFAULT_BRANCH"
  base="$(git -C "$wt" rev-parse HEAD)"

  set -f
  for f in $COPY_FILES; do
    if [ -f "$ROOT/$f" ]; then
      if git check-ignore -q "$f"; then mkdir -p "$(dirname "$wt/$f")"; cp -p "$ROOT/$f" "$wt/$f"
      else echo "warning: $f is not gitignored; not copied" >&2; fi
    fi
  done
  set +f

  ( umask 077
  {
    echo "AI_TASK_NAME=$name"
    echo "AI_TASK_BRANCH=$branch"
    echo "AI_TASK_BASE=$base"
    echo "PORT=$port"
    echo "AI_TASK_DB=$db"
  } > "$wt/.ai-task.env"
  )
  port_unlock

  if [ -n "$db" ]; then
    if [ -n "$DB_CREATE_CMD" ]; then
      (cd "$wt" && AI_TASK_DB="$db" bash -c "$DB_CREATE_CMD") || rollback "database setup failed: $DB_CREATE_CMD"
      db_created=1
    fi
    if [ -n "$DB_ENV_CMD" ]; then
      envlines="$(cd "$wt" && AI_TASK_DB="$db" PORT="$port" bash -c "$DB_ENV_CMD")" || rollback "DB_ENV_CMD failed"
      if [ -n "$envlines" ]; then
        printf '%s\n' "$envlines" | grep -Eqv '^[A-Za-z_][A-Za-z0-9_]*=' && rollback "DB_ENV_CMD must print KEY=VALUE lines only"
        printf '%s\n' "$envlines" >> "$wt/.ai-task.env"
      fi
    fi
    with_task_env "$wt" "$DB_VERIFY_CMD" || rollback "DB_VERIFY_CMD failed: the app does not resolve to $db, so nothing was installed or migrated"
  fi
  if [ "$install" = 1 ] && [ -n "$INSTALL_CMD" ]; then
    with_task_env "$wt" "$INSTALL_CMD" || rollback "install failed: $INSTALL_CMD"
  fi

  repo="$(basename "$ROOT")"
  echo "Task ready"
  echo "  folder:    $wt"
  echo "  branch:    $branch (from origin/$DEFAULT_BRANCH ${base:0:7})"
  echo "  port:      $port"
  [ -n "$db" ] && echo "  database:  $db (verified)"
  echo "  settings:  $wt/.ai-task.env (values withheld)"
  echo "  workspace: rename this cmux workspace to \"$repo · $name\""
  [ -n "$DEV_CMD" ] && echo "  dev:       cd \"$wt\" && set -a && . ./.ai-task.env && set +a && $DEV_CMD"
  if [ "$launch" = 1 ]; then
    command -v claude >/dev/null 2>&1 || die "claude not found on PATH"
    set -a; . "$wt/.ai-task.env"; set +a      # commands Claude runs inherit PORT and database settings
    if [ "$CLAUDE_MODE" = "worktree" ]; then cd "$ROOT" && exec claude --worktree "$name"
    else cd "$wt" && exec claude; fi
  fi
  ;;

resume)
  name="${1:-}"
  [ "$#" -eq 1 ] && valid_name "$name" || die "usage: ai-task.sh resume <task-name>"
  wt="$(wt_path "$name")"
  [ -f "$wt/.ai-task.env" ] || die "task settings missing: $wt/.ai-task.env"
  command -v claude >/dev/null 2>&1 || die "claude not found on PATH"
  chmod 600 "$wt/.ai-task.env"
  set -a; . "$wt/.ai-task.env"; set +a
  if [ -n "${AI_TASK_DB:-}" ]; then
    [ -n "$DB_VERIFY_CMD" ] || die "DB_VERIFY_CMD is required before resuming a task with a database"
    with_task_env "$wt" "$DB_VERIFY_CMD" || die "database verification failed; Claude was not started"
  fi
  cd "$wt" && exec claude --continue
  ;;

list)
  printf '%-24s %-28s %-6s %-9s %-12s %s\n' TASK BRANCH DIRTY UNPUSHED PR PORT
  git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,""); print}' | while IFS= read -r wt; do
    case "$wt" in "$ROOT/$WORKTREE_DIR/"*) ;; *) continue ;; esac
    name="$(basename "$wt")"
    branch="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
    dirty="$( (git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null || true) | wc -l | tr -d ' ')"
    ahead="$(unpushed_count "$wt")"
    port="$( (grep '^PORT=' "$wt/.ai-task.env" 2>/dev/null || true) | cut -d= -f2)"
    printf '%-24s %-28s %-6s %-9s %-12s %s\n' "$name" "${branch:-detached}" "$dirty" "$ahead" "$(pr_label "$branch")" "${port:--}"
  done
  ;;

finish)
  name="${1:-}"; shift || true
  rescue=0; allow_open=0; drop_db=0
  for a in "$@"; do
    case "$a" in --rescue) rescue=1 ;; --allow-open) allow_open=1 ;; --drop-db) drop_db=1 ;; *) die "unknown option $a" ;; esac
  done
  valid_name "$name" || die "invalid task name"
  wt="$(wt_path "$name")"
  [ -d "$wt" ] || die "no task worktree at $wt"
  # A plain folder here is not a worktree: git would resolve it to the main checkout, and a
  # rescue would commit and push that checkout's work. Require a registered worktree whose own
  # top level is this folder.
  registered_worktree "$wt" || die "$wt is not a registered task worktree; nothing changed"
  branch="$(git -C "$wt" branch --show-current)"
  db="$( (grep '^AI_TASK_DB=' "$wt/.ai-task.env" 2>/dev/null || true) | cut -d= -f2)"
  head="$(git -C "$wt" rev-parse HEAD)"

  # Prune, so a branch deleted on GitHub no longer counts as a copy of these commits. Without
  # current remote state the unpushed check cannot be trusted, so stop.
  git fetch --quiet --prune origin || die "could not fetch origin, so pushed commits cannot be confirmed; nothing removed"
  # --untracked-files: a status.showUntrackedFiles=no setting must not hide work from cleanup.
  dirty="$(git -C "$wt" status --porcelain --untracked-files=normal)"
  ahead="$(unpushed_count "$wt")"
  read -r pr_s pr_n pr_head <<< "$(pr_info "$branch")"
  pr_head="${pr_head:-}"
  # A squash-merged branch is usually deleted from origin, so its commits look unpushed. They
  # are safe only when the pull request merged exactly the commit checked out here.
  if [ "$ahead" != "0" ] && [ "$pr_s" = "MERGED" ] && [ "$pr_head" = "$head" ]; then ahead=0; fi

  entries="$(ignored_entries "$wt")" || die "could not list ignored files; nothing removed"
  keep=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    is_disposable "$wt" "$e" && continue
    case "$e" in
      */) # a folder that is not disposable as a whole: judge each file in it
        files="$(ignored_files_in "$wt" "$e")" || die "could not list files in $e; nothing removed"
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          is_disposable "$wt" "$f" || keep="$keep$f"$'\n'
        done <<< "$files" ;;
      *) keep="$keep$e"$'\n' ;;
    esac
  done <<< "$entries"

  reasons=""
  [ -n "$dirty" ] && reasons="${reasons}- uncommitted changes:"$'\n'"$(printf '%s\n' "$dirty" | sed 's/^/    /')"$'\n'
  [ "$ahead" != "0" ] && reasons="${reasons}- commits not on any remote branch: $ahead"$'\n'
  [ -n "$keep" ] && reasons="${reasons}- gitignored files that are not listed as disposable:"$'\n'"$(printf '%s' "$keep" | sed 's/^/    /')"$'\n'
  if [ "$rescue" != 1 ]; then
    case "$pr_s" in
      unknown) reasons="${reasons}- pull request state could not be confirmed (gh missing, signed out, or GitHub unavailable)"$'\n' ;;
      OPEN) [ "$allow_open" = 1 ] || reasons="${reasons}- pull request #$pr_n is open (pass --allow-open to remove only the local copy)"$'\n' ;;
    esac
    if [ -n "$reasons" ]; then
      echo "Not removing $name; nothing was changed:"
      printf '%s' "$reasons"
      echo "Push or delete what you no longer need, or run: bash scripts/ai-task.sh finish $name --rescue"
      exit 1
    fi
  fi

  rdir=""
  make_rdir() {
    [ -n "$rdir" ] && return 0
    local base n=1
    base="$RESCUE_DIR/$(basename "$ROOT")/$(date +%Y%m%d-%H%M%S)-$name"
    rdir="$base"
    while [ -e "$rdir" ]; do n=$((n + 1)); rdir="$base-$n"; done   # never reuse a folder
    ( umask 077 && mkdir -p "$rdir" ) || die "cannot create rescue folder $rdir; nothing removed"
    chmod 700 "$rdir" || die "cannot restrict permissions on $rdir; nothing removed"
  }

  rescue_branch=""; dump_file=""
  if [ "$rescue" = 1 ]; then
    make_rdir
    # Push a rescue branch whenever the commit is not on the default branch: a task branch, even
    # one already pushed, is normally deleted after a squash merge, and restore must still be
    # able to fetch the HEAD recorded in the manifest.
    if [ -n "$dirty" ] || ! git merge-base --is-ancestor "$head" "origin/$DEFAULT_BRANCH" 2>/dev/null; then
      rescue_branch="rescue/$(date +%Y%m%d)-$name"
      if [ -n "$dirty" ]; then
        git -C "$wt" add -A
        git -C "$wt" commit --quiet --no-verify -m "rescue: uncommitted work from task $name"
        head="$(git -C "$wt" rev-parse HEAD)"
      fi
      git -C "$wt" push --quiet origin "HEAD:refs/heads/$rescue_branch" || die "rescue push failed; nothing removed"
      git fetch --quiet origin "$rescue_branch"
      [ "$(git rev-parse "origin/$rescue_branch")" = "$head" ] || die "rescue branch does not match; nothing removed"
    fi
    if [ -n "$keep" ]; then
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        p="${e%/}"
        mkdir -p "$rdir/files/$(dirname "$p")" || die "cannot copy $p; nothing removed"
        cp -Rp "$wt/$p" "$rdir/files/$p" || die "cannot copy $p; nothing removed"
        diff -r "$wt/$p" "$rdir/files/$p" >/dev/null 2>&1 || die "copy of $p does not match; nothing removed"
      done <<< "$keep"
      ( cd "$rdir/files" && find . -type f -exec cksum {} + ) > "$rdir/files.cksum" || die "cannot record checksums; nothing removed"
    fi
  fi

  if [ "$drop_db" = 1 ] && [ -n "$db" ]; then
    [ -n "$DB_DROP_CMD" ] || die "--drop-db needs DB_DROP_CMD; nothing removed"
    if [ -n "$DB_DUMP_CMD" ]; then
      make_rdir
      dump_file="$rdir/database.dump"
      (cd "$wt" && AI_TASK_DB="$db" AI_TASK_DUMP="$dump_file" bash -c "$DB_DUMP_CMD") || die "database dump failed; nothing removed"
      [ -s "$dump_file" ] || die "database dump is empty; nothing removed"
    fi
  fi

  if [ -n "$rdir" ]; then
    {
      echo "# ai-task rescue manifest"
      echo "TASK=$name"
      echo "REPO=$ROOT"
      echo "BRANCH=$branch"
      echo "HEAD=$head"
      echo "RESCUE_BRANCH=$rescue_branch"
      echo "DB=$db"
      echo "DB_DUMP=${dump_file:+database.dump}"
      echo "DB_STATE=$([ "$drop_db" = 1 ] && [ -n "$db" ] && echo dropped || echo kept)"
      echo "CREATED=$(date '+%Y-%m-%d %H:%M:%S')"
      printf '%s' "$keep" | sed '/^$/d; s/\/$//; s/^/FILE=/'
      echo "# Restore: bash scripts/ai-task.sh restore \"$rdir\" [new-task-name]"
      echo "# Files are under files/ (private: not pushed anywhere); checksums in files.cksum."
      [ -n "$dump_file" ] && echo "# Database dump: database.dump (restore with your project's restore command)."
      true
    } > "$rdir/MANIFEST.txt" || die "cannot write manifest; nothing removed"
    echo "Saved to $rdir${rescue_branch:+ and origin/$rescue_branch}"
  fi

  git worktree remove --force "$wt"
  git branch -D "$branch" >/dev/null 2>&1 || true
  # A task that revised an existing branch (such as a bot's draft) switched away from the
  # branch start created. Remove that one too, but only if its commit is on a remote branch.
  orig="$BRANCH_PREFIX$name"
  if [ "$orig" != "$branch" ] && git show-ref --verify --quiet "refs/heads/$orig"; then
    if [ -n "$(git branch -r --contains "refs/heads/$orig" 2>/dev/null)" ]; then
      git branch -D "$orig" >/dev/null 2>&1 || echo "warning: could not delete branch $orig" >&2
    else
      echo "warning: kept branch $orig: it has commits on no remote branch" >&2
    fi
  fi
  if [ "$drop_db" = 1 ] && [ -n "$db" ]; then
    if AI_TASK_DB="$db" bash -c "$DB_DROP_CMD"; then echo "Dropped database $db"
    else echo "warning: could not drop $db; it still exists" >&2; fi
  elif [ -n "$db" ]; then
    echo "Database $db kept (finish --drop-db removes it)"
  fi
  echo "Removed task $name"
  ;;

restore)
  rdir="${1:-}"; name="${2:-}"
  [ -f "$rdir/MANIFEST.txt" ] || die "no MANIFEST.txt in $rdir"
  get() { (grep "^$1=" "$rdir/MANIFEST.txt" || true) | head -n 1 | cut -d= -f2-; }
  orig="$(get TASK)"; rb="$(get RESCUE_BRANCH)"; rhead="$(get HEAD)"; rdb="$(get DB)"
  name="${name:-$orig}"
  valid_name "$name" || die "invalid task name"
  wt="$(wt_path "$name")"; branch="$BRANCH_PREFIX$name"
  [ -e "$wt" ] && die "worktree already exists: $wt"
  git show-ref --quiet "refs/heads/$branch" && die "branch $branch already exists locally"
  if [ -n "$rb" ]; then
    git fetch --quiet origin "$rb" || die "cannot fetch origin/$rb"
    start_at="origin/$rb"
    # The same rescue branch can move on after a later rescue of the same task on the same day:
    # restore exactly the commit this rescue recorded.
    if [ -n "$rhead" ]; then
      git cat-file -e "${rhead}^{commit}" 2>/dev/null || die "commit $rhead from the manifest is not available"
      git merge-base --is-ancestor "$rhead" "origin/$rb" || die "commit $rhead is not on origin/$rb"
      start_at="$rhead"
    fi
  else
    git cat-file -e "${rhead}^{commit}" 2>/dev/null || git fetch --quiet origin || true
    git cat-file -e "${rhead}^{commit}" 2>/dev/null || die "commit $rhead is not available"
    start_at="$rhead"
  fi
  exclude_task_env
  port_lock
  port="$(pick_port "$name")" || die "no free port"
  mkdir -p "$ROOT/$WORKTREE_DIR"
  git worktree add --quiet -b "$branch" "$wt" "$start_at"
  if [ -d "$rdir/files" ]; then
    cp -Rp "$rdir/files/." "$wt/"
    while IFS= read -r f; do
      diff -r "$rdir/files/$f" "$wt/$f" >/dev/null 2>&1 || die "restored $f does not match the rescue copy"
    done < <(grep '^FILE=' "$rdir/MANIFEST.txt" | cut -d= -f2-)
  fi
  ( umask 077
  {
    echo "AI_TASK_NAME=$name"
    echo "AI_TASK_BRANCH=$branch"
    echo "AI_TASK_BASE=$(git -C "$wt" rev-parse HEAD)"
    echo "PORT=$port"
    echo "AI_TASK_DB=$rdb"
  } > "$wt/.ai-task.env"
  )
  port_unlock
  echo "Restored task $name at $wt on $branch (port $port)"
  if [ -n "$rdb" ]; then
    echo "Database: $rdb (re-run your DB_ENV_CMD and DB_VERIFY_CMD steps; restore $rdir/database.dump if it was dropped)"
  fi
  ;;

*)
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
  ;;
esac
