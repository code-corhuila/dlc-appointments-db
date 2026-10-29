# dlc-appointments-db

> appointments bounded context: database (schema, seeds, migrations)

Part of **DI LUCCA**, Appointments bounded context.
Governance and documentation live in [`dlc-docs`](https://github.com/code-corhuila/dlc-docs).

## Branching

Three permanent branches. **None of them accepts a direct commit** — you enter through a child
branch and leave through a Pull Request.

```
develop  <--PR--  feat/... fix/... chore/...
qa       <--PR--  qa/...
main     <--PR--  release/...  hotfix/...
```

Promotion happens **by re-application** (`git cherry-pick -x`), never by merging one permanent
branch into another: `merge develop -> qa` and `merge qa -> main` do not exist in this model.

`main` requires **1 approval from `ariel5253`**. On `develop` and `qa` the team sets its own review
rule.

Full policy: `00-governance/branching-policy.md` in `dlc-docs`.

## DB-02 schema migration and verification

Requires PowerShell 7, Docker Engine and Docker Compose v2+.
Run from the repository root (Windows or Linux):

```powershell
pwsh -File scripts/verify-db.ps1 -StaticOnly
pwsh -File scripts/verify-db.ps1
```

The first command checks reachable changelogs, DDL order, external SQL references,
DB-02 invariants and ordered id/author/filename identities against an explicit
expected manifest. Supported static grammar is deliberately limited; Liquibase
validate remains authoritative. CI runs the default DB-01-to-current suite.

From Windows CMD, with PowerShell 7 and an accessible Docker daemon:

```bat
pwsh -File scripts\verify-db.ps1 -StaticOnly
pwsh -File scripts\verify-db.ps1
pwsh -File scripts\verify-db.ps1 -Baseline DB02
```

`-ExpectedManifest scripts/fixtures/db03-expected.json` is the default target.
A future manifest must enumerate every identity in execution order, expected
schema presence/owner and every nontechnical relation as schema.name:relkind.
Only Appointments relations may be expected; an omitted/unexpected object fails.
Keep the DB-02 manifest frozen for the reusable baseline.

Each run creates separate empty and upgrade fixtures. Upgrade executes either
DB01 (empty) or DB02 (includes the canonical schema changelog, no SQL copy), then
the master in the SAME database without resetting history/locks. Exact history
and execution types, metadata OIDs, baseline history, second-update stability,
schema owner and unrelated namespaces/extensions are checked. Rollback verifies
identities first and reverts only the target suffix beyond the baseline, then
reconstructs. If baseline equals target, that scenario explicitly reports no new
changesets; it does not claim a new-migration upgrade or rollback test. The empty
scenario still exercises DB-02 rollback/reconstruction. Fixtures are test states,
not archived Git revisions. No migration SQL/checksum is modified by this runner.
The Compose fixture has no published ports or external database URL. It uses a
unique project, temporary database storage and a generated per-run test password.
Cleanup removes only that invocation's project in a finally block. No real
credentials or .env file are needed; do not copy production credentials here.
The sample environment file documents test images. Isolation preflight currently
accepts only the fixed versions below; changing them requires review. Export them
in the shell; the runner does not load .env.example automatically.

Images postgres:16.13 and liquibase/liquibase:4.33.0 are fixed **proposals for
verification**, not approved production versions. Sources:
[PostgreSQL release](https://www.postgresql.org/docs/16/release-16-13.html) and
[Liquibase Docker releases](https://github.com/liquibase/docker/releases).
Tags, JDBC compatibility and successful pulls still require runtime verification.

ADR-002/003/007/008 preserve one shared production PostgreSQL with owner schemas.
This isolated fixture does not replace that architecture. Its init-test.sql
creates appointments_liquibase for technical history/locks and provisions the
isolated extension fixture described below, automatically
before Liquibase starts. Nothing is created manually in a shared database.
This is a test-only metadata convention; production metadata placement, grants,
owner-scoped credentials and bootstrap remain unapproved and must be coordinated.
Do not use this test superuser or runner against shared environments.

DB-02 registers 001-appointments-create-schema, author bsbedoya, with labels
"HU-APT-001,ddl,schemas". The author was verified on 2026-10-23 via the GitHub
users API: login bsbedoya, name Brayan Smith Bedoya, account ID 160141855
(https://api.github.com/users/bsbedoya). The user authorized this initial ID;
coordination of numbering with the migration owner is still required.

SQL: CREATE SCHEMA appointments AUTHORIZATION CURRENT_USER;
CURRENT_USER becomes schema owner and requires CREATE on the target database.
Production migration role/ownership and runtime privileges remain pending.
The precondition HALTs if appointments exists; it never silently adopts a schema.
Rollback: DROP SCHEMA appointments RESTRICT; fails if objects remain, preserves
Liquibase metadata, and must not be forced with CASCADE or manual object removal.
No tables, indexes, extensions, roles or grants are introduced by DB-02.
This is schema infrastructure only, not completed HU-APT-001 or production readiness.

### Local DB-02 evidence (2026-10-23)

- RED: required migration and rollback files were absent before implementation.
- Static checks, PowerShell syntax and Compose configuration: PASS.
- Negative temp-copy probes (author, HALT, CASCADE, missing SQL): PASS.
- Runtime preflight: Docker Linux engine access denied; no migration tests executed.
- Empty deployment, rollback, reconstruction, DB-01 upgrade and remote CI: UNVERIFIED.
- Run the full runner locally with an accessible Docker daemon before acceptance.

### DB-03A verification preparation (2026-10-24)

Appointment cases are DEFERRED in scripts/fixtures/appointment-test-plan.md:
valid/invalid intervals and states, overlaps, adjacency, status participation and
two-connection conflicts. There is no appointment suite success before its table
exists. btree_gist provisioning, namespace and permissions require coordination;
this increment neither installs it nor defines production permissions.
Static checks and Compose config are executable without a running database;
real DB-02 lifecycle and baseline upgrade remain unverified until Docker works.

DB-03A local evidence: both baseline selections pass static checks; PowerShell
syntax and Compose config pass. Temporary-copy probes accept two changesets and
reject identity mismatches, non-HALT preconditions, CASCADE and unreachable YAML.
The full runner exits 1 at Docker preflight (permission denied); no PostgreSQL,
Liquibase lifecycle, upgrade or appointment constraint tests executed in Codex.

### DB-03B-PRE: isolated extension fixture

The user authorized btree_gist installation ONLY in newly created disposable test
fixtures. This is not a production extension migration. Init runs on empty tmpfs
before verification snapshots. Namespace: appointments_extensions; schema and
extension owner: bootstrap_test (the fixture initdb superuser). No persistent data
volume, host ports, external network or configurable external JDBC URL is used.
The default network is internal. Preflight inspects effective Compose config,
rejects unexpected services/mounts/images/connections, requires a fresh unique
project and verifies the running PostgreSQL data mount is tmpfs. Cleanup checks
that no containers or networks with that project label remain.

Catalog assertions require btree_gist, the namespace/owner, the default UUID GiST
opclass gist_uuid_ops and its pg_depend extension membership. Namespace USAGE and
visibility under an explicit transaction-local search_path are checked. A future
migration must qualify appointments_extensions.gist_uuid_ops or deliberately set
a trusted search_path; no implicit production search_path is approved here.
The normal runner compares namespace/extension snapshots after provisioning and
repeats extension assertions through baseline, updates, rollback and reconstruction.
It never removes the extension as a domain rollback. DB-01/DB-02 SQL and checksums
remain unchanged. Existing Windows CMD runner commands apply to both baselines.

Production extension owner, namespace, permissions, provisioning and version
approval remain pending. This fixture superuser is not a production permission
model. No appointment table, business index or constraint is introduced.

Local evidence (2026-10-24): PowerShell syntax, static DB01/DB02 selections and
effective Compose isolation checks PASS. Negative configuration probes reject
published ports, external JDBC URLs, non-tmpfs data paths and non-internal networks.
Both full baseline runners are BLOCKED at Docker preflight (permission denied).
Extension installation/catalog assertions, migration lifecycle and cleanup checks
are implemented but UNEXECUTED here; no test containers were started by Codex.

### DB-03B-A: integrity/concurrency harness (PowerShell 7+)

From Windows CMD:
```bat
pwsh -NoProfile -File scripts\test-pg-harness.ps1
pwsh -NoProfile -File scripts\verify-db.ps1 -Baseline DB01
pwsh -NoProfile -File scripts\verify-db.ps1 -Baseline DB02
```

The first command tests child-process transport with simulated responses, not
PostgreSQL. The full runner executes the harness only after fixture/storage
validation. Two persistent psql worker sessions and an independent observer use
explicit transactions. pg_blocking_pids proves blocking; advisory transaction
locks test release after COMMIT and ROLLBACK without creating business objects.
A deliberately expired client deadline must throw, then recover after release.
No timeout counts as an exclusion conflict. Server statement timeout is 10s.

Trusted fixture SQL uses anonymous DO exception subtransactions, capturing
RETURNED_SQLSTATE and CONSTRAINT_NAME into marked JSON notices. Assertions require
both exact values; failed statements roll back their subtransaction. Roll back
the surrounding test transaction after each integrity case. Query cancellation
and outer SQL errors fail the harness. No helper tables/functions are persisted.
Session shutdown is bounded, with backend termination/forced process cleanup as
fallback; the outer runner retains project-scoped cleanup and isolation checks.
This helper has no standalone database URL or external-container CLI option.

Local evidence: syntax, DB01/DB02 static checks and transport tests pass.
Docker daemon access is denied in Codex. Real sessions, blocking, SQL diagnostics,
extension checks and fixture cleanup are UNVERIFIED here. All appointment cases
remain DEFERRED until DB-03B-B creates the protected table.

### DB-03B-B: appointment persistence

Approved owner contract: dlc-docs/09-microservices/services/04-appointments-service/data-model.md.
Changeset 002-appointments-create-appointments (bsbedoya) creates the 16-column
appointments.appointments table and immediate partial GiST exclusion atomically.
No business SQL defaults or cross-owner FKs are introduced. The API supplies
PROGRAMADA/PENDING/PENDING/version 1 and authenticated actor/server timestamps.
Timezone validation, authorization, optimistic updates and lifecycle remain API work.

The migration discovers btree_gist's actual namespace from pg_extension, verifies
UUID GiST membership/access, and quotes that namespace explicitly in DDL under a
transaction-local pg_catalog search_path. It never installs/moves/drops extensions.
Production provisioner, namespace approval, grants, versions and deployment remain
pending. The fixture namespace is not imposed on shared databases.

Run pwsh -File scripts/test-appointment-static.ps1 for negative structural probes.
The existing DB01/DB02 runner commands now target scripts/fixtures/db03-expected.json.
DB02 stays frozen. The runner checks catalogs, 47 integrity cases, two conflicting
insert outcomes, exact SQLSTATE/constraint, persisted snapshots and session cleanup.
Rollback drops only appointments.appointments RESTRICT; it is destructive and
tested only in the disposable fixture. Production recovery requires its runbook.
Local static/transport checks pass; PostgreSQL migration, constraint and rollback
tests are BLOCKED by Docker daemon access. No production readiness is claimed.

### DB-04: scheduling support, outbox and runtime grants (HU-APT-001)

Completes the remaining HU-APT-001 persistence scope (issue #4) on top of DB-03B-B:

- 003-appointments-create-dentist-schedules: appointments.dentist_schedules (one
  row per dentist, optimistic version, audit pairs) plus availability_intervals and
  blocked_intervals. Each interval table has a half-open [) immediate GiST exclusion
  per schedule, a finite start<end CHECK and an ON DELETE RESTRICT owner FK.
  The btree_gist namespace is resolved exactly as in DB-03B-B.
- 004-appointments-create-outbox-events: owner-local outbox with the required
  integration metadata (event id/type/version, aggregate, payload, correlation,
  causation, actor, occurred/recorded, status, attempts, next retry, safe error code).
  PUBLISHED requires published_at and vice versa. No business SQL defaults.
- 005-appointments-create-outbox-events-indexes: partial relay index on
  unpublished events (10_indexes, per Annex A order).
- 006-appointments-grant-runtime-scheduling: DML-only grants to the externally
  provisioned appointments_runtime role. The precondition HALTs unless the role
  exists without superuser/createrole/createdb/replication/bypassrls and does not
  own the schema. No DELETE on appointments, schedules or outbox; interval rows
  can be deleted because availability replacement rewrites them. No DDL.

The migration never creates roles or extensions. The disposable fixture creates a
NOLOGIN appointments_runtime stand-in in init-test.sql. Production role name,
login/credential binding and provisioner remain to be approved in dlc-docs.

The default target is scripts/fixtures/db04-expected.json. -Baseline DB03 applies
the released DB-03 changesets from the real master (update-count) and then upgrades,
which is the previous-version check for this increment. DB01/DB02 remain available.

```bat
pwsh -File scripts\verify-db.ps1 -StaticOnly
pwsh -File scripts\verify-db.ps1 -Baseline DB03
```

scripts/fixtures/scheduling-tests.ps1 adds rolled-back integrity cases for the new
tables (exact SQLSTATE and constraint name) and privilege cases executed under
SET LOCAL ROLE appointments_runtime: allowed DML succeeds; DELETE of audit-bearing
rows, TRUNCATE, CREATE/ALTER/DROP and reading Liquibase metadata fail with 42501.

### DB-05: lifecycle audit and versioned reminders (HU-APT-002)

Persistence for issue #5:

- 007-appointments-create-appointment-status-changes: insert-only lifecycle audit,
  one row per accepted appointment version (uk on appointment_id+version). A CHECK
  allows only the documented transitions (SCHEDULE, CONFIRM, CANCEL, RESCHEDULE,
  START_ATTENTION, NO_SHOW, COMPLETE); rescheduling requires a changed old/new
  interval; cancellation and any override require a 1-1000 character reason; an
  override is limited to CANCEL/RESCHEDULE by an ADMINISTRATOR actor.
- 008-appointments-create-appointment-reminders: EMAIL-only reminder work keyed by
  appointment version, with PENDING/REQUESTED/SENT/DELIVERY_FAILED/INVALIDATED,
  attempts, stable delivery id, safe outcome code and invalidation instant.
- 009-appointments-create-appointment-reminders-indexes: at most one live
  (non-INVALIDATED) reminder per appointment, plus a pending due-instant index.
- 010-appointments-grant-runtime-lifecycle: SELECT/INSERT on the audit (no UPDATE
  or DELETE), SELECT/INSERT/UPDATE on reminders.

Annex A order places later tables before earlier indexes/grants, so the runner now
requires the baseline to be an ordered subsequence of the target and expects
upgrades to append the remaining changesets in changelog order. -Baseline DB04
applies the released HU-APT-001 changesets with --label-filter=HU-APT-001.
scripts/fixtures/lifecycle-tests.ps1 adds 80 rolled-back cases.

### DB-06: calendar query indexes (HU-APT-003)

Issue #6 asks to verify the calendar projection and migrate only evidenced gaps.
Before this increment appointments.appointments had only pk_appointments and the
partial GiST exclusion, which covers PROGRAMADA/CONFIRMADA/EN_ATENCION only and so
cannot serve a Dentist calendar that includes FINALIZADA, the patientId filter or the
default createdAt/id page order of GET /api/v1/appointments (API-APT-01).
011-appointments-create-appointments-calendar-indexes adds three btree indexes:
(dentist_id, start_at), (patient_id, start_at) and (created_at, appointment_id).
No table, column, projection or grant changes: the existing columns already hold the
minimal identity/status the API projects. -Baseline DB05 applies the released
HU-APT-001/002 state by label. scripts/fixtures/calendar-tests.ps1 checks the exact
index definitions and that each query path is planned through its index.

### DB-07: ongoing clinical assignments (HU-APT-004)

Persistence for issue #7, metadata only (REL-001/002):

- 012-appointments-create-clinical-assignments: patient/dentist identities, ACTIVE or
  ENDED, 1-1000 character reason, started_at/by, and on ending ended_at/by plus the
  required end_reason (the endings contract demands one) with version >= 2. ACTIVE
  rows carry no ending fields. started_by <> dentist_id rejects Dentist
  self-assignment. No clinical narrative column and no cross-owner FK.
- 013-appointments-create-clinical-assignments-indexes: at most one ACTIVE
  assignment per patient/dentist (ended rows stay as history), plus
  patient/dentist/status and dentist/status authorization paths.
- 014-appointments-grant-runtime-assignments: SELECT/INSERT/UPDATE only.

-Baseline DB06 applies the released HU-APT-001..003 state by label.
scripts/fixtures/assignment-tests.ps1 adds 31 rolled-back cases.
