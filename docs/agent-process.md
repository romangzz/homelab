# Autonomous agent development process

How a software project goes from specification to delivered code with local
agents running unattended on the homelab. Humans own **specification,
refinement and sprint review**; agents own the **development cycle**
(understand → implement → review → deliver) one task at a time.

> Status: **process defined, infrastructure not yet deployed.** Planned
> components: `apps/plane/` and `apps/agent-worker/` (see
> [Components](#components)).

## Principles

1. **Humans decide what, agents decide how.** Scope and acceptance criteria are
   fixed before a task reaches an agent. An agent never guesses past an
   ambiguous requirement; it blocks.
2. **WIP = 1.** Ollama serves one model and one request at a time
   (`OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`), so the cycle is
   strictly sequential. Each task starts from code that already contains the
   previous one.
3. **Machines gate correctness, humans gate quality.** Tests, lint and CI
   decide whether a task is done. A human looks at the result once per sprint.
4. **Everything is bounded.** Every loop has a retry budget. When it runs
   out, the task goes to `Blocked`. Nothing spins forever.
5. **State lives in the planner, code lives in git.** An agent can be killed
   and restarted at any point and resume from Plane + GitHub state.

## Components

| Component | Where | Role |
|---|---|---|
| **Plane** (Community Edition) | `apps/plane/`, `plane.home.romangzz.com` behind Authelia | Task planner: Pages (PRD, architecture), Work items, Cycles (sprints), states, comments. API + MCP server |
| **agent-worker** | `apps/agent-worker/` (single pod) | Orchestrator loop that runs the cycle; uses OpenCode as the coding engine |
| **Ollama** | `apps/ollama/`, `ollama-service.ai.svc.cluster.local:11434` | Serves the developer and reviewer models (both GPUs, 64k context) |
| **GitHub** | Project repository | Code, branches, PRs, CI. Delivery target |
| **ntfy** | `apps/media/ntfy.yaml`, `ntfy-service.media` | Push notifications to the human |
| **Loki / Grafana** | `apps/monitoring/` | Full agent logs (collected by Alloy automatically) |

Security boundary: the worker pod is the sandbox, so the agent runs without
permission prompts. The pod is not privileged, has no hostPath and
`automountServiceAccountToken: false`. A NetworkPolicy limits egress to Ollama,
Plane, GitHub and package registries. Its GitHub token is fine-grained and
scoped to the one project repo. Its Plane token is scoped to the one project.
Both are `SealedSecret`s.

## Phases

```
 Phase 1            Phase 2               Phase 3                    Phase 4
 Specification ──►  Refinement      ──►   Autonomous cycle    ──►    Sprint review
 (human)            (human + agent)       (agent only)               (human)
```

### Phase 1: Specification (human)

The human writes in Plane Pages (or `docs/` in the project repo):

- **PRD**: problem, users, goals, non-goals, features.
- **Architecture**: stack, modules, data model, conventions, constraints
  (e.g. "no new dependencies without a work item").
- **Project `AGENTS.md`** in the repo: how to build, test and lint, plus code
  conventions. The agent reads it at the start of every task.

These are the source of truth. If code and spec disagree, the agent blocks.
It does not pick one.

### Phase 2: Refinement (human + planning agent, interactive)

The planning agent (on the workstation, connected to Plane via MCP) reads the
spec and proposes work items. The human challenges, splits and approves them.

**Work item template**

```
Title:        <verb> <outcome>            e.g. "Add JWT login endpoint"
Context:      why it exists; link to the PRD/architecture section
Acceptance:   - checkable statements, each mapped to at least one test
Scope:        files/modules expected to change (≤ 3–5)
Out of scope: what must NOT be done in this task
Depends on:   other work items (Plane relations)
Size:         S   (anything larger gets split)
```

**Definition of Ready**: an item can move to `Ready` only if:

- [ ] Every acceptance criterion is testable.
- [ ] Size is S (roughly one focused session of work).
- [ ] Dependencies are linked.
- [ ] Nothing in it contradicts the PRD or architecture.

Approved items go to `Ready` and are added to the active **Cycle**
(sprint `<n>`). Before the cycle starts, the human creates branch `sprint/<n>`
from `main`. Alternatively, the worker creates it when the first task begins.

### Phase 3: Autonomous development cycle (agent only)

#### States

```
 Ready ──► Analyzing ──► In Progress ──► In Review ──► Done
              │             ▲    │            │
              │             └────┘ tests fail │ changes requested
              │            (≤ 3 attempts)     └──► In Progress (≤ 3 rounds)
              ▼                                         │
           Blocked ◄────── budget exceeded / ambiguity ─┘
```

Plane states: `Backlog`, `Ready`, `Analyzing`, `In Progress`, `In Review`,
`Done`, `Blocked`. Only the worker moves items from `Ready` onward. Only the
human moves items out of `Blocked`.

#### Steps

| # | Step | Agent action | Recorded in Plane |
|---|---|---|---|
| 1 | **Pick** | Take the highest-priority `Ready` item in the active Cycle whose dependencies are all `Done` | State → `Analyzing` |
| 2 | **Analyze** | Read the item, linked spec sections, project `AGENTS.md` and relevant code. Write an implementation plan. If acceptance criteria are ambiguous or conflict with the spec → **Blocked** | Comment: plan |
| 3 | **Implement** | Branch `task/<id>` from `sprint/<n>`. Write code **and** tests. Run tests + lint locally; on failure, fix and retry | State → `In Progress`; comment per attempt |
| 4 | **Review** | Reviewer pass (separate prompt, preferably a different model) checks the diff against acceptance criteria, scope/out-of-scope, architecture and AGENTS.md conventions. Verdict: `approve` or `changes requested` with findings | State → `In Review`; comment: verdict + findings |
| 5 | **Fix** | Address every finding, re-run tests, back to step 4 | Comment: what changed |
| 6 | **Deliver** | Push and open a PR `task/<id>` → `sprint/<n>` (description: item link, plan, review verdict). When GitHub CI is green → **auto-merge** (squash), delete the branch | Comment: PR link; State → `Done` |
| 7 | **Next** | Return to step 1. When no eligible `Ready` items remain → Cycle finished | ntfy: cycle summary |

#### Budgets

| Budget | Limit | On exhaustion |
|---|---|---|
| Test/lint attempts per implementation round | 3 | Blocked |
| Review rounds | 3 | Blocked |
| Wall-clock per task | e.g. 2 h | Blocked |
| CI failures after PR | 2 fix attempts | Blocked |

#### Blocked protocol

1. Push the work-in-progress branch (never discard work).
2. Comment on the item: what was attempted, the exact failure or ambiguity,
   and what the agent needs from the human.
3. State → `Blocked`, ntfy notification.
4. Continue with the next eligible item. Items that depend on the blocked one
   stay ineligible.

#### Models

- **Developer**: the strongest coding model available in Ollama that fits
  both GPUs with the 64k context.
- **Reviewer**: a different model family when possible, so it doesn't share
  the developer's blind spots. Swapping models costs seconds per task, which is
  acceptable because the cycle is sequential.
- While the worker is active, Open WebUI and Hermes requests queue behind it.
  If that matters, restrict the worker to working hours.

#### Hard rules for agents

- Never push to `main` or `sprint/<n>` directly. Only PRs.
- Never change files outside the item's scope without explaining why in the
  review comment. The reviewer rejects unexplained scope creep.
- Never edit acceptance criteria, the PRD or the architecture. Block instead.
- Never commit secrets. Never disable, skip or weaken tests to get green.
- Every task leaves the `sprint/<n>` branch green.

### Phase 4: Sprint review (human, once per cycle)

1. **Plane Cycle summary**: done vs. blocked, any trends.
2. **Integration PR `sprint/<n>` → `main`**. This is the single human quality
   gate. Review the aggregate diff, run the app, merge or request fixes. Fixes
   become new work items for the next cycle.
3. **Resolve `Blocked` items**: clarify, split or re-scope, then set them back
   to `Ready` (or move them to the next cycle).
4. **Retro**: every mistake the agent repeated becomes a rule in the project
   `AGENTS.md` or in the developer/reviewer prompts. This is how the system
   improves between sprints.

## Observing and controlling

| Need | Where |
|---|---|
| Progress at a glance | Plane board / Cycle view |
| Why a task did what it did | Item comments (plan, attempts, review verdicts) and the PR |
| Full trace | Grafana → Loki, namespace of `agent-worker` |
| Interruptions | ntfy: only `Blocked`, cycle finished, worker crash |
| Pause | Scale `agent-worker` to 0 replicas, or add a `paused` label to the Cycle (the worker checks it before each pick) |
| Redirect a task | Comment on the item and move it back to `Ready`; the worker reads all comments during Analyze |

## Branching summary

```
main ──────────────────────────────────────────────●── (human merges at sprint review)
  └─ sprint/<n> ──●────────●────────●──────────────┘
                  ↑        ↑        ↑
          task/<id-1>  task/<id-2>  task/<id-3>   (agent PRs, auto-merged on green CI)
```
