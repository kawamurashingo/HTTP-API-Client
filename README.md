# HTTP::API::Client

A small, dependency-light foundation for building JSON HTTP API clients in Perl.

The goal is not to replace `HTTP::Tiny`, `LWP`, or `Mojo::UserAgent`. It adds the API-client layer applications repeatedly rebuild: base URLs, JSON request/response handling, default headers, timeout configuration, and structured errors.

## Example

```perl
use HTTP::API::Client;

my $api = HTTP::API::Client->new(
    base_url => 'https://api.example.com',
    headers  => {
        Authorization => "Bearer $ENV{API_TOKEN}",
    },
    timeout => 10,
);

my $response = $api->get('/users');
my $data = $response->json;
```

## v0.01 scope

- base URL handling
- default and per-request headers
- JSON request encoding
- JSON response decoding
- configurable timeout
- structured transport/HTTP/decode errors
- extraction of `Retry-After` and common request-ID headers
- injectable transport for tests and custom integration

## Planned

Retry with exponential backoff + jitter, pagination, rate-limit policy, and middleware/hooks.

## License

Same terms as Perl itself.
