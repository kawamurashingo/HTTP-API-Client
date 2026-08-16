# Authentication helpers

`HTTP::API::Client::Auth` provides small `before_request` hook helpers for authentication schemes commonly used by HTTP APIs.

The design deliberately builds on the existing lifecycle-hook mechanism instead of adding service-specific authentication state to the client core.

## Bearer tokens

```perl
use HTTP::API::Client;
use HTTP::API::Client::Auth qw(bearer_auth);

my $api = HTTP::API::Client->new(
    base_url => 'https://api.example.com',
    hooks => {
        before_request => bearer_auth($token),
    },
);
```

## Basic authentication

```perl
use HTTP::API::Client::Auth qw(basic_auth);

hooks => {
    before_request => basic_auth($username, $password),
}
```

## API keys

Header API key (default):

```perl
use HTTP::API::Client::Auth qw(api_key_auth);

hooks => {
    before_request => api_key_auth(
        name  => 'X-API-Key',
        value => $key,
    ),
}
```

Query parameter API key:

```perl
hooks => {
    before_request => api_key_auth(
        in    => 'query',
        name  => 'api_key',
        value => $key,
    ),
}
```

Explicit request headers take precedence over auth helpers. Query-key helpers also avoid adding the configured key when the URL already contains that parameter.

## Non-goals

OAuth token acquisition, refresh flows, browser authorization flows, and service-specific signing schemes remain outside the core. They can be implemented by separate modules using the same hook mechanism.
