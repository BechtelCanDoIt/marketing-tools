# people-app: let a listed service client read the employee directory

## Why

Amplify needs to know who sits on whose team, so it can rank each employee against their own sub-team on the leaderboard. people-app already has that data in `GET /employees/basic-info`: every Active and Marked leaver employee, with name, work email, photo, team and sub-team. One WSO2's Org Chart reads the same endpoint today.

The catch is who's allowed to call it. Amplify has to resolve teams server to server. If the browser sent the list of teammates, any employee could ask for anyone's points. So `amplify-api` calls people-app through the gateway with OAuth2 client credentials, and that token belongs to an application, not a person.

Here's what `JwtInterceptor` does with a token like that today:

1. It decodes `x-jwt-assertion` and converts the payload to `CustomJwtPayload`, which requires `email` and `groups`.
2. A client-credentials token has neither, so the conversion fails and the caller gets **500 "Malformed Invoker info object!"**.

There's no way for a service to read the directory, even though every signed-in employee can.

## What changed

All of it is in `apps/people-app/backend`.

`modules/authorization/types.bal` adds `ServiceClientConfig`, with two fields:

| Field | Default | Meaning |
|---|---|---|
| `clientIdClaim` | `"azp"` | The gateway JWT claim that holds the calling application's client id |
| `directoryClientIds` | `[]` | Client ids allowed to read the directory. Empty means no service callers at all |

`modules/authorization/authorization.bal` adds `public configurable ServiceClientConfig serviceClients = {};`. Inside `JwtInterceptor`, before the existing user path, a token with **no `email` claim** is checked against that list:

- Listed client and `GET /employees/basic-info`: the client id goes into the request context under `HEADER_SERVICE_CLIENT`, and the request carries on.
- Listed client and any other route or method: 403 "Insufficient privileges!", with a warning log naming the client and the route.
- Not listed: falls through to the existing code, which answers exactly as it does today.

Two small helpers sit at the bottom of the file: `allowedServiceClient` reads the claim and checks the list, and `isServiceClientRoute` matches the one allowed route.

`modules/authorization/constants.bal` adds `HEADER_SERVICE_CLIENT` and `SERVICE_CLIENT_PATH` (`employees/basic-info`).

`service.bal`: the `employees/basic-info` resource used to return 500 when there was no user in the context. It now accepts either a user or a service client. The query and the data it returns don't change.

`Config.toml.local` gets the new `[people.authorization.serviceClients]` section with empty defaults.

## Why it's shaped this way

I tried to keep the blast radius as small as I could.

It's off unless someone turns it on. With `directoryClientIds` empty, nothing behaves differently, so the PR can merge before anyone has a client id to list.

The route is fixed in code. The client list is config, but the one route a service may reach is a constant. Opening a second endpoint to services should take a code change and a review, not a config edit in the console.

User tokens never take the new path. The branch only runs when the token has no `email`, so a person signed in through an app whose id happens to be listed still goes through the normal role checks. There's a test for exactly that case.

It doesn't widen what's visible. A service client gets the same rows and fields any signed-in employee can already read from this endpoint. Personal info, search and single employee records stay off limits (403).

It keeps the trust model we already have. The interceptor decodes `x-jwt-assertion` without checking its signature and relies on the gateway for that. This change does the same: the client id has to come from the gateway's assertion, never from anything the caller sends directly.

## How I tested it

Unit tests, new in `modules/authorization/tests/service_client_test.bal`. They run the real `JwtInterceptor` in front of a small test service:

| Test | Expected |
|---|---|
| Listed client reads `GET /employees/basic-info` | 200, service client set, no user set |
| Listed client asks for `/employees/{id}`, `/employees/{email}/vehicles`, `POST /employees/basic-info` | 403 each |
| Unlisted or blank client id | 500, same as before |
| Employee user | 200 as before; a user with no people group still gets 403 |
| User token that also carries a listed client id | Stays a user (403 without a role) |

Run them with `bal test --tests "people.authorization:*"` on Ballerina 2201.12.7: 5 passing.

End to end, I ran the real people-app (this branch, built on 2201.12.7) against MySQL 8.0 loaded with `people_app_creation.sql` and a handful of seeded employees. A small stand-in for the Choreo gateway issues client-credentials tokens and turns them into `x-jwt-assertion` with `azp` set. Then I pointed `amplify-api` at it through its normal OAuth2 client-credentials config.

| Check | Result |
|---|---|
| Directory read as `amplify-api-local` through the gateway | 200, 11 rows |
| `Left` employees still excluded | yes |
| Same token on a single employee, personal info, search | 403, 403, 403 |
| Unlisted client id, straight to people-app | 500 (unchanged) |
| Employee user reads the directory | 200 |
| User with no people group | 403 |
| amplify-api My Team built from people-app | `OK`, team = Forward Deployed Engineering, headcount 9 |

I also flipped it off: same build, `directoryClientIds = []`. The service read went back to **500 "Malformed Invoker info object!"** and Amplify's team view went back to `UNAVAILABLE`. That's the before and after in one environment.

The harness lives in the marketing-tools repo at `apps/amplify/local/people-app-proto/` (`run.sh up | demo | off | down`), if you want to rerun it.

## Rolling it out

1. Create a Choreo connection from the Amplify project to the people-app API, which gives Amplify a client id and secret.
2. **Look at a real gateway token from that connection and confirm which claim carries the client id.** I defaulted to `azp`, but I haven't seen a Choreo backend JWT for a client-credentials call yet. If it's a different claim, set `clientIdClaim` to match.
3. Add the client id to `directoryClientIds` in people-app's config for that environment.
4. On the Amplify side, set `PEOPLEDIRECTORYURL`, `PEOPLEDIRECTORYTOKENURL`, `PEOPLEDIRECTORYCLIENTID` and `PEOPLEDIRECTORYCLIENTSECRET`.

## Things I tripped over (not in this PR)

None of these come from this change, but they cost me time getting people-app running locally, so I'm noting them for whoever hits them next:

- `people_app_creation.sql` won't load on MySQL 8.4: "Failed to add the foreign key constraint. Missing unique key for constraint 'fk_emp_office_company'". 8.4 now requires a unique key on referenced columns, and `office (company_id, id)` doesn't have one. It loads fine on 8.0.
- A jar built with Ballerina 2201.13.3 dies at start-up with `NoClassDefFoundError ... database/1/identifiers/global_vars/$v$1` at `types.bal:34`. Building on 2201.12.7, the version in `Ballerina.toml`, works.
- `Config.toml.local` still has `[people.scim]` and `[people.email]`, but those imports are commented out in `service.bal`, and the runtime refuses to start with config for modules it doesn't load.
- `bal test` across the whole package stops with "value not provided for required configurable variable 'dbConfig'", since the root module has no tests or test config. Module tests run fine with `--tests`.
- On Apple Silicon the Alpine JRE can't load netty's native TLS library, so people-app needs a glibc base image there.

Anything I missed or got wrong is my fault. Leave a comment and I'll fix it right up!
