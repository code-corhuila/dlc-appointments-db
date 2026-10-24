# Deferred appointment constraint suite

NOT EXECUTED: no appointment table or exclusion constraint exists in DB-03A.
Before enabling these cases, migrate the real DB-03B table and verify its catalog
columns, named CHECK constraints and partial GiST exclusion. Never count absence
of the table as a passing test. Use synthetic UUIDs and explicit offset timestamps.

| Case | Required assertion |
|---|---|
| Valid appointment | Insert accepted; read back contractual values |
| Invalid interval | Equal, inverted, NULL and infinite endpoints rejected |
| Invalid state | Noncanonical value rejected by the named CHECK |
| Same dentist overlap | Rejected by the named exclusion, SQLSTATE 23P01 |
| Different dentists overlap | Both inserts accepted |
| Adjacent intervals | Both accepted using half-open boundaries |
| Status participation | Active states conflict; terminal states release interval |
| Version, reason, reminder | Contractual checks enforced independently |
| Concurrent conflict | Two connections: only one conflicting transaction commits |

Use independent BEGIN/ROLLBACK transactions for cases; assert the expected named
constraint and SQLSTATE, not just any nonzero psql exit. An unexpected error fails
the case. For concurrency use two native processes with distinct application_name,
verify the second is waiting on the first with pg_blocking_pids, then commit the
first and require exclusion rejection. Repeat aborting the first and require the
second to succeed. Bound barrier polling/process waits and fail on timeout; sleeps
alone do not establish concurrency. Always close both connections in finally.
Keep this orchestration separate from the migration lifecycle runner.

btree_gist is required for UUID equality in GiST. Its owner, namespace, permissions
and test provisioning must be coordinated separately. DB-03A does not install it.
Application authorization, valid transitions, patient activity and availability
are separate workflow guarantees, not outcomes proved by these constraint cases.
