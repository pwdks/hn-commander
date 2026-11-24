#!/usr/bin/env bash
# hn-commander: 역할 배정·작업 단계·에이전트 넘기기 (Windows Git Bash / macOS bash 3.2 호환)
# 사용: bash .harness/bin/hn.sh <명령> [인자]
#   roles                       현재 역할 배정 표
#   role-set <역할> <claude|codex|none>
#   preset <claude|codex>       메인/서브 프리셋 적용
#   on | off                    하네스 켜기/끄기
#   start <종류> "<요청 요약>"   작업 시작 (종류: .harness/pipelines.conf)
#   next                        다음 단계와 담당
#   done <역할> "<한 줄 결과>"   단계 완료
#   skip <역할> "<이유>"         단계 건너뜀
#   delegate <역할> "<목표>"     다른 에이전트에게 맡기고 결과를 받음
#   fix-round                   검토 지적 → 고치기 + 다시 검토 (1회까지)
#   wait                        사용자에게 묻기 전에 (훅이 재촉하지 않음)
#   cancel | finish | status
#   stop-hook                   Claude/Codex Stop 훅에서 호출
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

need_roles() { [ -f "$ROLES_FILE" ] || die "역할 배정이 없습니다. /hn-setup 또는 /hn-mod-role로 먼저 배정하세요"; }

# ---------- 역할 배정 ----------
cmd_roles() {
  need_roles
  if enabled; then echo "하네스: 켜짐"; else echo "하네스: 꺼짐"; fi
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
  fi
}

advance() { # $1 역할, $2 상태, $3 메모
  [ -f "$CUR" ] || die "진행 중인 작업 없음"
  clear_wait
  p="$(pos_of)"; s="$(step_at "$p")"
  [ -n "$s" ] || die "남은 단계가 없습니다. finish 하세요"
  [ "$s" = "$1" ] || die "지금 단계는 '$s'입니다 ('$1' 아님)"
  kv_set "$CUR" pos $((p+1))
  log "$1($(agent_of "$1")) $2: ${3:-}"
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
cmd_delegate() {
  [ -z "${HN_DELEGATED:-}" ] || die "위임받은 작업 안에서는 다시 넘길 수 없습니다(재위임 금지). 맡은 역할만 하세요"
  [ $# -ge 2 ] || die "사용: delegate <역할> \"<이번 목표>\""
  role="$1"; goal="$2"; need_roles
  is_role "$role" || die "없는 역할: $role"
  agent="$(agent_of "$role")"; [ "$agent" != none ] || die "$role 은 배정 안 됨 → skip 하세요"
  rf="$(role_file "$role")"; [ -n "$rf" ] || die "역할 파일 없음: docs/roles/*-$role.md"
  perm="$(perm_of "$role")"
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
    [ "$role" = reviewer ] && echo "- 첫 줄에 반드시 '결과: 문제 없음' 또는 '결과: 문제 있음' 중 하나를 쓴다"
    echo "- 마지막 답은 역할 파일의 출력 형식대로 짧게 쓴다"
    echo "</hn-delegated>"
  } > "$STATE/results/.prompt.txt"

  echo "[$role] $agent 에게 넘기는 중... (몇 분 걸릴 수 있음)" >&2
  case "$agent" in
    codex)
      command -v codex >/dev/null 2>&1 || die "codex CLI를 찾을 수 없습니다"
      case "$perm" in read-only) sb=read-only ;; *) sb=workspace-write ;; esac
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

  if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
    echo "[$role] $agent 실행 실패(종료 코드 $rc). 로그: ${errlog#$ROOT/}"; tail -n 15 "$errlog" 2>/dev/null
    echo "→ 사용자에게 알리고, 'hn.sh skip $role \"실행 실패\"' 또는 다시 시도"
    return 1
  fi
  echo "[$role] $agent 결과 (${out#$ROOT/}):"
  head -c "$RESULT_INLINE" "$out"; echo
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
cmd_init() {
  [ -d "$HN_HOME/harness" ] || die "설치 폴더가 없습니다: $HN_HOME (설치 스크립트를 먼저 실행)"
  mkdir -p "$H/bin" "$ROOT/docs/roles"
  cp "$HN_HOME/harness/bin/"* "$H/bin/"
  [ -f "$PIPES_FILE" ] || cp "$HN_HOME/harness/pipelines.conf" "$PIPES_FILE"
  for f in "$HN_HOME"/roles/*.md; do b="$(basename "$f")"; [ -f "$ROOT/docs/roles/$b" ] || cp "$f" "$ROOT/docs/roles/$b"; done
  gi="$ROOT/.gitignore"; grep -qxF '.harness/state/' "$gi" 2>/dev/null || printf '.harness/state/\n' >> "$gi"
  echo "복사 완료: .harness/bin, .harness/pipelines.conf, docs/roles/, .gitignore(.harness/state/)"
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

cmd_section() {
  me="${1:-}"; case "$me" in claude|codex) ;; *) die "사용: section <claude|codex>" ;; esac
  sed "s/{{ME}}/$me/g" "$HN_HOME/harness/agent-section.md"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  roles) cmd_roles ;;
  role-set) cmd_role_set "$@" ;;
  preset) cmd_preset "$@" ;;
  on)  need_roles; kv_set "$ROLES_FILE" enabled 1; echo "하네스 켜짐" ;;
  off) need_roles; kv_set "$ROLES_FILE" enabled 0; echo "하네스 꺼짐 (배정은 남아 있음. 'on'으로 다시 켬)" ;;
  start) cmd_start "$@" ;;
  next) cmd_next ;;
  done) cmd_done "$@" ;;
  skip) cmd_skip "$@" ;;
  delegate) cmd_delegate "$@" ;;
  fix-round) cmd_fix_round ;;
  wait) cmd_wait ;;
  cancel) cmd_cancel ;;
  status) cmd_status ;;
  finish) cmd_finish ;;
  stop-hook) cmd_stop_hook ;;
  init) cmd_init ;;
  hooks) cmd_hooks ;;
  section) cmd_section "$@" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; [ -n "$cmd" ] && exit 1 ;;
esac
