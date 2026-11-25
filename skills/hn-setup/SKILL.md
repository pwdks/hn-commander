---
name: hn-setup
description: 현재 프로젝트에 하네스를 세팅한다 (CLAUDE.md·AGENTS.md·기록 문서·역할 파일, 원하면 Claude/Codex 역할 배정과 자동 넘기기). 사용자가 /hn-setup 또는 $hn-setup 을 입력했을 때만 쓴다
---

# hn-setup

현재 작업 폴더(프로젝트 루트)에 하네스를 세팅한다. 사용자가 명시적으로 요청했을 때만 실행한다.

## 0. 준비
- 설치 폴더 `HN`: `~/.hn-commander` (Windows: `%USERPROFILE%\.hn-commander`). 없으면 "설치 스크립트를 먼저 실행하세요"라고 알리고 멈춘다
- hn 명령 실행 방법:
  - bash가 있는 셸(macOS, Claude Code의 Bash): `bash "$HOME/.hn-commander/harness/bin/hn.sh" <명령>`
  - bash가 없는 셸(Windows PowerShell·cmd, 예: Codex on Windows): `& "$env:USERPROFILE\.hn-commander\harness\bin\hn.cmd" <명령>`
  - 세팅 뒤에는 프로젝트 안의 `.harness/bin/hn.sh` / `.harness\bin\hn.cmd`를 쓴다
  - 아래의 `hn <명령>`은 이 실행 방법을 줄여 쓴 것이다
- 나는 지금 이 스킬을 실행하는 에이전트다: Claude Code면 `claude`, Codex면 `codex`

## 질문하는 방법
- 선택형 질문 도구(예: Claude Code의 AskUserQuestion)가 있으면 그것으로 묻는다
- 없으면(예: Codex) 번호 목록으로 묻고 **사용자의 답을 기다린다.** 답을 받기 전에 다음 단계로 가지 않는다
  ```
  역할 배정이 필요한가요?
  1) 예  2) 아니오
  번호로 답해 주세요.
  ```

## 0-1. 언어 설정 (가장 먼저 묻는다)
1. `hn lang-detect` → 컴퓨터의 표시 언어. 예: `ko korean Korean 한국어` (코드 · Claude 값 · 영어 이름 · 한국어 이름)
2. 묻는다. 감지된 언어가 1번, 영어가 2번 (감지된 언어가 영어면 1) 영어(감지됨) 2) 한국어)
   ```
   언어 설정
   1) 한국어(감지됨)  2) 영어
   ```
3. 고른 언어로 `hn lang <코드>` (예: `hn lang ko`, `hn lang en`). Claude Code와 Codex의 사용자 전체 설정이라 모든 프로젝트에 적용된다
4. 이 뒤의 질문과 보고는 고른 언어로 한다

## 1. 기준 문서 읽기
`HN/guides/` 의 `01-harness-engineering.md`, `02-token-efficiency.md`, `03-templates.md`, `04-agent-handoff.md`를 읽고 이 원칙대로 세팅한다. 역할 파일(`HN/roles/`)은 이름과 첫 줄 설명만 본다.

## 2. 기본 세팅
1. 프로젝트를 grep/glob으로 좁게 살펴 스택, 주요 폴더, 설치·전체 테스트·파일 하나 테스트·타입 검사·린트·실행 명령을 찾는다. 못 찾은 것은 `<확인 필요>`
2. `CLAUDE.md`와 `AGENTS.md`를 `03-templates.md`의 A 틀로 만든다 (두 파일 내용은 같게. 토큰 절약 줄은 `02`의 복사용 블록)
3. `docs/progress.md`, `docs/decisions.md`를 B·C 틀로 만든다
4. `docs/roles/`에 `HN/roles/*.md`를 복사한다 (이미 있는 파일은 두기)
- **이미 있는 파일은 덮어쓰지 않는다.** 빠진 부분만 추가하고, 무엇을 추가할지 먼저 보여주고 승인받는다
- 커밋하지 않는다

## 3. 역할 배정 질문
**Q1. 역할 배정이 필요한가요?** 1) 예 2) 아니오
- 아니오 → 2단계까지로 끝. 5단계 보고로 간다

**Q2. 배정 방식** 1) claude 메인 + codex 서브 2) codex 메인 + claude 서브 3) 직접 배정
- 메인: orchestrator(지휘) · architect · developer · debugger · integrator
- 서브: tester · reviewer · documenter · optimizer

**Q3. (직접 배정일 때만) 역할마다** — 질문에 역할 설명을 함께 보인다. 선택지: 1) claude 2) codex 3) 배정 안 함
선택형 도구는 한 번에 질문 4개까지이므로 3번에 나눠 묻는다(4·4·1).

| 역할 | 설명 (질문에 그대로 보임) |
|---|---|
| orchestrator (지휘) | 여러 모듈에 걸친 큰 요청을 역할별 작업으로 나눠 계획을 세웁니다. 파일은 고치지 않습니다 |
| architect (설계) | 코드를 고치기 전에 바꿀 파일과 방법을 3~7개 요점으로 정리합니다 |
| developer (구현) | 설계에 맞춰 필요한 최소 범위만 구현합니다 |
| tester (테스트) | 바뀐 동작을 확인하는 테스트를 추가합니다. 경계 조건과 실패 경로 포함 |
| reviewer (검토) | 변경을 다시 읽고 버그·보안 문제·빠진 처리를 찾습니다. 파일은 고치지 않습니다 |
| debugger (디버깅) | 오류를 재현하고 원인을 찾아 최소한으로 고칩니다. 검토 지적을 고칠 때도 씁니다 |
| integrator (통합) | 여러 작업이 나눠 고친 내용이 서로 맞물리는지 확인하고 어긋난 곳만 고칩니다 |
| optimizer (최적화) | 측정 근거가 있을 때만 성능을 개선하고 전후 수치를 남깁니다 |
| documenter (문서) | 사용법·설정이 바뀌면 문서를 짧게 갱신합니다. 필요 없으면 건너뜁니다 |

- developer와 debugger가 둘 다 "배정 안 함"이면: "구현·수정 단계가 모두 건너뛰어집니다. 괜찮을까요?"라고 확인한다

## 4. 역할 배정 적용 (Q1이 예일 때)
1. `hn init` → `.harness/`(스크립트, pipelines.conf), `docs/roles/`, `.gitignore`(`.harness/state/`) 준비. 이 프로젝트가 업데이트 목록에 등록되어, 이후 설치 명령을 다시 실행하면 함께 업데이트된다
2. 프리셋이면 `hn preset claude` 또는 `hn preset codex`, 직접 배정이면 역할마다 `hn role-set <역할> <claude|codex|none>`
3. `hn section claude` 출력을 `CLAUDE.md` 끝에, `hn section codex` 출력을 `AGENTS.md` 끝에 붙인다 (`<!-- hn-commander:start -->` 구역이 이미 있으면 그 구역만 바꾼다)
4. `hn hooks` → Claude Stop 훅(`.claude/settings.json`), Codex Stop 훅(`.codex/hooks.json`) 등록. "합치기 필요"가 나오면 기존 설정을 유지한 채 Stop 훅만 추가한다
5. 배정에 쓰인 CLI가 설치돼 있는지 `claude --version` / `codex --version`으로 확인하고, 없으면 알린다
6. `docs/decisions.md`에 한 줄: `| Dn | 역할 배정 | <프리셋 또는 직접: 요약> | /hn-setup |`
7. `hn roles` 표를 보여준다

## 5. 보고 (짧게)
- 만든/고친 파일 목록, `<확인 필요>`로 남긴 항목
- 답변 언어: "<언어> (Claude Code / Codex를 다시 켜면 반영)"
- 역할 배정을 했으면 사용법 세 줄:
  - 평소처럼 요청하면 요청 종류에 맞는 역할만 움직입니다. 질문에는 답만 합니다
  - 확실히 하려면 `[질문]` `[개발]` `[버그]` 같은 머리말을 붙이세요
  - 배정 변경: `/hn-mod-role` (Codex: `$hn-mod-role`)
- Codex 훅을 처음 쓰면: "Codex에서 한 번 `/hooks`를 열어 이 프로젝트의 Stop 훅을 신뢰(trust)해 주세요"
