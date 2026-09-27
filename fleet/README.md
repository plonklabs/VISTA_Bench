# The fleet arm

Everything a throwaway repository needs to be a fleet: the `.fleet/` a
benchmark run copies in, the worker the harness starts, and the one CI
workflow the repository is graded through.

```
fleet/
  overlay/      copied into the throwaway repository before `fleet init`
    .fleet/config.toml              the team file
    .fleet/agents/bench/config.toml the one member
    .fleet/templates/               implement, init, main
    .fleet/actions/rebase           what the landing lane runs
    .claude/agents/worker.md        what `--agent worker` resolves to
    .gitignore
  ci/check.yml  copied to .github/workflows/check.yml
  README.md     this file
```

Nothing here names the benchmark repository or the throwaway repository. Both
are read from the git remote, or from `PLONK_GITHUB_REPOSITORY`, at the moment
a command runs.

## What the arm is

One item, one dag, one merged `main`, nobody in the loop. The runner creates
the repository, files the C4 prompt as its single item, creates the dag by
hand and starts the root; `main` at the deadline is the submission.

The dag is created directly — `fleet dag create implement --issue <n>` —
rather than through `intake`. Intake exists to turn a labelled issue into a
dag without a person typing the create, which is worth having when a backlog
is being drained by a team. Here there is exactly one item, created by the same
script that creates the repository, and going through intake would buy a label
vocabulary that has to round-trip through the repository-creation script and a
GitHub call every five minutes for the length of the run, in exchange for
nothing. The `[issues] ready` and `hold` labels are still named in the team
file, so a run that turns intake on has the vocabulary rather than inventing
one under time pressure. `init.star` therefore stands two crons, `main` and
`sweep`, and the apply step below deletes the intake template `fleet init`
writes.

## Applying it

Each step runs in the throwaway repository's checkout on the runner. `<repo>`
is `owner/name`; nothing below assumes what either is.

```bash
# 1. the repository, and the default branch pushed so there is a base
gh repo create "$REPO" --private
git init -b main .
git remote add origin "https://github.com/$REPO.git"
cp -R <this checkout>/fleet/overlay/. .
mkdir -p .github/workflows
cp <this checkout>/fleet/ci/check.yml .github/workflows/check.yml

# 2. the model, on all four tiers, from the same value the other arm is given
sed -i "s/MODEL-PINNED-BY-THE-RUNNER/$MODEL/g" .fleet/agents/bench/config.toml

# 3. the item's inputs, wherever the prompt tells the worker to look
cp -R <the task's inputs>/ inputs/

git add .fleet .claude .github .gitignore inputs
git commit -m "the fleet overlay and the task inputs"
git push -u origin main
git remote set-head origin -a          # `fleet doctor` and the rebase action read origin/HEAD

# 4. the ruleset that makes `pr.checks.*` mean something (see the findings)
gh api -X POST "repos/$REPO/rulesets" --input - <<'JSON'
{ "name": "check", "target": "branch", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [ { "type": "required_status_checks",
               "parameters": { "strict_required_status_checks_policy": false,
                               "required_status_checks": [ { "context": "check" } ] } } ] }
JSON

# 5. the fleet
PLONK_AGENT_ID=bench fleet init
rm -f .fleet/templates/intake.star      # a cron template nothing stands is a doctor finding
fleet doctor                            # expect no template finding

# 6. the item and the dag
gh issue create --repo "$REPO" --title "<the task>" --body-file item.md
fleet dag create implement --issue "$N" --tier heavy

# 7. the run
fleet up
```

`item.md` is the C4 system prompt with the task description appended,
verbatim, and a `## Shape` table at the end of it — the `admit` step's gate
asks the body for a `Title` row and a `Tier` row, and `draft-pr` titles the
pull request from the `Title` row:

```markdown
## Shape

| key | value |
|---|---|
| Title | <what the app is> |
| Tier | heavy |
```

## What the runner must set

| knob | where | why |
|---|---|---|
| `PLONK_AGENT_ID=bench` | environment of every `fleet` call | names the member whose `.fleet/agents/<name>/` is read |
| `PLONK_GITHUB_REPOSITORY=<owner/name>` | environment of every `fleet` call | the repository, until plonklabs/plonk#3130 lands. Without it the remote is parsed from `origin`, which works, so this is belt and braces on a runner where the remote may be a token URL |
| the model, four times | `.fleet/agents/bench/config.toml`, substituted at step 2 | fleet reads no environment variable in TOML, and all four tiers must carry a model or the config fails to load |
| `claude` first on `PATH` | environment of `fleet up` | the harness argv is `claude -p …` and is not configurable; the pinned binary is pinned by `PATH` and by nothing else. It is the same binary the other arm gets through `CLAUDE_BIN` |
| `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` | environment of `fleet up` | every session inherits it |
| `JEV_KEY` | environment of `fleet up` | `[judge.systemone] key_env` names it; `fleet up` refuses to start without it while the chain asks the engine |
| `gh` authenticated | the runner | fleet shells `gh api` for everything it reads and writes on GitHub; the token must create repositories, push, merge and read Actions |
| `FRONTEND_PORT` repository variable | optional, on the throwaway repository | what `check.yml` curls. Unset it defaults to `38000`, the grader's pair |

`[sessions] max = 2` is a fairness knob and is reported with the run: the
other arm is one session, and this is how many this one may have at once.

## The shape of `implement`

```
workspace → admit → branch → build → draft-pr → self-review → ready
          → fix-check → land → rebase → merge → close-out
```

`build` and `self-review` and `fix-check` are the only steps a session runs.
Everything else is the tick's. There is no owner step and no review step: there
is nobody to rule on anything, and there is no review bot in this organisation,
so a step waiting on a verdict would wait for a comment nobody will write.

`fix-check` is the one that earns its place. It is an agent step whose
`done_while` gate holds as long as the `check` workflow is **not** red, so a
green or still-running head walks straight past it and a run that fails puts a
session on the branch with everything behind it waiting again. A red build
therefore becomes work rather than a stop — which matters more here than
anywhere, because of the first finding below.

Every `on_fail` offers a retry, and the two failures of `rebase` are told apart
by rules in the team file. None of them routes to the owner.

## What fleet could not express

One line each, with where it was read from (plonk `main`, 2026-09-27).

1. **The first stop at any step parks the dag, whatever the judge decides.**
   `dispose` returns `Ask` unless the move has been made from that
   `(template, node)` before, read out of the `log` table — and a throwaway
   repository's ledger is empty, so no rule and no engine can move anything the
   first time. An `Ask` routed to the owner opens nothing.
   `core/src/orchestrator/dispose.rs`, `src/ledger/judged.rs` `move_ever_made`,
   `core/src/orchestrator/drive.rs` `opened_by`. **This is the largest risk to
   "nobody in the loop", and it is why the templates are built to wait rather
   than to fail.**
2. **The engine judge can never settle a stop on a fresh ledger.** `[judge.systemone]
   admission = "facts"` reads admission rows a curated suite writes; with none,
   every step is unadmitted, the engine's answer is kept for the record and the
   chain ends at `Ask`. `src/up.rs` `admissions`,
   `core/src/orchestrator/judge.rs` `Chain::judge`. The engine half of the
   chain costs calls and settles nothing here.
3. **`main.green` is true on a branch with no workflow runs at all** — an empty
   set of conclusions is green. `core/src/sources/main.rs` `settled`. So a seed
   CI run on the default branch is *not* a precondition of `admit`, and the
   plan's assumption that it was is wrong.
4. **`pr.checks.green` is true over an empty set of required checks**, which is
   what a repository with no branch ruleset has — so without step 4 above a
   head nothing ever built reads green and merges. `core/src/sources/pr.rs`
   `check_facts`. Shaping the repository is not something a `.fleet/` can carry.
5. **A resource pool is a counting semaphore and cannot hand its holder a
   value.** `Pools` is `name → u32` and a `Hold` is `{resource, dag, took_at}`
   with no slot; nothing reaches a session but the lane's name.
   `core/src/config.rs` `Pools`, `src/ledger/holds.rs`,
   `core/src/render/model.rs` `RunRow.lanes`. A pool of *port pairs* is not
   expressible: the overlay declares a count and the session derives its ports
   from the checkout's own name.
6. **A receipt is only observed for a workflow some step of the graph
   dispatches.** `src/tick/refresh.rs` `dispatched_workflows`. A workflow that
   fires on push cannot be waited on as `pr.receipt.<workflow>` without also
   being dispatched, which runs it twice per head — so this overlay uses the
   ruleset and `pr.checks.*` instead of a receipt leg.
7. **`fleet init` writes all eight scaffold templates and never a subset**, and
   a cron template nothing stands is a `fleet doctor` finding — so applying the
   overlay ends by deleting the template the run does not use.
   `core/src/scaffold.rs` `files`, `src/tick/doctor.rs` `check_templates`.
8. **`fleet dag templates --lint` does not run the checks `fleet doctor` runs.**
   A step holding a pool `[resources]` does not declare lints clean; only
   `doctor` names it. So a green lint is not evidence the templates are
   loadable under this repository's policy, and applying the overlay runs
   `fleet doctor` as well.
9. **The harness argv is hard-coded**, so the `claude` binary is pinned by
   `PATH` and by nothing a configuration file can say.
   `core/src/harness.rs` `HARNESSES`.
10. **`[tiers.<harness>]` takes literal model ids and reads no environment
    variable**, and all four keys are mandatory once the table exists — so the
    model is substituted into the file before `fleet init`.
    `core/src/config.rs` `Models`.
11. **The repository is resolved from `origin` or `PLONK_GITHUB_REPOSITORY`**,
    both of which name a repository rather than being given one.
    `src/gh.rs` `resolve_repo`. Filed as plonklabs/plonk#3130.
12. **A step gated on a review fact waits forever when `[review] bots` is
    empty**: `review_facts` returns nothing, and a predicate over an unobserved
    key refuses rather than reading false. `core/src/sources/pr.rs`
    `review_facts`. Hence no review step.
13. **`[review] check` is read by nothing** — it is validated and printed in
    the help, and no source consults it. `core/src/config.rs` `check_review`.
14. **The scaffold's review-cap decision has no non-owner form.** `implement`'s
    `size` is an `owner_step`, and there is no predicate that answers "this
    branch is too wide" with anything but a person — so the overlay drops the
    cap rather than shipping a step that parks.
    `core/scaffold/templates/implement.star`.
15. **The scaffold's `analysis` ends at an `owner_step` and opens a `spec`**, so
    routing any failure to it under nobody-in-the-loop parks a second dag and
    spends a session on an investigation nobody reads — hence `main.star` here
    drops the `escalate` step that opens one on a red base.
    `core/scaffold/templates/analysis.star`.
16. **`fleet doctor` and `.fleet/actions/rebase` both read `refs/remotes/origin/HEAD`**,
    which a freshly created repository has not got until `git remote set-head
    origin -a` — which is why step 3 above runs it.
