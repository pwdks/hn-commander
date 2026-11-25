# 에이전트 넘기기 (Claude ↔ Codex)

역할마다 맡을 에이전트를 정해 두면, 요청 종류에 맞는 역할만 순서대로 움직이고 담당이 다른 에이전트면 자동으로 그 CLI를 불러 맡긴다.

## 1. 원칙
- **배정은 한 파일에만**: `.harness/roles.conf` (`tester=codex` 형식). 지침 파일·역할 파일에는 누가 맡는지 적지 않는다 → 배정을 바꿔도 다른 파일은 그대로
- **진행은 사용자와 대화하는 에이전트가**: Claude에게 말하면 Claude가, Codex에게 말하면 Codex가 단계를 진행한다. 자기 담당은 직접, 다른 담당은 넘긴다
- **질문에는 답만**: 파일을 바꾸라는 요청이 분명할 때만 단계를 시작한다
- **판단은 스크립트가 돕는다**: 지금 단계·담당·남은 단계는 `hn.sh`가 기록하고 알려 준다. 모델이 기억에 의존하지 않는다

## 2. 요청 종류와 단계 (`.harness/pipelines.conf`)
| 종류 | 머리말 | 단계 |
|---|---|---|
| question | `[질문]` | 없음 (답만) |
| feature | `[개발]` | architect → developer → tester → reviewer → documenter |
| change | `[수정]` | developer → tester → reviewer |
| bug | `[버그]` | debugger → tester → reviewer |
| perf | `[성능]` | optimizer → tester → reviewer |
| test | `[테스트]` | tester |
| review | `[검토]` | reviewer |
| docs | `[문서]` | documenter |
| large | `[대형]` | orchestrator → architect → developer → integrator → tester → reviewer → documenter |

- 배정 안 된 역할은 시작할 때 빠진다
- reviewer가 "문제 있음" → 고치기(debugger, 없으면 developer) + 재검토를 **1회까지** 끼워 넣는다
- 단계를 바꾸고 싶으면 이 파일만 고친다

## 3. 넘기기 (`hn.sh delegate <역할> "<목표>"`)
- 다른 에이전트를 대화 없이 한 번 실행한다: Codex는 `codex exec`, Claude는 `claude -p`
- 넘기는 것: 역할 파일 경로, 요청 요약, 이번 목표, 지금까지 단계 기록, 바로 앞 결과 (전체 대화는 넘기지 않음)
- 권한은 역할에 맞게:

| 권한 | 역할 | Codex | Claude |
|---|---|---|---|
| 읽기 전용 | orchestrator, architect, reviewer | `-s read-only` | 읽기·git 조회만 허용 |
| 수정 | developer, tester, documenter | `-s workspace-write` | + 파일 수정 |
| 수정+실행 | debugger, integrator, optimizer | `-s workspace-write` | + 명령 실행 |

- 읽기 전용·수정 역할은 넘겨받았을 때 빌드·테스트를 실행하지 않고 "돌릴 명령"만 적는다. 실행은 진행 중인 에이전트가 결과를 받은 뒤 한 번 한다 (샌드박스에 막혀 시간·토큰을 버리지 않도록)
- Codex 샌드박스는 Windows에서 빌드 도구(dotnet 파이프 등)나 셸 실행을 막을 수 있다. 수정+실행 역할을 Codex에 맡기고 빌드까지 시키려면 `hn.sh codex-sandbox full` (`-s danger-full-access`, 되돌리기는 `auto`). 이때 Codex 쪽은 커밋·푸시·삭제를 지시문으로만 막는다
- 넘겨받은 쪽은 커밋·푸시·재위임을 하지 않는다 (`HN_DELEGATED=1`로 막음)
- 결과는 `.harness/state/results/`에 남는다

### 넘겨받은 쪽이 한도에 걸렸을 때
- 실패 로그·짧은 결과에 한도 문구(usage limit, rate limit, 429 등)가 있으면 **한도 초과**로 보고, 진행 중인 에이전트에게 "이 단계를 대신 하라"고 알린다. 다른 이유의 실패는 지금처럼 사용자에게 묻는다
- 역할 배정(`roles.conf`)과 역할 지침은 **바뀌지 않는다**. 진행 중인 에이전트가 그 역할 지침을 읽고 이번 단계만 대신 한다. 단계 기록에는 `tester(codex 한도 → 대신)`처럼 남는다
- 풀리는 시각을 메시지에서 읽어 `.harness/state/limits.conf`에 적는다 ("try again in 2 hours", "resets 3pm", `|<epoch>` 형식). 읽지 못하면 15분 뒤
- 그 시각 전에는 delegate가 CLI를 부르지 않고 바로 대신 하라고 알린다 (실패할 시도로 시간을 버리지 않게). **시각이 지나면 원래 담당에게 다시 넘긴다** — 같은 작업 안의 다음 단계에서도
- 넘겨받은 쪽이 하다 만 변경이 있을 수 있으므로, 대신 하기 전에 `git status` / `git diff`부터 본다
- 진행 중인 에이전트 자신이 한도에 걸리면 대신 할 쪽이 없다. 상태는 남아 있으므로 나중에 `hn.sh status` / `next`로 이어 간다
- 기록 보기·지우기: `hn.sh limits`, `hn.sh limits clear [claude|codex]` (요금제를 올려 바로 풀렸을 때 등)

## 4. 빠뜨림 방지 (Stop 훅)
- 에이전트가 응답을 끝내려 할 때 남은 단계가 있으면 훅이 "남은 단계: …"를 돌려보내 이어서 진행시킨다 (한 번만)
- 사용자에게 물어야 할 때는 `hn.sh wait` 후 질문 → 훅이 재촉하지 않는다
- 진행 중인 작업이 없으면(질문만 한 경우) 훅은 아무것도 하지 않는다
- Claude: `.claude/settings.json`, Codex: `.codex/hooks.json` (Codex는 처음 한 번 `/hooks`에서 신뢰 필요)

## 5. 명령 요약
| 명령 | 하는 일 |
|---|---|
| `start <종류> "<요약>"` | 작업 시작, 단계와 담당 표시 |
| `next` | 다음 단계와 담당 |
| `done <역할> "<결과>"` / `skip <역할> "<이유>"` | 단계 끝 / 건너뜀 |
| `delegate <역할> "<목표>"` | 다른 에이전트에게 맡기고 결과 받기 |
| `limits [clear [claude\|codex]]` | 넘겨받는 에이전트의 한도 기록 보기 / 지우기 |
| `fix-round` | 검토 지적 → 고치기 + 재검토 |
| `wait` / `cancel` / `finish` / `status` | 대기 / 취소 / 끝내기 / 상태 |
| `roles` / `role-set` / `preset` / `on` / `off` | 배정 보기·바꾸기 |
| `codex-sandbox <auto\|full>` | 위임받은 Codex의 샌드박스 (기본 auto) |

Windows PowerShell·cmd에서는 `bash .harness/bin/hn.sh` 대신 `.harness\bin\hn.cmd`.
