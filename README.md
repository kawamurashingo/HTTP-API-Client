# HTTP::API::Client

A small, dependency-light foundation for building JSON HTTP API clients in Perl.

The goal is not to replace `HTTP::Tiny`, `LWP`, or `Mojo::UserAgent`. It adds the API-client layer applications repeatedly rebuild: base URLs, JSON request/response handling, default headers, timeout configuration, structured errors, and conservative retries.

## Example

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

## Retry policy

Retries are intentionally conservative. By default only `GET`, `HEAD`, `PUT`, `DELETE`, and `OPTIONS` are retried. `POST` and `PATCH` are not automatically repeated because doing so can duplicate side effects.

Retryable failures include transport errors, HTTP `408`, `425`, `429`, and `5xx` responses. Delays use exponential backoff with jitter. A numeric `Retry-After` header takes precedence over the calculated delay.

```perl
# Disable retry for one request.
$api->get('/status', retry => 0);

# Explicitly opt POST into retry when the endpoint is known to be idempotent.
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
- JSON request encoding
- JSON response decoding
- configurable timeout
- structured transport/HTTP/encode/decode errors
- request ID and `Retry-After` extraction
- automatic retry with exponential backoff + jitter
- injectable transport for tests and custom integration

## Planned

Pagination, richer rate-limit policy, and middleware/hooks.

## License

Same terms as Perl itself.
