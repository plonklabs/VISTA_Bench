# One application, from branch to merged `main`, with nobody in the loop.
#
# What this is, against the set fleet ships: the scaffold's `implement` has two
# steps a person answers — `size`, an `owner_step` that rules on a branch over
# the review cap, and the review round a bot posts. Neither exists here. There
# is no owner to rule, and there is no review bot in this organisation, so a
# step waiting for a verdict would wait for a comment nobody will write. What
# is left is the fleet's own loop: cut a checkout, build, review your own work
# once, open the pull request, wait for the one check the repository has, and
# land it.
#
# Every `on_fail` routes to a retry or back into the work. None of them routes
# to the owner: an escalation to the owner opens nothing and parks the dag on
# its item, and a parked dag in a benchmark run is a zero.

issue = param("issue")

# How long one session may go without pushing. Set per run at create, because
# the benchmark's deadline is what really bounds it.
build_timeout = param("build_timeout", "3h")

def rounds_reads(node):
    return ["step.%s.run_count" % node, "step.%s.error_count" % node,
            "step.%s.run_count_at_head" % node, "pr.head"]

def rounds(node, wanted):
    def check(facts):
        ran = facts.get("step.%s.run_count" % node, 0)
        beaten = facts.get("step.%s.error_count" % node, 0)
        done = ran - beaten
        if done < wanted:
            return "round %d of %d reviewed" % (done, wanted)
        at_head = facts.get("step.%s.run_count_at_head" % node, 0)
        if at_head < 1:
            return "%d rounds recorded, none at head %s; one more round at this head" % (
                done, facts.get("pr.head", "?"))
        return True
    return check

# One round, not the three the scaffold asks for. A greenfield application has
# no repository conventions for a second reader to check it against; the round
# that is worth its tokens is the one that re-opens the mockups and reads the
# built pages back against them, and a second pass over the same three inputs
# finds what the first did. The gate is credited by the content it covered, so
# a push after the round is content no round has read and it asks for another.
reviewed = gate("reviewed", rounds("self-review", 1),
                reads = rounds_reads("self-review"))

# What the item carries for a run to start on it: the rows of its `## Shape`
# table. The source holding the body takes the verdict.
shaped = gate("shaped", contains("issue.body", ["Title", "Tier"]))

# The one receipt this repository has. `pr.checks.red` is only ever true
# because the repository's default branch carries a ruleset requiring the
# `check` context — with no ruleset the aggregate reads green over an empty
# set of required checks and says nothing at all.
#
# A gate rather than a requirement, because a requirement that refuses is a
# wait and a wait is the wrong answer here: a red check is work, and the step
# it hangs off puts a session on it the moment the gate stops holding. That is
# what keeps a broken build out of the judge, which with nobody in the loop is
# where a run goes to park.
def not_red(facts):
    if facts.get("pr.checks.red"):
        return "the check workflow is red at this head"
    return True

checks_clear = gate("checks-clear", not_red, reads = ["pr.checks.red"])

# The two failures of the rebase, told apart by the text of the reason and by
# nothing a gate could have read first. The words are the ones
# `.fleet/actions/rebase` writes, and `.fleet/config.toml` carries a rule for
# each so neither needs a person.
rebase_stopped = {
    "retry": "The failure came from outside the change: the network, the code host, " +
             "a runner. The branch and the base are what they were.",
    "rewind:build": "The branch is what failed: it conflicts with the base. Settling " +
                    "that is coding work, and the checkout is left where a session can do it.",
}

cut = tick_step(
    "workspace",
    action = workspace(),
    done_when = "workspace.path",
)

# `main.green` is named here because `[templates] must_depend_on` asks for it
# on the step behind the cut. It is also the reason the throwaway repository
# runs its `check` workflow once on the default branch before the first dag is
# created: with no run at that head, neither green nor pending holds and this
# step never passes.
admit = tick_step(
    "admit",
    requires = [any_of("main.green", "main.pending"), shaped, "fleet.room"],
)

branch = tick_step("branch", action = create_branch(), done_when = "worktree.branch")

# `compose` is held from here to the pushed branch: the session brings the
# application up on this host to verify it, and the pool is how many such
# stacks may stand at once. Which host ports this session takes is derived in
# the session from the checkout's own name — a pool is a count and cannot hand
# its holder a port.
build = agent_step(
    "build",
    describe = "Writes the application from the item's mockups, structure JSON and " +
               "description, brings it up with `docker compose up --build`, verifies every " +
               "page in the README's `## Pages` table answers, and pushes the branch.",
    requires = ["worktree.head"],
    holds = ["compose"],
    done_when = "worktree.pushed",
    waits_on = "own",
    attempts = 0,
    timeout = build_timeout,
    skill = "build the application — the `build` row of .claude/agents/worker.md — for issue #%s" % issue,
    on_fail = decide(
        moves = {
            "retry": "The work is where the last session left it and another session can " +
                     "carry it on: a turn that ran out of time, or one that ended with the " +
                     "branch unpushed and the checkout holding commits.",
        },
    ),
)

draft_pr = tick_step(
    "draft-pr",
    action = open_draft_pr(),
    done_when = "pr.exists",
    on_fail = decide(
        moves = {
            "retry": "The code host refused the request itself: a network fault, a rate " +
                     "limit, an outage.",
            "rewind:build": "The request was refused for what the branch carries: no head " +
                            "where the fact said one was, or a subject the code host would not take.",
        },
    ),
)

review = agent_step(
    "self-review",
    describe = "Re-opens each mockup, walks the description's bullet for that page and reads " +
               "the built page back against both; fixes what is missing and pushes.",
    tier = "heavy",
    skip_when = ["pr.merged"],
    holds = ["compose"],
    done_while = reviewed,
    waits_on = "own",
    attempts = 0,
    timeout = "2h",
    skill = "review your own work — the `self-review` row of .claude/agents/worker.md — for issue #%s" % issue,
    on_fail = decide(
        moves = {
            "retry": "The round is where the last session left it: a turn that ran out of " +
                     "time, or one that ended without reporting what it had read.",
        },
    ),
)

ready = tick_step("ready", action = flip_ready(), done_when = "pr.ready")

# The step that keeps a red check from ending the run. It holds while the
# `check` workflow is not red, so a green or still-running head walks straight
# past it; the moment a run fails, the gate stops holding, this step returns to
# the frontier with everything behind it waiting again, and a session is put on
# it. The application not coming up is the one failure this benchmark can
# actually produce, and this is it answered by work rather than by a stop.
fix = agent_step(
    "fix-check",
    describe = "Reads the failing `check` run, fixes what it found — the application not " +
               "coming up from a cold start, or a page in the README's `## Pages` table not " +
               "answering — and pushes.",
    tier = "heavy",
    skip_when = ["pr.merged"],
    holds = ["compose"],
    done_while = checks_clear,
    waits_on = "own",
    attempts = 0,
    timeout = "2h",
    skill = "fix the red `check` run on this branch — the `fix-check` row of .claude/agents/worker.md — for issue #%s" % issue,
    on_fail = decide(
        moves = {
            "retry": "The fix is where the last session left it: a turn that ran out of time. " +
                     "The run is still red and another session carries it on.",
        },
    ),
)

# The `check` workflow fires on the push of its own accord, so there is no leg
# to dispatch and no receipt to place: `pr.checks.green` is the whole of it,
# and it means something only because the default branch's ruleset requires the
# `check` context. Seeding that ruleset is part of creating the repository.
#
# The wait is long on purpose. A judged retry of a step whose clock ran out is
# another window and nothing else, and with nobody to ask, a stop that could
# have been a wait is the most expensive thing in the run.
land = tick_step(
    "land",
    holds = ["landing"],
    skip_when = ["pr.merged"],
    timeout = "6h",
    requires = ["pr.ready", not_("pr.checks.red"), "pr.checks.green",
                "pr.base_is_default", "pr.mergeable", "main.ci_green"],
    on_fail = decide(
        moves = {
            "retry": "What holds the merge is outside the head and clears on its own: a " +
                     "base that is red, a check still running. The step reads its " +
                     "requirements again for another window.",
            "rewind:build": "The head itself is what holds the merge: the `check` workflow " +
                            "is red on this branch, so the application does not come up or a " +
                            "page in the README does not answer.",
        },
    ),
)

rebase = tick_step(
    "rebase",
    describe = "Puts the branch that is next to land onto a base nobody else can move. It " +
               "passes when the rebased head is pushed.",
    holds = ["landing"],
    skip_when = [any_of("pr.merged", all_("pr.base_disjoint", not_("pr.behind_base")))],
    action = run("rebase", idempotent = True),
    done_when = "script.rebase.head",
    attempts = 1,
    timeout = "30m",
    on_fail = decide(moves = rebase_stopped),
)

landed = tick_step(
    "merge",
    holds = ["landing"],
    action = merge(events = ["push", "workflow_dispatch", "workflow_run"]),
    requires = [not_("pr.checks.red"), "pr.checks.green", "pr.base_is_default",
                not_("pr.behind_base"), "pr.mergeable", "main.ci_green"],
    timeout = "6h",
    final_when = "pr.merged",
    on_fail = decide(
        moves = {
            "retry": "The code host refused the request itself: a network fault, a rate " +
                     "limit, an outage. A head that moved is not this — it is refused by its " +
                     "own status, spends no try and is re-read on the next pass.",
        },
    ),
)

# A tick step rather than a session: closing the item is one call, and a
# session spent on it is a session's worth of tokens on the run's bill.
close = tick_step("close-out", action = close_issue(), done_when = "issue.closed")

dag("implement",
    once_trigger(priority = 2) >> cut >> admit >> branch >> build >>
    draft_pr >> review >> ready >> fix >> land >> rebase >> landed >> close,
    depends_on = ["main"], timeout = "2h")
