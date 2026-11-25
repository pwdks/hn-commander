#!/usr/bin/env bash
# hn-commander: 역할 배정·작업 단계·에이전트 넘기기 (Windows Git Bash / macOS bash 3.2 호환)
# 사용: bash .harness/bin/hn.sh <명령> [인자]
#   roles                       현재 역할 배정 표
#   role-set <역할> <claude|codex|none>
#   preset <claude|codex>       메인/서브 프리셋 적용
#   on | off                    하네스 켜기/끄기
#   codex-sandbox <auto|full>   위임받은 Codex의 샌드박스 (auto: 역할 권한대로, full: 풀기)
#   start <종류> "<요청 요약>"   작업 시작 (종류: .harness/pipelines.conf)
#   next                        다음 단계와 담당
#   done <역할> "<한 줄 결과>"   단계 완료
#   skip <역할> "<이유>"         단계 건너뜀
#   delegate <역할> "<목표>"     다른 에이전트에게 맡기고 결과를 받음 (그쪽이 한도에 걸리면 대신 하라고 알림)
#   limits [clear [claude|codex]]  넘겨받는 에이전트의 한도 기록 보기 / 지우기
#   fix-round                   검토 지적 → 고치기 + 다시 검토 (1회까지)
#   wait                        사용자에게 묻기 전에 (훅이 재촉하지 않음)
#   cancel | finish | status
#   stop-hook                   Claude/Codex Stop 훅에서 호출
#   update                      이 프로젝트를 설치된 최신 버전으로 (= init)
#   update-all                  등록된 모든 프로젝트를 최신으로 (설치 스크립트가 호출)
#   lang-detect | lang <ko|en|…>  답변 언어 감지 / 설정 (Claude·Codex 사용자 전체 설정)
#   init | hooks | section <claude|codex>   /hn-setup에서 사용
set -u

ROLES="orchestrator architect developer tester reviewer debugger integrator optimizer documenter"
MAIN_ROLES="orchestrator architect developer debugger integrator"
SUB_ROLES="tester reviewer documenter optimizer"
MAX_FIX_ROUNDS=1
RESULT_INLINE=4000

HN_HOME="${HN_HOME:-$HOME/.hn-commander}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
H="$ROOT/.harness"
ROLES_FILE="$H/roles.conf"
PIPES_FILE="$H/pipelines.conf"
STATE="$H/state"
CUR="$STATE/current.conf"
LOG="$STATE/log.md"
LIMITS="$STATE/limits.conf"   # 넘겨받은 에이전트가 한도에 걸린 기록: <에이전트>=<다시 넘겨 볼 시각(epoch)>
LIMIT_DEFAULT_MIN=15          # 풀리는 시각을 못 읽었을 때 다시 넘겨 볼 때까지 기다리는 분

die() { echo "hn: $*" >&2; exit 1; }

# key=value 파일 읽기/쓰기 (sed -i 없이)
kv_get() { [ -f "$1" ] && grep -E "^$2=" "$1" | head -1 | cut -d= -f2- ; }
kv_set() {
  f="$1"; k="$2"; v="$3"; t="$f.tmp.$$"
  touch "$f"
  grep -vE "^$k=" "$f" > "$t" || true
  printf '%s=%s\n' "$k" "$v" >> "$t"
  mv "$t" "$f"
}

is_role() { for r in $ROLES; do [ "$r" = "$1" ] && return 0; done; return 1; }
agent_of() { a="$(kv_get "$ROLES_FILE" "$1")"; [ -n "$a" ] && echo "$a" || echo none; }
enabled() { [ "$(kv_get "$ROLES_FILE" enabled)" = "1" ]; }
role_file() { f="$(ls "$ROOT"/docs/roles/*-"$1".md 2>/dev/null | head -1)"; echo "${f#$ROOT/}"; }

desc_of() {
  case "$1" in
    orchestrator) echo "요청을 역할별 작업으로 나눔" ;;
    architect)    echo "바꿀 파일과 방법을 요점으로 설계" ;;
    developer)    echo "필요한 최소 범위로 구현" ;;
    tester)       echo "바뀐 동작을 확인하는 테스트 작성" ;;
    reviewer)     echo "버그·보안·빠진 처리 검토" ;;
    debugger)     echo "오류 재현 → 원인 → 최소 수정" ;;
    integrator)   echo "작업 사이 어긋난 연결을 맞춤" ;;
    optimizer)    echo "측정 근거로 성능 개선" ;;
    documenter)   echo "사용자가 알아야 할 변경을 문서화" ;;
  esac
}

perm_of() {
  case "$1" in
    orchestrator|architect|reviewer) echo read-only ;;
    developer|tester|documenter)     echo edit ;;
    *)                               echo edit+exec ;;
  esac
}

codex_sandbox() { [ "$(kv_get "$ROLES_FILE" codex_sandbox)" = full ] && echo full || echo auto; }

cmd_codex_sandbox() {
  need_roles
  case "${1:-}" in
    auto) kv_set "$ROLES_FILE" codex_sandbox auto
          echo "위임받은 Codex 샌드박스: 역할 권한대로 (읽기 전용 → read-only, 그 밖 → workspace-write)" ;;
    full) kv_set "$ROLES_FILE" codex_sandbox full
          echo "위임받은 Codex 샌드박스: 풀림 (danger-full-access)"
          echo "주의: Codex 쪽에는 커밋·푸시·삭제를 막는 장치가 없고 지시문으로만 막습니다. 'codex-sandbox auto'로 되돌림" ;;
    *) die "사용: codex-sandbox <auto|full>  (지금: $(codex_sandbox))" ;;
  esac
}

need_roles() { [ -f "$ROLES_FILE" ] || die "역할 배정이 없습니다. /hn-setup 또는 /hn-mod-role로 먼저 배정하세요"; }

# ---------- 역할 배정 ----------
cmd_roles() {
  need_roles
  if enabled; then echo "하네스: 켜짐"; else echo "하네스: 꺼짐"; fi
  if [ "$(codex_sandbox)" = full ]; then echo "위임받은 Codex 샌드박스: 풀림 (full)"; else echo "위임받은 Codex 샌드박스: 역할 권한대로 (auto)"; fi
  echo "| 역할 | 담당 | 하는 일 |"
  echo "|---|---|---|"
  for r in $ROLES; do
    a="$(agent_of "$r")"; [ "$a" = none ] && a="배정 안 함"
    echo "| $r | $a | $(desc_of "$r") |"
  done
}

cmd_role_set() {
  [ $# -eq 2 ] || die "사용: role-set <역할> <claude|codex|none>"
  is_role "$1" || die "없는 역할: $1 (가능: $ROLES)"
  case "$2" in claude|codex|none) ;; *) die "담당은 claude, codex, none 중 하나" ;; esac
  mkdir -p "$H"; kv_set "$ROLES_FILE" "$1" "$2"
  [ -n "$(kv_get "$ROLES_FILE" enabled)" ] || kv_set "$ROLES_FILE" enabled 1
  echo "$1 → $2"
}

cmd_preset() {
  case "${1:-}" in
    claude) main=claude; sub=codex ;;
    codex)  main=codex;  sub=claude ;;
    *) die "사용: preset <claude|codex>  (메인이 될 에이전트)" ;;
  esac
  mkdir -p "$H"
  for r in $MAIN_ROLES; do kv_set "$ROLES_FILE" "$r" "$main"; done
  for r in $SUB_ROLES;  do kv_set "$ROLES_FILE" "$r" "$sub";  done
  kv_set "$ROLES_FILE" enabled 1
  cmd_roles
}

# ---------- 작업 단계 ----------
steps_of() { kv_get "$CUR" steps; }
pos_of() { p="$(kv_get "$CUR" pos)"; echo "${p:-0}"; }
step_at() { i=0; for s in $(steps_of); do [ "$i" -eq "$1" ] && { echo "$s"; return; }; i=$((i+1)); done; }
count_steps() { n=0; for s in $(steps_of); do n=$((n+1)); done; echo "$n"; }
remaining() {
  p="$(pos_of)"; i=0; out=""
  for s in $(steps_of); do [ "$i" -ge "$p" ] && out="$out $s($(agent_of "$s"))"; i=$((i+1)); done
  echo "${out# }"
}
clear_wait() { [ -f "$CUR" ] && kv_set "$CUR" wait 0; }
log() { mkdir -p "$STATE"; printf -- '- %s\n' "$*" >> "$LOG"; }

cmd_start() {
  need_roles
  enabled || { echo "하네스 꺼짐: 역할 단계 없이 평소처럼 직접 작업하세요."; return 0; }
  type="${1:-}"; req="${2:-}"
  [ -n "$type" ] || die "사용: start <종류> \"<요청 요약>\". 종류: $(grep -E '^[a-z]+=' "$PIPES_FILE" | cut -d= -f1 | tr '\n' ' ')"
  grep -qE "^$type=" "$PIPES_FILE" || die "없는 종류: $type"
  [ -f "$CUR" ] && die "진행 중인 작업이 있습니다: $(kv_get "$CUR" request). finish 또는 cancel 먼저"
  pipe="$(kv_get "$PIPES_FILE" "$type")"
  if [ -z "$pipe" ]; then echo "'$type'은 역할 단계가 없습니다. 답만 하세요(파일 수정·위임 금지)."; return 0; fi
  steps=""; skipped=""
  for r in $pipe; do
    if [ "$(agent_of "$r")" = none ]; then skipped="$skipped $r"; else steps="$steps $r"; fi
  done
  steps="${steps# }"
  [ -n "$steps" ] || { echo "배정된 역할이 하나도 없어 단계 없이 직접 작업하세요."; return 0; }
  mkdir -p "$STATE/results"; rm -f "$LOG" "$STATE"/results/*.md
  kv_set "$CUR" type "$type"; kv_set "$CUR" request "$(echo "$req" | tr '\n' ' ')"
  kv_set "$CUR" steps "$steps"; kv_set "$CUR" pos 0; kv_set "$CUR" rounds 0; kv_set "$CUR" wait 0
  log "시작: [$type] $req"
  [ -n "$skipped" ] && log "배정 안 됨, 건너뜀:$skipped"
  echo "작업 시작 [$type]"
  i=1; for s in $steps; do echo "  $i. $s → $(agent_of "$s")"; i=$((i+1)); done
  [ -n "$skipped" ] && echo "  (배정 안 됨, 건너뜀:$skipped)"
  cmd_next
}

cmd_next() {
  [ -f "$CUR" ] || { echo "진행 중인 작업 없음"; return 0; }
  clear_wait
  p="$(pos_of)"; s="$(step_at "$p")"
  if [ -z "$s" ]; then echo "모든 단계 완료 → 'hn.sh finish' 실행 후 요약 보고"; return 0; fi
  a="$(agent_of "$s")"
  echo "다음: $s → $a"
  if [ "$a" = none ]; then echo "  배정 안 됨 → 'hn.sh skip $s \"배정 안 됨\"'"
  else
    echo "  지침: $(role_file "$s")"
    echo "  내가 $a 이면 직접 하고 'hn.sh done $s \"<한 줄 결과>\"'"
    echo "  아니면 'hn.sh delegate $s \"<이번 목표>\"' (오래 걸림: 타임아웃 10분 이상)"
    [ "$(limit_left "$a")" -gt 0 ] && echo "  ($a 한도 중: $(hm_of "$(kv_get "$LIMITS" "$a")") 전에는 delegate가 넘기지 않고 대신 하라고 알려 줌)"
  fi
}

advance() { # $1 역할, $2 상태, $3 메모
  [ -f "$CUR" ] || die "진행 중인 작업 없음"
  clear_wait
  p="$(pos_of)"; s="$(step_at "$p")"
  [ -n "$s" ] || die "남은 단계가 없습니다. finish 하세요"
  [ "$s" = "$1" ] || die "지금 단계는 '$s'입니다 ('$1' 아님)"
  kv_set "$CUR" pos $((p+1))
  who="$(agent_of "$1")"
  [ "$(kv_get "$CUR" proxy)" = "$1" ] && { who="$who 한도 → 대신"; kv_set "$CUR" proxy ""; }
  log "$1($who) $2: ${3:-}"
  cmd_next
}
cmd_done() { [ $# -ge 1 ] || die "사용: done <역할> \"<한 줄 결과>\""; advance "$1" 완료 "${2:-}"; }
cmd_skip() { [ $# -ge 1 ] || die "사용: skip <역할> \"<이유>\""; advance "$1" 건너뜀 "${2:-}"; }

cmd_fix_round() {
  [ -f "$CUR" ] || die "진행 중인 작업 없음"
  clear_wait
  rounds="$(kv_get "$CUR" rounds)"; rounds="${rounds:-0}"
  if [ "$rounds" -ge "$MAX_FIX_ROUNDS" ]; then
    echo "고치기 한도($MAX_FIX_ROUNDS회)를 다 썼습니다. 남은 지적은 고치지 말고 사용자에게 보고하세요."; return 0
  fi
  fixer=debugger; [ "$(agent_of debugger)" = none ] && fixer=developer
  [ "$(agent_of "$fixer")" = none ] && { echo "고칠 담당(debugger/developer)이 없어 보고만 하세요."; return 0; }
  # 지금 단계가 아직 끝내지 않은 reviewer면 "문제 있음"으로 끝낸 것으로 본다
  p="$(pos_of)"
  if [ "$(step_at "$p")" = reviewer ]; then
    p=$((p+1)); kv_set "$CUR" pos "$p"; log "reviewer($(agent_of reviewer)) 완료: 문제 있음"
  fi
  # 지금 위치에 [고치기, reviewer]를 끼워 넣는다
  i=0; new=""
  for s in $(steps_of); do
    [ "$i" -eq "$p" ] && new="$new $fixer"
    [ "$i" -eq "$p" ] && [ "$(agent_of reviewer)" != none ] && new="$new reviewer"
    new="$new $s"; i=$((i+1))
  done
  [ "$p" -ge "$i" ] && { new="$new $fixer"; [ "$(agent_of reviewer)" != none ] && new="$new reviewer"; }
  kv_set "$CUR" steps "${new# }"; kv_set "$CUR" rounds $((rounds+1))
  log "검토 지적 → 고치기 $((rounds+1))회차"
  cmd_next
}

cmd_wait()   { [ -f "$CUR" ] && kv_set "$CUR" wait 1; echo "대기: 사용자 답을 기다립니다(훅이 재촉하지 않음). 다음 hn.sh 명령에서 풀림"; }
cmd_cancel() { [ -f "$CUR" ] || { echo "진행 중인 작업 없음"; return 0; }; log "취소"; rm -f "$CUR"; echo "작업 취소"; }
cmd_status() {
  [ -f "$CUR" ] || { echo "진행 중인 작업 없음"; return 0; }
  echo "작업: [$(kv_get "$CUR" type)] $(kv_get "$CUR" request)"
  echo "남은 단계: $(remaining)"; [ "$(kv_get "$CUR" wait)" = 1 ] && echo "(사용자 답 대기 중)"
  for a in claude codex; do [ "$(limit_left "$a")" -gt 0 ] && echo "($a 한도 중: $(hm_of "$(kv_get "$LIMITS" "$a")") 전까지는 대신 진행)"; done
  [ -f "$LOG" ] && cat "$LOG"
}
cmd_finish() {
  [ -f "$CUR" ] || { echo "진행 중인 작업 없음"; return 0; }
  rest="$(remaining)"; [ -n "$rest" ] && log "끝내기 전 남은 단계: $rest"
  log "끝"
  echo "## 작업 기록"; cat "$LOG"; echo; echo "결과 파일: .harness/state/results/"
  rm -f "$CUR"
}

# ---------- 넘기기 ----------
# 한도(사용량·요청 수) 초과로 보이는 문구. 작업 내용과 헷갈리지 않게 찾는 곳을 좁힌다
#   실행 실패·결과 없음: 로그 끝부분 + 결과에서 LIMIT_RE
#   정상 종료인데 결과가 짧음: 결과에서만, 한도 안내 문구로만 쓰이는 LIMIT_RE_OK ("rate limit" 같은 말은 코드 이야기일 수 있음)
LIMIT_RE='usage limit|rate[ _-]?limit|limit reached|hit your( usage)? limit|out of (credits|quota)|quota exceeded|exceeded your (current )?quota|insufficient_quota|too many requests|(^|[^0-9])429([^0-9]|$)'
LIMIT_RE_OK='usage limit reached|hit your( usage)? limit|[0-9]+-hour limit|weekly limit reached|limit reached.{0,10}(\||resets?)'

hm_of() { date -d "@$1" '+%m/%d %H:%M' 2>/dev/null || date -r "$1" '+%m/%d %H:%M'; }

limit_left() {  # <에이전트> → 다시 넘겨 볼 때까지 남은 초 (없으면 0)
  u="$(kv_get "$LIMITS" "$1")"; case "$u" in ''|*[!0-9]*) echo 0; return ;; esac
  l=$((u - $(date +%s))); [ "$l" -gt 0 ] && echo "$l" || echo 0
}

limit_until() {  # <메시지 파일> → "<풀리는 시각 epoch> <0: 메시지에서 읽음 | 1: 못 읽어 기본값>"
  txt="$(tail -n 40 "$1" 2>/dev/null | tr 'A-Z' 'a-z' | tr '\r\n' '  ')"
  set -- $(date '+%s %H %M %S'); now="$1"; nh=$((10#$2)); nm=$((10#$3)); ns=$((10#$4))   # 한 번에 읽어 어긋나지 않게
  # 1) "limit reached|1732550400" 처럼 시각(epoch)이 그대로 적힌 경우
  e="$(printf '%s' "$txt" | grep -oE '\|[0-9]{10}' | head -1 | tr -d '|')"
  [ -n "$e" ] && [ "$e" -gt "$now" ] && { echo "$e 0"; return; }
  # 2) "try again in 2 hours 15 minutes" / "resets in 3h"
  rel="$(printf '%s' "$txt" | grep -oE '(again|resets?) in [0-9a-z ,]+' | head -1)"
  if [ -n "$rel" ]; then
    s="$(printf '%s' "$rel" | awk '{ n = split($0, t, /[ ,]+/); s = 0
      for (i = 1; i <= n; i++) { v = t[i]; u = ""
        if (v ~ /^[0-9]+$/) u = t[i + 1]
        else if (v ~ /^[0-9]+[a-z]+$/) { u = v; sub(/^[0-9]+/, "", u); sub(/[a-z]+$/, "", v) }
        else continue
        if (u ~ /^d/) s += v * 86400; else if (u ~ /^h/) s += v * 3600; else if (u ~ /^m/) s += v * 60; else if (u ~ /^s/) s += v }
      print s }')"
    [ "${s:-0}" -gt 0 ] && { echo "$((now + s)) 0"; return; }
  fi
  # 3) "resets 3pm" / "try again at 3:05 PM" / "resets at 15:00" (이 컴퓨터 시간대로 본다)
  at="$(printf '%s' "$txt" | grep -oE '(resets?( at)?|again at) [0-9]{1,2}(:[0-9]{2})? ?(am|pm)?' | head -1)"
  if [ -n "$at" ]; then
    hh="$(printf '%s' "$at" | sed -E 's/^[a-z ]* ([0-9]{1,2}).*/\1/')"
    mm="$(printf '%s' "$at" | sed -nE 's/.*:([0-9]{2}).*/\1/p')"
    ap="$(printf '%s' "$at" | grep -oE '(am|pm)$')"
    if [ -n "$mm$ap" ] && [ "$((10#$hh))" -le 23 ]; then
      h=$((10#$hh)); m=$((10#${mm:-0}))
      [ "$ap" = pm ] && [ "$h" -lt 12 ] && h=$((h + 12)); [ "$ap" = am ] && [ "$h" -eq 12 ] && h=0
      d=$(( (h * 60 + m - nh * 60 - nm + 1440) % 1440 )); [ "$d" -eq 0 ] && d=1
      echo "$((now - ns + d * 60)) 0"; return
    fi
  fi
  echo "$((now + LIMIT_DEFAULT_MIN * 60)) 1"
}

# 넘기지 않고 진행 중인 에이전트가 이번 단계만 대신 한다 (역할 배정·지침은 그대로)
fallback_msg() {  # <역할> <에이전트> <역할 파일> <사유>
  [ -f "$CUR" ] && kv_set "$CUR" proxy "$1"
  echo "[$1] $2 $4"
  echo "→ 넘기지 말고 내가(진행 중인 에이전트) 이 단계를 대신 한다. 사용자에게 묻지 않아도 된다"
  echo "  지침: $3 (역할 배정·지침은 바뀌지 않음. 이번 단계만 대신)"
  echo "  끝나면 'hn.sh done $1 \"<한 줄 결과>\"'. $2 한도가 풀린 뒤의 단계는 다시 $2 에게 넘긴다"
}

cmd_limits() {
  if [ "${1:-}" = clear ]; then
    for a in ${2:-claude codex}; do [ -f "$LIMITS" ] && kv_set "$LIMITS" "$a" ""; done
    echo "한도 기록 지움: ${2:-claude codex} (다음 단계부터 다시 넘김)"; return 0
  fi
  [ -n "${1:-}" ] && die "사용: limits [clear [claude|codex]]"
  any=""
  for a in claude codex; do
    [ "$(limit_left "$a")" -gt 0 ] || continue
    echo "$a: 한도 중. $(hm_of "$(kv_get "$LIMITS" "$a")")부터 다시 넘겨 봄 (그 전까지는 진행 중인 에이전트가 대신)"; any=1
  done
  [ -n "$any" ] || echo "한도 걸린 에이전트 없음"
}
cmd_delegate() {
  [ -z "${HN_DELEGATED:-}" ] || die "위임받은 작업 안에서는 다시 넘길 수 없습니다(재위임 금지). 맡은 역할만 하세요"
  [ $# -ge 2 ] || die "사용: delegate <역할> \"<이번 목표>\""
  role="$1"; goal="$2"; need_roles
  is_role "$role" || die "없는 역할: $role"
  agent="$(agent_of "$role")"; [ "$agent" != none ] || die "$role 은 배정 안 됨 → skip 하세요"
  rf="$(role_file "$role")"; [ -n "$rf" ] || die "역할 파일 없음: docs/roles/*-$role.md"
  perm="$(perm_of "$role")"
  if [ "$(limit_left "$agent")" -gt 0 ]; then
    fallback_msg "$role" "$agent" "$rf" "한도 중 ($(hm_of "$(kv_get "$LIMITS" "$agent")")부터 다시 넘겨 봄. 지금은 넘기지 않음)"
    return 0
  fi
  mkdir -p "$STATE/results"
  n=$(ls "$STATE"/results/*.md 2>/dev/null | wc -l | tr -d ' '); n=$((n+1))
  out="$STATE/results/$(printf '%02d' "$n")-$role-$agent.md"; errlog="$STATE/results/.last-$agent.log"
  prev="$(ls "$STATE"/results/*.md 2>/dev/null | tail -1)"

  {
    echo "<hn-delegated>"
    echo "너는 이 프로젝트에서 '$role' 역할로 호출되었다. 먼저 $rf 지침을 읽고 그대로 따른다."
    [ -f "$CUR" ] && echo "사용자 요청 원문 요약: $(kv_get "$CUR" request)"
    echo "이번 목표: $goal"
    echo "권한: $perm"
    if [ -f "$LOG" ]; then echo; echo "지금까지 단계 기록:"; cat "$LOG"; fi
    if [ -n "$prev" ]; then echo; echo "바로 앞 위임 결과($(basename "$prev")):"; head -c "$RESULT_INLINE" "$prev"; echo; fi
    echo
    echo "규칙:"
    echo "- 맡은 역할만 하고 끝낸다. 다른 에이전트를 부르거나 .harness/bin/hn.sh 를 실행하지 않는다"
    echo "- 커밋·푸시하지 않는다. 실행하지 않은 명령의 결과를 지어내지 않는다"
    echo "- 변경 내용은 git status / git diff 로 확인한다"
    if [ "$perm" != edit+exec ]; then
      echo "- 빌드·테스트·앱 실행은 하지 않는다(이 역할 권한 밖). 확인에 필요한 명령은 결과에 '돌릴 명령: <명령> (실행 안 함)'으로 적는다. 실행은 진행 중인 에이전트가 한다"
    fi
    [ "$role" = reviewer ] && echo "- 첫 줄에 반드시 '결과: 문제 없음' 또는 '결과: 문제 있음' 중 하나를 쓴다"
    echo "- 마지막 답은 역할 파일의 출력 형식대로 짧게 쓴다"
    echo "</hn-delegated>"
  } > "$STATE/results/.prompt.txt"

  echo "[$role] $agent 에게 넘기는 중... (몇 분 걸릴 수 있음)" >&2
  case "$agent" in
    codex)
      command -v codex >/dev/null 2>&1 || die "codex CLI를 찾을 수 없습니다"
      if [ "$(codex_sandbox)" = full ]; then sb=danger-full-access
      else case "$perm" in read-only) sb=read-only ;; *) sb=workspace-write ;; esac; fi
      HN_DELEGATED=1 codex exec -s "$sb" --skip-git-repo-check -C "$ROOT" -o "$out" - \
        < "$STATE/results/.prompt.txt" > "$errlog" 2>&1
      rc=$? ;;
    claude)
      command -v claude >/dev/null 2>&1 || die "claude CLI를 찾을 수 없습니다"
      ro='Read,Grep,Glob,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*)'
      deny='Bash(git commit:*),Bash(git push:*),Bash(git reset:*),Bash(rm -rf:*)'
      case "$perm" in
        read-only) set -- --allowedTools "$ro" --disallowedTools "Edit,Write,$deny" ;;
        edit)      set -- --permission-mode acceptEdits --allowedTools "$ro,Edit,Write" --disallowedTools "$deny" ;;
        *)         set -- --permission-mode acceptEdits --allowedTools "$ro,Edit,Write,Bash" --disallowedTools "$deny" ;;
      esac
      (cd "$ROOT" && HN_DELEGATED=1 claude -p --output-format text "$@" \
        < "$STATE/results/.prompt.txt" > "$out" 2> "$errlog")
      rc=$? ;;
    *) die "알 수 없는 담당: $agent" ;;
  esac

  # 한도 초과인지 본다 (위 LIMIT_RE 설명 참고)
  chk="$STATE/results/.last-check.txt"; osz=0
  [ -f "$out" ] && osz="$(wc -c < "$out" | tr -d ' ')"
  if [ "$rc" -ne 0 ] || [ "$osz" -eq 0 ]; then
    { tail -n 40 "$errlog" 2>/dev/null; [ -f "$out" ] && cat "$out"; } > "$chk"; re="$LIMIT_RE"
  elif [ "$osz" -lt 600 ]; then cp "$out" "$chk"; re="$LIMIT_RE_OK"
  else : > "$chk"; re='$^'
  fi
  if grep -qiE "$re" "$chk"; then
    set -- $(limit_until "$chk"); reset_at="$1"; guessed="$2"
    kv_set "$LIMITS" "$agent" "$reset_at"
    cat "$out" >> "$errlog" 2>/dev/null; rm -f "$out"   # 한도 메시지를 다음 단계의 '앞 결과'로 넘기지 않게
    if [ "$guessed" = 1 ]; then why="한도 초과 (풀리는 시각을 못 읽어 ${LIMIT_DEFAULT_MIN}분 뒤 $(hm_of "$reset_at")부터 다시 넘겨 봄)"
    else why="한도 초과 ($(hm_of "$reset_at")에 풀릴 예정)"; fi
    log "$role($agent) 한도 초과 → 진행 중인 에이전트가 대신 (다시 넘겨 볼 시각: $(hm_of "$reset_at"))"
    fallback_msg "$role" "$agent" "$rf" "$why. 로그: ${errlog#$ROOT/}"
    echo "  먼저 git status / git diff 로 $agent 가 하다 만 변경이 있는지 보고, 있으면 그걸 이어서 한다"
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
    echo "[$role] $agent 실행 실패(종료 코드 $rc). 로그: ${errlog#$ROOT/}"; tail -n 15 "$errlog" 2>/dev/null
    echo "→ 사용자에게 알리고, 'hn.sh skip $role \"실행 실패\"' 또는 다시 시도"
    return 1
  fi
  echo "[$role] $agent 결과 (${out#$ROOT/}):"
  head -c "$RESULT_INLINE" "$out"; echo
  [ "$perm" != edit+exec ] && echo "→ 넘겨받은 쪽은 빌드·테스트를 실행하지 않습니다. 결과의 '돌릴 명령'이 있으면 직접 실행해 확인하고 그 결과로 done 하세요"
  echo "→ 결과를 확인하고 'hn.sh done $role \"<한 줄 결과>\"'"
  [ "$role" = reviewer ] && grep -q '결과: *문제 있음' "$out" && echo "→ 문제 있음: done 대신 'hn.sh fix-round' (고치기 + 재검토)"
  return 0
}

# ---------- 훅 ----------
cmd_stop_hook() {
  input="$(cat 2>/dev/null || true)"
  [ -z "${HN_DELEGATED:-}" ] || exit 0
  [ -f "$CUR" ] || exit 0
  echo "$input" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && exit 0
  [ "$(kv_get "$CUR" wait)" = 1 ] && exit 0
  rest="$(remaining)"
  if [ -z "$rest" ]; then
    log "끝(자동)"; rm -f "$CUR"
    printf '{"systemMessage":"hn: 모든 단계 완료. 기록: .harness/state/log.md"}\n'
    exit 0
  fi
  echo "hn: 진행 중인 작업 [$(kv_get "$CUR" type)]에 남은 단계가 있습니다: $rest. 'bash .harness/bin/hn.sh next'로 이어서 진행하세요. 사용자에게 물어야 하면 'hn.sh wait' 후 질문하고, 사용자가 다른 이야기로 넘어갔으면 'hn.sh cancel'." >&2
  exit 2
}

# ---------- 세팅 ----------
# 설치 폴더의 최신 파일을 프로젝트에 맞춘다 (init·update 공통. 몇 번 실행해도 결과가 같다)
#   .harness/bin/              항상 최신으로
#   pipelines.conf, docs/roles 손대지 않은 파일만 최신으로, 직접 고친 파일은 그대로 두고 알림
#   CLAUDE.md / AGENTS.md      hn-commander 구역(<!-- hn-commander:start/end -->)만 최신으로
# '손대지 않음' = 예전에 hn-commander가 복사한 내용 그대로 (.harness/upstream.sums 또는 legacy.sums에 있는 값)
SUMS="$H/upstream.sums"
REGISTRY="$HN_HOME/projects.txt"
sum_of() { tr -d '\r' < "$1" | cksum | cut -d' ' -f1-2; }
is_pristine() { grep -qxF "$1 $2" "$SUMS" 2>/dev/null || grep -qxF "$1 $2" "$HN_HOME/harness/legacy.sums" 2>/dev/null; }

sync_file() {  # <설치 폴더 기준 경로> <프로젝트 파일>
  rel="$1"; src="$HN_HOME/$1"; dest="$2"; name="${dest#$ROOT/}"
  new="$(sum_of "$src")"
  if [ ! -f "$dest" ]; then cp "$src" "$dest"; echo "  추가     $name"
  else
    cur="$(sum_of "$dest")"
    if [ "$cur" = "$new" ]; then :
    elif is_pristine "$cur" "$rel"; then cp "$src" "$dest"; echo "  업데이트 $name"
    else echo "  그대로   $name  (직접 고친 파일. 새 버전: $src)"; KEPT=$((KEPT + 1)); return
    fi
  fi
  printf '%s %s\n' "$new" "$rel" >> "$SUMS"
}

sync_section() {  # <파일> <claude|codex>
  f="$ROOT/$1"; grep -q '<!-- hn-commander:start -->' "$f" 2>/dev/null || return 0
  sec="$STATE/.section.$$"; out="$STATE/.out.$$"
  cmd_section "$2" > "$sec"
  tr -d '\r' < "$f" | awk -v sec="$sec" '
    /<!-- hn-commander:start -->/ { while ((getline l < sec) > 0) print l; skip = 1; next }
    /<!-- hn-commander:end -->/   { if (skip) { skip = 0; next } }
    !skip { print }' > "$out"
  if [ "$(tr -cd '\r' < "$f" | wc -c)" -gt 0 ]; then sed 's/$/\r/' "$out" > "$out.crlf" && mv "$out.crlf" "$out"; fi  # 줄바꿈 방식 유지
  if cmp -s "$f" "$out"; then rm -f "$out"; else mv "$out" "$f"; echo "  업데이트 $1 (hn-commander 구역)"; fi
  rm -f "$sec"
}

register() {
  p="$(cd "$ROOT" && pwd)"
  grep -qxF "$p" "$REGISTRY" 2>/dev/null || printf '%s\n' "$p" >> "$REGISTRY"
}

cmd_init() {
  [ -d "$HN_HOME/harness" ] || die "설치 폴더가 없습니다: $HN_HOME (설치 스크립트를 먼저 실행)"
  ver="$(cat "$HN_HOME/VERSION")"; old="$(cat "$H/VERSION" 2>/dev/null)"
  mkdir -p "$H/bin" "$STATE" "$ROOT/docs/roles"
  KEPT=0
  cp "$HN_HOME/harness/bin/"* "$H/bin/"
  sync_file harness/pipelines.conf "$PIPES_FILE"
  for f in "$HN_HOME"/roles/*.md; do b="$(basename "$f")"; sync_file "roles/$b" "$ROOT/docs/roles/$b"; done
  sync_section CLAUDE.md claude
  sync_section AGENTS.md codex
  [ -f "$SUMS" ] && sort -u "$SUMS" -o "$SUMS"
  gi="$ROOT/.gitignore"; grep -qxF '.harness/state/' "$gi" 2>/dev/null || printf '.harness/state/\n' >> "$gi"
  echo "$ver" > "$H/VERSION"
  register
  if [ -z "$old" ]; then echo "hn-commander $ver 적용: $(cd "$ROOT" && pwd)"
  elif [ "$old" = "$ver" ]; then echo "hn-commander $ver (최신): $(cd "$ROOT" && pwd)"
  else echo "hn-commander $old → $ver: $(cd "$ROOT" && pwd)"; fi
  [ "$KEPT" -gt 0 ] && echo "  직접 고친 파일 ${KEPT}개는 그대로 뒀습니다. 새 버전을 쓰려면 그 파일을 지우고 다시 업데이트하세요"
  return 0
}

# 등록된 모든 프로젝트 + 지금 폴더의 프로젝트를 업데이트 (설치 스크립트가 끝에서 호출)
cmd_update_all() {
  list="$(mktemp)"
  { cat "$REGISTRY" 2>/dev/null; [ -f "$H/bin/hn.sh" ] && (cd "$ROOT" && pwd); } | awk 'NF && !seen[$0]++' > "$list"
  : > "$REGISTRY.tmp"; n=0
  while IFS= read -r p; do
    [ -f "$p/.harness/bin/hn.sh" ] || continue
    printf '%s\n' "$p" >> "$REGISTRY.tmp"; n=$((n + 1))
    (cd "$p" && bash "$HN_HOME/harness/bin/hn.sh" init) || echo "  실패: $p"
  done < "$list"
  mv "$REGISTRY.tmp" "$REGISTRY"; rm -f "$list"
  [ "$n" -eq 0 ] && echo "업데이트할 프로젝트 없음 (세팅한 프로젝트 폴더에서 설치 명령을 실행하면 그 프로젝트도 함께 업데이트됩니다)"
  return 0
}

cmd_hooks() {
  c="$ROOT/.claude/settings.json"; x="$ROOT/.codex/hooks.json"
  claude_hook='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.harness/bin/hn.sh\" stop-hook","timeout":30}]}]}}'
  codex_hook='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash .harness/bin/hn.sh stop-hook","commandWindows":".harness\\bin\\hn.cmd stop-hook","timeout":30}]}]}}'
  for pair in "$c|$claude_hook" "$x|$codex_hook"; do
    f="${pair%%|*}"; j="${pair#*|}"
    if [ -f "$f" ]; then
      if grep -q 'hn.sh' "$f"; then echo "이미 등록됨: ${f#$ROOT/}"
      else echo "합치기 필요: ${f#$ROOT/} 에 아래 Stop 훅을 기존 설정을 유지한 채 추가하세요:"; echo "$j"; fi
    else mkdir -p "$(dirname "$f")"; echo "$j" > "$f"; echo "만듦: ${f#$ROOT/}"; fi
  done
  echo "Codex 훅은 처음 한 번 Codex에서 /hooks 로 신뢰(trust)해야 동작합니다."
}

# ---------- 답변 언어 (사용자 전체 설정: 모든 프로젝트에 적용) ----------
#   Claude Code: ~/.claude/settings.json 의 "language"
#   Codex      : ~/.codex/AGENTS.md 의 hn-commander:lang 구역 (Codex에는 언어 설정이 없음)
lang_info() {  # <코드> → "<코드> <Claude 값> <영어 이름> <한국어 이름>"
  # 코드|Claude 값|영어 이름|그 언어로 쓴 이름|질문 제목|1번 선택지|2번 선택지|2번 코드  (질문은 감지된 언어로 쓴다)
  case "$1" in
    ko) echo "ko|korean|Korean|한국어|언어 설정|한국어(감지됨)|영어|en" ;;
    ja) echo "ja|japanese|Japanese|日本語|言語設定|日本語(検出)|英語|en" ;;
    zh) echo "zh|chinese|Chinese|中文|语言设置|中文(已检测)|英语|en" ;;
    es) echo "es|spanish|Spanish|Español|Idioma|Español (detectado)|Inglés|en" ;;
    fr) echo "fr|french|French|Français|Langue|Français (détecté)|Anglais|en" ;;
    de) echo "de|german|German|Deutsch|Sprache|Deutsch (erkannt)|Englisch|en" ;;
    pt) echo "pt|portuguese|Portuguese|Português|Idioma|Português (detectado)|Inglês|en" ;;
    *)  echo "en|english|English|English|Language|English (detected)|한국어 (Korean)|ko" ;;
  esac
}

cmd_lang_detect() {  # 컴퓨터의 표시 언어 (위치가 아니라 OS 언어 설정 기준) → 질문에 그대로 쓸 문구
  l=""
  if command -v powershell.exe >/dev/null 2>&1; then l="$(powershell.exe -NoProfile -Command '(Get-UICulture).Name' 2>/dev/null | tr -d '\r')"
  elif command -v defaults >/dev/null 2>&1; then l="$(defaults read -g AppleLanguages 2>/dev/null | sed -n 's/^[[:space:]]*"\{0,1\}\([A-Za-z-]*\).*/\1/p' | grep . | head -1)"
  fi
  [ -n "$l" ] || l="${LC_ALL:-${LANG:-en}}"
  d="$(printf '%s' "$l" | cut -c1-2 | tr 'A-Z' 'a-z')"
  IFS='|' read -r code _ _ _ title opt1 opt2 code2 <<EOF
$(lang_info "$d")
EOF
  [ "$code" = "$d" ] || opt1="English"   # 지원하지 않는 언어: 영어로 묻되 '감지됨'은 붙이지 않음
  printf 'question=%s\n1=%s → hn lang %s\n2=%s → hn lang %s\n' "$title" "$opt1" "$code" "$opt2" "$code2"
}

cmd_lang() {
  case "${1:-}" in ko|en|ja|zh|es|fr|de|pt) ;; *) die "사용: lang <ko|en|ja|zh|es|fr|de|pt>" ;; esac
  IFS='|' read -r _ val eng kor _ <<EOF
$(lang_info "$1")
EOF
  # Claude Code: "language" 한 줄만 넣거나 바꾼다 (다른 설정은 그대로)
  c="$HOME/.claude/settings.json"; t="$c.tmp.$$"; mkdir -p "$HOME/.claude"
  if [ ! -s "$c" ] || [ "$(tr -d ' \t\r\n' < "$c")" = "{}" ]; then printf '{\n  "language": "%s"\n}\n' "$val" > "$c"
  elif grep -q '"language"[[:space:]]*:' "$c"; then
    sed "s/\"language\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"language\": \"$val\"/" "$c" > "$t" && mv "$t" "$c"
  else
    awk -v v="$val" '!d && /\{/ { sub(/\{/, "{\n  \"language\": \"" v "\","); d = 1 } { print }' "$c" > "$t" && mv "$t" "$c"
  fi
  echo "Claude Code: ~/.claude/settings.json → \"language\": \"$val\""
  # Codex: 전역 지침 파일에 표시된 구역만 바꾼다
  x="${CODEX_HOME:-$HOME/.codex}/AGENTS.md"; mkdir -p "$(dirname "$x")"; touch "$x"
  awk '/<!-- hn-commander:lang -->/ { skip = 1; next } /<!-- hn-commander:lang-end -->/ { skip = 0; next } !skip { print }' "$x" > "$x.tmp.$$"
  { cat "$x.tmp.$$"; [ -s "$x.tmp.$$" ] && echo
    echo "<!-- hn-commander:lang -->"
    echo "Always write replies and reports to the user in $eng."
    echo "<!-- hn-commander:lang-end -->"; } | awk 'NF || prev_nf { print } { prev_nf = NF }' > "$x"
  rm -f "$x.tmp.$$"
  echo "Codex      : ${x/#$HOME/~} → $eng"
  echo "답변 언어: $kor (모든 프로젝트에 적용. Claude Code / Codex를 다시 켜면 반영)"
}

cmd_section() {
  me="${1:-}"; case "$me" in claude|codex) ;; *) die "사용: section <claude|codex>" ;; esac
  sed "s/{{ME}}/$me/g" "$HN_HOME/harness/agent-section.md"
}

# 아래 전체를 { …; exit; } 한 덩어리로 둔다: bash는 스크립트를 실행하면서 조금씩 읽으므로,
# delegate가 몇 분 도는 사이 업데이트로 이 파일이 바뀌면 끝난 뒤 바뀐 파일의 엉뚱한 위치를 읽어 문법 오류가 난다.
# 한 덩어리는 실행 전에 다 읽고, 끝에서 exit 하므로 그 뒤를 더 읽지 않는다.
{
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  roles) cmd_roles ;;
  role-set) cmd_role_set "$@" ;;
  preset) cmd_preset "$@" ;;
  codex-sandbox) cmd_codex_sandbox "$@" ;;
  on)  need_roles; kv_set "$ROLES_FILE" enabled 1; echo "하네스 켜짐" ;;
  off) need_roles; kv_set "$ROLES_FILE" enabled 0; echo "하네스 꺼짐 (배정은 남아 있음. 'on'으로 다시 켬)" ;;
  start) cmd_start "$@" ;;
  next) cmd_next ;;
  done) cmd_done "$@" ;;
  skip) cmd_skip "$@" ;;
  delegate) cmd_delegate "$@" ;;
  limits) cmd_limits "$@" ;;
  fix-round) cmd_fix_round ;;
  wait) cmd_wait ;;
  cancel) cmd_cancel ;;
  status) cmd_status ;;
  finish) cmd_finish ;;
  stop-hook) cmd_stop_hook ;;
  init|update) cmd_init ;;
  update-all) cmd_update_all ;;
  lang-detect) cmd_lang_detect ;;
  lang) cmd_lang "$@" ;;
  hooks) cmd_hooks ;;
  section) cmd_section "$@" ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; [ -n "$cmd" ] && exit 1 ;;
esac
exit
}
