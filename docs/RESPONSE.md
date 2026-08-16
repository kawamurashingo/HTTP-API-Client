# Response API

`HTTP::API::Client::Response` keeps response handling explicit and predictable.

## Body access

```perl
my $response = $api->get('/users');

$response->content;      # raw response body
$response->text;         # alias for content
$response->has_content;  # raw body has non-zero length
$response->json;         # explicit JSON decoding
```

`text` does not perform charset transcoding. It is deliberately an alias for the raw response body so the core does not guess an encoding policy.

`json` is explicit and does not depend on the `Content-Type` header. Empty or whitespace-only bodies return `undef`. Invalid non-empty JSON throws the existing structured `decode` error and retains a reference to the response.

This makes `204 No Content` and APIs that return an empty successful body straightforward without weakening error handling for malformed non-empty JSON.

## Content type

```perl
$response->content_type;
$response->is_json;
```

`content_type` returns the lower-cased media type and strips parameters such as `charset`:

```text
Application/JSON; charset=utf-8
        ->
application/json
```

`is_json` recognizes both `application/json` and structured syntax suffix media types such as `application/problem+json`.

The Content-Type helpers are informational. Calling `json` still attempts JSON decoding when the caller explicitly asks for it, even if the header is missing or incorrect.

## Metadata

The response object also exposes:

- `status`
- `reason`
- `headers`
- `header($name)`
- `method`
- `url`
- `elapsed`
- `request_id`
- `rate_limit`

`headers` returns a copy rather than the internal hash so callers cannot accidentally mutate response state.

## Design principle

The response API should provide small, transport-independent primitives. It should not automatically deserialize based on Content-Type, perform charset conversion, or introduce a separate content-negotiation framework.
