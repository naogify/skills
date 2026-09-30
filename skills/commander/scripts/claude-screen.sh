#!/usr/bin/env bash
# 画面テキストの分類（source して使う。単体では何もしない）。spawn.sh / watch.sh / status.sh 共用。
#
# claude_screen_state <画面>  →  ok / dialog / absent
#   dialog : 確認ダイアログ（"Enter to confirm"）で止まっている
#   absent : claude の UI が見えない。素のシェルのプロンプトに戻っている＝claude が終了している
#   ok     : claude の UI が見えている
#
# 事故（2026-09-30）: 信頼ダイアログで「No, exit」が選ばれて claude が終了し、素のシェルだけが
# 残った部下が 2 時間近く誰にも気付かれなかった。「claude が動いていない」を画面から直接
# 判定できるようにする。
#
# 判定順序が重要: 終了後のシェルの画面には、スクロールバックに claude の古い表示
# （"Bypassing Permissions" や ❯ の行）が残る。そのため「最後の非空行がシェルのプロンプト
# （$ % # で終わる）」を、古い UI の手がかりより先に見る。ただし生成中を示す
# "esc to interrupt" だけは、今動いている証拠なので最優先で ok にする。
claude_screen_state() {
  local scr=$1 last
  case "$scr" in
    *"Enter to confirm"*) printf 'dialog\n'; return ;;
    *"esc to interrupt"*) printf 'ok\n'; return ;;
  esac
  last=$(printf '%s\n' "$scr" | grep -v '^[[:space:]]*$' | tail -n 1)
  if printf '%s' "$last" | grep -qE '[$%#][[:space:]]*$'; then
    printf 'absent\n'; return
  fi
  case "$scr" in
    *"tokens)"*|*"Bypassing Permissions"*|*"? for shortcuts"*|*"bypass permissions"*|*"accept edits"*)
      printf 'ok\n'; return ;;
  esac
  if printf '%s' "$scr" | grep -qE '^[[:space:]]*❯([[:space:]]|$)'; then
    printf 'ok\n'
  else
    printf 'absent\n'
  fi
}

# 信頼ダイアログで「Yes, I trust this folder」を選ぶために送るキーを決める。
#   trust_dialog_keys <画面>  →  "down N" / "up N" / "enter"（既に Yes が選択中）。判別できなければ 1 を返す
# 選択肢の行（"No, exit" と "Yes, I trust this folder" を含む行）を上から数え、
# カーソル（行頭の ❯）がある行と Yes の行の差だけ矢印を送る。既定位置が変種で変わっても、
# Enter 単発で「No, exit」を選ぶことが無い。カーソル行か Yes の行が見つからなければ
# 推測せず失敗を返す（呼び出し側は自動応答せず起動失敗にする）。
trust_dialog_keys() {
  printf '%s\n' "$1" | awk '
    /No, exit|Yes, I trust this folder/ {
      n++
      if ($0 ~ /Yes, I trust this folder/) yes = n
      if ($0 ~ /^[[:space:]]*❯/) cur = n
    }
    END {
      if (!yes || !cur) exit 1
      d = yes - cur
      if (d == 0) print "enter"
      else if (d > 0) print "down " d
      else print "up " (-d)
    }'
}
