# amplify_domain

Bounded contexts shared by `amplify-api` and `amplify-jobs` (ADR-021): per context, the pure domain model
(`types.bal`, `service.bal`, `events.bal`), its repository port, and the PostgreSQL repository
(`repository.bal`). Plus `store`: client, outbox and audit writers, SQL error mapping, partition upkeep call.

Depends on `amplify_common` (publish that first). Publish to the local repository before building a consumer:

```sh
bal pack && bal push --repository=local
```

Integration tests (group `integration`) need a migrated PostgreSQL 18; see `docs/migrations/README.md`.
