---
name: hn-mod-role
description: 현재 프로젝트의 Claude/Codex 역할 배정을 바꾼다 (프리셋 다시 고르기, 역할 골라서 바꾸기, 끄기/켜기). 사용자가 /hn-mod-role 또는 $hn-mod-role 을 입력했을 때만 쓴다
---

# hn-mod-role

현재 프로젝트의 역할 배정(`.harness/roles.conf`)만 바꾼다. `CLAUDE.md`, `AGENTS.md`, 역할 파일은 건드리지 않는다(배정을 직접 적어 두지 않으므로 바꿀 필요 없음).

## 0. 준비
- hn 명령: bash 셸이면 `bash .harness/bin/hn.sh <명령>`, Windows PowerShell·cmd면 `.harness\bin\hn.cmd <명령>`
- 질문 방법은 hn-setup과 같다: 선택형 질문 도구가 있으면 쓰고, 없으면 번호 목록으로 묻고 답을 기다린다
- `.harness/roles.conf`가 없으면(세팅 때 배정 안 함, 또는 세팅 전):
  - `CLAUDE.md`/`AGENTS.md`도 없으면 "먼저 /hn-setup 을 실행하세요"라고 알리고 멈춘다
  - 있으면 "아직 역할 배정이 없습니다. 지금 배정할까요? 1) 예 2) 아니오" → 예면 `~/.hn-commander/skills/hn-setup/SKILL.md`의 **3·4단계**를 그대로 따른다(Q1은 건너뜀)

## 1. 현재 상태 보여주기
`hn roles` 표와 `hn status`(진행 중인 작업 여부)를 보여준다.

## 2. 무엇을 바꿀지 묻기
**무엇을 바꿀까요?**
1) 프리셋 다시 고르기 (claude 메인 + codex 서브 / codex 메인 + claude 서브)
2) 역할 골라서 바꾸기
3) 하네스 끄기 (배정은 남기고 역할 단계 없이 평소처럼 작업) — 이미 꺼져 있으면 "하네스 켜기"로 보인다

### 2) 역할 골라서 바꾸기
1. 바꿀 역할을 여러 개 고르게 한다. 선택형 도구는 질문 하나에 선택지 4개까지라, 질문 3개로 나눈다(복수 선택)
   - 묶음 1: orchestrator · architect · developer · debugger
   - 묶음 2: integrator · tester · reviewer · documenter
   - 묶음 3: optimizer
   - 번호 목록으로 물을 때는 9개를 한 번에 보이고 "바꿀 번호를 쉼표로" 받는다
2. 고른 역할마다 묻는다. 역할 설명과 지금 담당을 함께 보인다(설명은 hn-setup의 역할 표):
   ```
   Tester — 바뀐 동작을 확인하는 테스트를 추가합니다.
   지금: codex → 어떤 에이전트에게 맡길까요?  1) claude  2) codex  3) 배정 안 함
   ```

## 3. 확인 후 적용
1. 바꾸기 전/후 표를 보여주고 "이대로 적용할까요? 1) 예 2) 아니오"
2. `hn status`에 진행 중인 작업이 있으면: "진행 중인 작업이 있습니다. 1) 지금 적용 (남은 단계부터 새 담당) 2) 작업을 취소하고 적용 3) 그만두기"
3. 적용: 프리셋 `hn preset <claude|codex>` / 개별 `hn role-set <역할> <claude|codex|none>` / 끄기 `hn off` / 켜기 `hn on`
4. developer와 debugger가 둘 다 "배정 안 함"이 되면 hn-setup과 같이 한 번 더 확인한다
5. 새로 배정된 에이전트의 CLI가 설치돼 있는지 확인하고, 훅이 없으면 `hn hooks`
6. `docs/decisions.md`에 한 줄: `| Dn | 역할 배정 변경 | <무엇을 무엇에서 무엇으로> | /hn-mod-role |`
7. 바뀐 `hn roles` 표를 보여주고 "다음 요청부터 적용됩니다"라고 알린다
