# The health of the branch everything merges into. One cron dag, no checkout.
#
# The scaffold's third step opens an `analysis` dag when the branch goes red.
# It is dropped here: that template ends at an `owner_step`, and with nobody to
# rule on it the dag it opens parks on the item after spending a session on an
# investigation nobody reads. A red base is already a fact the `land` and
# `merge` steps read for themselves.

follow  = tick_step("follow", action = follow_main())

refresh = tick_step("refresh",
                    action = observe_main(events = ["push", "workflow_dispatch",
                                                    "workflow_run"]),
                    done_when = "main.observed")

dag("main", cron_trigger("*/5 * * * *", overlap = "skip") >> follow >> refresh)
