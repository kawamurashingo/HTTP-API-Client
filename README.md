# HTTP::API::Client

A small, dependency-light foundation for building JSON HTTP API clients in Perl.

The goal is not to replace `HTTP::Tiny`, `LWP`, or `Mojo::UserAgent`. It adds the API-client layer applications repeatedly rebuild: base URLs, JSON request/response handling, default headers, timeout configuration, structured errors, conservative retries, and pagination.

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

Retryable failures include transport errors, HTTP `408`, `425`, `429`, and `5xx` responses. Delays use exponential backoff with jitter. A numeric `Retry-After` header takes precedence over the calculated delay.

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
- request ID and `Retry-After` extraction
- automatic retry with exponential backoff + jitter
- next-URL, page-number, and cursor pagination
- injectable transport for tests and custom integration

## Planned

Richer rate-limit policy and middleware/hooks.

## License

Same terms as Perl itself.
