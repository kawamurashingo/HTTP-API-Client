# HTTP::API::Client

A small, dependency-light foundation for building JSON HTTP API clients in Perl.

The goal is not to replace `HTTP::Tiny`, `LWP`, or `Mojo::UserAgent`. It adds the API-client layer applications repeatedly rebuild: base URLs, JSON request/response handling, default headers, timeout configuration, structured errors, conservative retries, pagination, rate-limit handling, and lifecycle hooks.

## Basic usage

```perl
use HTTP::API::Client;

my $api = HTTP::API::Client->new(
    base_url => 'https://api.example.com',
    headers  => {
        Authorization => "Bearer $ENV{API_TOKEN}",
    },
    timeout => 10,
    retry => {
        attempts   => 3,
        base_delay => 0.25,
        max_delay  => 5,
        jitter     => 1,
    },
);

my $response = $api->get('/users');
my $data = $response->json;
```

## Hooks

Client-level and per-request hooks make it possible to add authentication, logging, metrics, tracing, or other cross-cutting behavior without subclassing.

```perl
my $api = HTTP::API::Client->new(
    base_url => 'https://api.example.com',
    hooks => {
        before_request => sub {
            my ($ctx) = @_;
            $ctx->{headers}{Authorization} = "Bearer $token";
        },
        after_response => sub {
            my ($response, $ctx) = @_;
            log_status($response->status);
        },
        on_error => sub {
            my ($error, $ctx) = @_;
            record_failure($error->category);
        },
    },
);
```

`before_request` receives a mutable context containing `method`, `url`, `headers`, `content`, and the retry `attempt`. It runs immediately before each transport attempt. `after_response` runs after a successful response is received. `on_error` runs before retry is considered.

Each hook can be a coderef or an arrayref of coderefs. Request-local hooks are appended after client-level hooks:

```perl
$api->get('/users',
    hooks => {
        before_request => sub {
            my ($ctx) = @_;
            $ctx->{headers}{'X-Request-Tag'} = 'users';
        },
    },
);
```

Hook failures are surfaced as structured, non-retryable `hook` errors.

## Rate limits

Responses expose normalized rate-limit metadata:

```perl
my $response = $api->get('/users');
my $rate = $response->rate_limit;

say $rate->limit       if defined $rate->limit;
say $rate->remaining   if defined $rate->remaining;
say $rate->resource    if defined $rate->resource;
say $rate->wait_seconds if $rate->exhausted;
```

`HTTP::API::Client::RateLimit` understands numeric `RateLimit-Limit`, `RateLimit-Remaining`, and `RateLimit-Reset` fields as well as the widely-used `X-RateLimit-*` family and `Retry-After`. `X-RateLimit-Reset` is treated as a UTC epoch timestamp; `RateLimit-Reset` is treated as a delay in seconds.

HTTP errors expose the same object through `$error->rate_limit`.

For exhausted quotas, `Retry-After` remains the first choice. When it is absent, retry handling can fall back to reset metadata. A `403` is only treated as a rate-limit retry when the response explicitly reports `remaining == 0`; ordinary authorization failures are not retried.

## Pagination

`paginate` returns an iterator with `next` and `all`. All pagination styles use the same API.

### Next URL

```perl
my $pager = $api->paginate(
    '/users',
    mode  => 'next_url',
    items => 'data.users',
    next  => 'links.next',
);

while (my $user = $pager->next) {
    ...
}
```

The `next` value may be an absolute URL or a path relative to `base_url`.

### Page number

```perl
my $pager = $api->paginate(
    '/users',
    mode      => 'page',
    items     => 'users',
    page_size => 100,
);

my @users = $pager->all;
```

The defaults are `page` for the page parameter and `per_page` for the page-size parameter. Override them with `page_param` and `page_size_param`. If the response exposes an explicit boolean, use `has_more => 'meta.has_more'`.

### Cursor

```perl
my $pager = $api->paginate(
    '/users',
    mode   => 'cursor',
    items  => 'data.users',
    next   => 'meta.next_cursor',
    query  => { limit => 100 },
);
```

The default cursor parameter is `cursor`; override it with `cursor_param`.

Extractor values such as `data.users` and `meta.next_cursor` are dotted paths. A coderef can also be supplied when an API needs custom extraction logic.

Repeated next URLs/cursors are detected and rejected rather than looping forever.

## Retry policy

Retries are intentionally conservative. By default only `GET`, `HEAD`, `PUT`, `DELETE`, and `OPTIONS` are retried. `POST` and `PATCH` are not automatically repeated because doing so can duplicate side effects.

Retryable failures include transport errors, HTTP `408`, `425`, `429`, `5xx`, and exhausted-quota `403` responses. Delays use exponential backoff with jitter. A numeric `Retry-After` header takes precedence; exhausted rate-limit reset metadata is used as a fallback.

```perl
$api->get('/status', retry => 0);

$api->post('/jobs',
    json => { task => 'sync' },
    retry => {
        attempts => 2,
        methods  => ['POST'],
    },
);
```

## Features

- base URL handling
- default and per-request headers
- JSON request encoding and response decoding
- configurable timeout
- structured transport/HTTP/encode/decode errors
- request ID extraction
- automatic retry with exponential backoff + jitter
- normalized rate-limit metadata and reset-aware retry fallback
- next-URL, page-number, and cursor pagination
- client-level and per-request lifecycle hooks
- injectable transport for tests and custom integration

## Planned

Additional API-client ergonomics.

## License

Same terms as Perl itself.
