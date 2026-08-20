#!/usr/bin/env bash
# ミッションを開始する。mission ディレクトリと、サイドバーのグループを作る。
#   mission-start.sh <slug> <ミッション名> [依頼原文]
# 標準出力の最後に mission ディレクトリの絶対パスを返す（呼び出し側はこれを控える）。
set -uo pipefail
export CMUX_QUIET=1

die() { printf '%s\n' "mission-start: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: mission-start.sh <slug> <ミッション名> [依頼原文]"
SLUG=$1; NAME=$2; BRIEF=${3:-}

command -v cmux >/dev/null || die "cmux が無い"
command -v jq   >/dev/null || die "jq が無い"
cmux ping >/dev/null 2>&1 || die "cmux ソケットに繋がらない"

MISSION="$HOME/.claude/commander/$(date +%Y%m%d-%H%M)-$SLUG"
mkdir -p "$MISSION/workers" || die "mission ディレクトリを作れない: $MISSION"
printf '# ミッション: %s\n\n## 依頼（人間の原文）\n%s\n' "$NAME" "$BRIEF" > "$MISSION/MISSION.md"

# 司令官（自分）を名乗ってピン留めする。冪等
cmux workspace-action --action rename --title "司令官" >/dev/null 2>&1
cmux workspace-action --action pin >/dev/null 2>&1
cmux workspace-action --action set-description --description "$NAME" >/dev/null 2>&1

# ミッションのグループを作る。anchor はミッションのヘッダー兼、雑用シェルになる
g=$(cmux workspace-group create --name "$NAME" --cwd "$MISSION" --json 2>&1)
gref=$(printf '%s' "$g" | jq -r '.group.ref // empty' 2>/dev/null)
if [ -n "$gref" ]; then
  anchor=$(printf '%s' "$g" | jq -r '.group.anchor_workspace_ref // empty')
  cmux workspace-group set-color "$gref" --hex '#4C8DFF' >/dev/null 2>&1
  cmux workspace-group set-icon  "$gref" --symbol "person.3.fill" >/dev/null 2>&1
  cmux workspace-group pin "$gref" >/dev/null 2>&1
  cmux rename-workspace --workspace "$anchor" "${NAME}（本部）" >/dev/null 2>&1
  printf '%s\n' "$gref" > "$MISSION/group.ref"
  printf 'anchor=%s\n' "$anchor" >> "$MISSION/group.ref"
  printf 'グループ: %s (%s) / anchor=%s\n' "$NAME" "$gref" "$anchor"
else
  printf 'warn: グループを作れなかった。部下はグループなしで起動する（%s）\n' "$(printf '%s' "$g" | head -1)" >&2
fi

printf 'MISSION=%s\n' "$MISSION"
