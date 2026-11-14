# Changelog

All notable changes of `dlc-appointments-db` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow
[Semantic Versioning](https://semver.org/). A release is tagged `v<version>` once it is merged into `main`.

## [Unreleased]

## [3.0.0] - 2026-11-14

The changelog starts at this release.

### Added

- Create appointments schema with Liquibase.
- Add appointment persistence and overlap protection.
- Add scheduling availability, outbox and runtime grants.
- Add appointment lifecycle audit and versioned reminders.
- Add appointment calendar query indexes.
- Add ongoing clinical assignment persistence.
- Add environment bootstrap and owner-role migrator.
- Add synthetic dev and qa scheduling seed.
- Add idempotency records and consumer inbox.
- Add care completions, patient gates and reminder history.
- Add waiting list, appointment types and appointment type reference (DB-12, DB-13).

### Fixed

- Accept WaitingListEntry idempotency records (DB-13).
