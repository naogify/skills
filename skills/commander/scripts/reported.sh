#!/usr/bin/env bash
# 完了を人間に報告し終えたら、その完了を reported.log に記録する。
#   reported.sh <mission-dir> <no> [name]
#
# inbox.sh は reported.log を「タブ区切り・第2フィールド=部下番号」という形式で読み、
# completed.log と突き合わせて「★人間へ未報告の完了」を出す。この形式は SKILL.md にしか
# 書かれておらず、司令官が半角スペース区切りで手書きした結果、第2フィールドが一致せず
# 同じ完了が何度も再提示され続けた事故が起きた。手で reported.log を編集せず、必ずこの
# スクリプト経由で追記すること。
set -uo pipefail
die() { printf '%s\n' "reported: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: reported.sh <mission-dir> <no> [name]"
MISSION=$1; NO=$2; NAME=${3:-}
[ -d "$MISSION" ] || die "mission ディレクトリが無い: $MISSION"

printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NO" "$NAME" >> "$MISSION/reported.log" \
  || die "reported.log への追記に失敗: $MISSION/reported.log"

printf 'reported.log に記録した: 部下%s %s\n' "$NO" "$NAME"
