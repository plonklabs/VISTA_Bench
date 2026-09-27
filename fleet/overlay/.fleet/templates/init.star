# How a throwaway benchmark repository becomes a fleet. Every step is
# idempotent, so a re-run creates only what is missing.
#
# Two crons stand rather than the scaffold's three. The item is created by
# hand — `fleet dag create implement --issue <n>` — so `intake` has nothing to
# scan for: a run with one item needs no label vocabulary, and a scan that
# never matches is a GitHub call every five minutes for the length of the run.

ledger   = tick_step("ledger", action = create_ledger(), done_when = "init.ledger")
adapters = tick_step("adapters", action = write_adapters(), done_when = "init.adapters")

schedule_main  = tick_step("schedule-main", action = create_instance("main"))
schedule_sweep = tick_step("schedule-sweep", action = create_instance("sweep"))

dag("init", once_trigger(priority = 0) >> ledger >> adapters >>
    [schedule_main, schedule_sweep], max_actions = 5)
