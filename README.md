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

## DB-01 verification runner

Requires PowerShell 7, Docker Engine and Docker Compose v2+.
Run from the repository root (Windows or Linux):

```powershell
pwsh -File scripts/verify-db.ps1 -StaticOnly
pwsh -File scripts/verify-db.ps1
```

The first command checks the include-only DB-01 grammar, reachability and DDL
order without Docker. It intentionally rejects changesets: extend the verifier
in DB-02 before introducing migrations. It is not a general YAML parser.
The second checks the daemon, Compose configuration, starts a new PostgreSQL,
runs Liquibase validate/update/update, inspects history, then runs update again.
With zero changesets, rollback is explicitly not applicable, not a tested success.
Catalog assertions reject business objects, other owner schemas and extensions.
CI runs both commands for pull requests and pushes to develop.

The Compose fixture has no published ports or external database URL. It uses a
unique project, temporary database storage and a generated per-run test password.
Cleanup removes only that invocation's project in a finally block. No real
credentials or .env file are needed; do not copy production credentials here.
The sample environment file documents optional test image overrides. Export them
in the shell; the runner does not load .env.example automatically.

Images postgres:16.13 and liquibase/liquibase:4.33.0 are fixed **proposals for
verification**, not approved production versions. Sources:
[PostgreSQL release](https://www.postgresql.org/docs/16/release-16-13.html) and
[Liquibase Docker releases](https://github.com/liquibase/docker/releases).
Tags, JDBC compatibility and successful pulls still require runtime verification.

ADR-002/003/007/008 preserve one shared production PostgreSQL with owner schemas.
This isolated fixture does not replace that architecture. Its init-test.sql
creates only appointments_liquibase for technical history/locks, automatically
before Liquibase starts. Nothing is created manually in a shared database.
This is a test-only metadata convention; production metadata placement, grants,
owner-scoped credentials and bootstrap remain unapproved and must be coordinated.
Do not use this test superuser or runner against shared environments.

No business schema, business tables, production users, extensions or changesets are introduced.
Empty-changelog success does not prove HU-APT-001 persistence. DB-02 should resolve
metadata ownership and add the first schema migration with explicit SQL rollback,
then extend CI to test actual own-change rollback and reconstruction. Rollback of
populated shared environments remains a separate reviewed recovery operation.

### Local evidence (2026-10-23)

- Docker client 29.8.0; Compose v5.5.1.
- Static verifier: PASS, 27 reachable changelogs and zero changesets.
- PowerShell syntax parser and docker compose config --quiet: PASS.
- Missing include, invalid leaf and unreachable file rejection: PASS in temp copies.
- Full runner: exit 1 at daemon preflight (Docker Linux engine pipe unavailable).
- No database started; Liquibase validate/update/rollback and CI execution unverified.
