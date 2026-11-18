# API boundaries

[English](api-boundaries.md) | [Français](api-boundaries.fr.md)

For operators and contributors checking which callers can reach an HTTP surface.
The same classification applies to a standalone installation, separate platform and
compute machines, and a high-availability pair.

## Surfaces

| Surface | Intended callers | Entry and control |
|---|---|---|
| Product API | Browsers and authorized integrations | Platform or administration HTTPS entry; application authentication and resource permissions |
| Application API | Users of an application | That application's host and backend; its own contract and authorization |
| Service calls on one machine | Authorized service containers | Private networks and service credentials; no general host-port publication |
| Links between product machines | Paired machines | Dedicated link listener with verified client certificates; see [certificates and DNS](certificates-and-dns.md) |
| Operations and monitoring | Local health probes and the recorder | Container-local checks or the dedicated metrics network; no product entry |

An administrator using the product still uses the product API. An operator's metrics
endpoint is a separate surface. Authentication at a proxy does not replace the
receiving service's checks on the requested action and resource.

## Product routing

`Caddyfile` owns the platform and administration entries. Their shared
`product_api_boundary` keeps reserved service and operations paths off those entries,
including `internal` and `operator` namespaces at the root, under `/api` and
under `/api/v3`, as well as API documentation and metrics paths. Health probes inside an API container continue
to use their existing addresses. Product routes retain their upstream destinations;
the existing API is not replaced by this change.

API paths with structural encodings, dot segments or repeated separators are refused.
Normal encoded resource names, such as spaces, and query parameters remain supported.
The rule is evaluated before selecting an upstream and does not depend on credentials.
The response for a route outside this surface is 404.

Existing product APIs remain routed by their historical namespaces. This is not a
new exhaustive operation contract for those APIs. Each new surface must list its
published methods and paths explicitly; extending it requires the corresponding
contract, authorization and ingress tests.

Application hosts and generated applications keep their own contracts. A generic
platform rule must not reserve a path in somebody else's application. Their owners
are responsible for classifying application routes and enforcing access. The machine
links retain their existing admission and mutual TLS policy.

Caddy's own counters stay on the recorder's listener and network. Publishing another
service port to bypass routing is not a supported way to make an operation available.

## Qualifying a routing change

1. In one PR, update routing, this reference and `test/ingress.sh`. The CI runs the
   pinned Caddy against fake upstreams and checks existing product destinations,
   rejected methods and paths, encoded variants and the absence of an upstream call
   on rejection. The same API boundary is exercised with `internal`, `custom` and
   `edge` TLS. Application authentication is verified by the application's own tests.
2. Keep `test/migration.sh` based on `origin/main`: the version in service is the
   starting state. This routing change adds no setting, port or data migration of its
   own; the complete release can contain other changes covered by the upgrade checks.
3. Before activation, record the active package and configuration, and successful
   reference journeys: sign-in, a normal authenticated API operation, an integration
   call where configured, and monitoring collection. Use the normal managed
   [update procedure](update.md); do not patch a deployed Caddyfile by hand.
4. Before returning the installation to users, repeat those journeys and verify that
   service/operations routes stay off the product entry. One previously working
   journey failing, one forbidden route reaching an upstream, or monitoring losing
   a previously healthy target stops acceptance. The operator records the affected
   journey, HTTP status and package version without credentials or user content.
5. Correct the exact published route or follow the existing [recovery procedure](update.md#if-the-update-goes-wrong).
   Restoring the earlier package also restores its earlier routing policy; it is a
   recovery step, not evidence that the new boundary passed. Keep the change open
   until the intended policy and the product journeys are both verified.

A passing proxy test is not a record of deployment or of the application's resource
authorization. Record activation results separately with the release being qualified.

Sources consulted on 15 November 2026: [Caddy request matchers](https://caddyserver.com/docs/caddyfile/matchers),
[handle](https://caddyserver.com/docs/caddyfile/directives/handle),
[route ordering](https://caddyserver.com/docs/caddyfile/directives/route).
