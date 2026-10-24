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

`-ExpectedManifest scripts/fixtures/db02-expected.json` is the default target.
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
