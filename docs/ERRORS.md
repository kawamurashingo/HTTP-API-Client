# Error model

`HTTP::API::Client` uses `HTTP::API::Client::Error` objects for failures that cross the public client API boundary.

## Stable categories

The `category` method is the machine-readable classification:

| Category | Meaning |
| --- | --- |
| `encode` | JSON request encoding failed |
| `decode` | Explicit JSON response decoding failed |
| `transport` | The HTTP transport failed or returned an invalid transport response |
| `http` | The server returned a non-success HTTP status |
| `hook` | A lifecycle hook failed |

Code should branch on `category`, status, and other structured fields rather than parsing `message`. Exact human-readable message wording is not a compatibility guarantee.

## HTTP errors

HTTP errors retain the associated response:

```perl
eval {
    $api->get('/users/404');
};

if (my $error = $@) {
    if ($error->category eq 'http') {
        say $error->status;
        say $error->body;
        say $error->header('content-type');
        my $payload = $error->json;
    }
}
```

`body` and `text` expose the response body. `headers` returns a defensive copy. `json` delegates to the response object's explicit JSON decoding semantics.

## Errors without responses

Transport, encode, and hook failures may not have an HTTP response. In that case `response`, `body`, `text`, `header`, and `json` return `undef`, while `headers` returns an empty hash reference.

## Compatibility

These semantics are covered by regression tests and are the intended public error contract on the path to 1.0. `DESIGN.md` remains the source of truth for the project's compatibility direction.
