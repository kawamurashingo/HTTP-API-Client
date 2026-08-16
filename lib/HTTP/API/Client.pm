package HTTP::API::Client;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(encode_json);
use Scalar::Util qw(blessed);
use Time::HiRes qw(sleep time);

use HTTP::API::Client::Response;
use HTTP::API::Client::Error;
use HTTP::API::Client::Pagination;

our $VERSION = '0.09';

sub new {
    my ($class, %args) = @_;

    my $base_url = delete $args{base_url};
    die "base_url is required\n" if !defined($base_url) || $base_url eq '';
    $base_url =~ s{/+\z}{};

    my $headers = delete($args{headers}) || {};
    die "headers must be a hash reference\n" if ref($headers) ne 'HASH';

    my $timeout = exists $args{timeout} ? delete($args{timeout}) : 10;
    die "timeout must be a positive number\n" if !defined($timeout) || $timeout !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ || $timeout <= 0;

    my $transport = delete $args{transport};
    die "transport must be a code reference\n" if defined($transport) && ref($transport) ne 'CODE';

    my $retry = exists $args{retry} ? delete($args{retry}) : {};
    die "retry must be a hash reference\n" if ref($retry) ne 'HASH';
    $retry = _normalize_retry($retry);

    my $hooks = exists $args{hooks} ? delete($args{hooks}) : {};
    $hooks = _normalize_hooks($hooks);

    die "unknown constructor option: $_\n" for sort keys %args;

    my $self = bless {
        base_url  => $base_url,
        headers   => { %$headers },
        timeout   => $timeout,
        transport => $transport,
        retry     => $retry,
        hooks     => $hooks,
    }, $class;

    $self->{http} = HTTP::Tiny->new(timeout => $timeout) if !$transport;
    return $self;
}

sub base_url { $_[0]->{base_url} }
sub timeout  { $_[0]->{timeout} }
sub retry    { +{ %{ $_[0]->{retry} }, methods => [ @{ $_[0]->{retry}{methods} } ] } }
sub hooks    { _clone_hooks($_[0]->{hooks}) }

sub get    { my ($self, $path, %opts) = @_; return $self->request('GET',    $path, %opts) }
sub post   { my ($self, $path, %opts) = @_; return $self->request('POST',   $path, %opts) }
sub put    { my ($self, $path, %opts) = @_; return $self->request('PUT',    $path, %opts) }
sub patch  { my ($self, $path, %opts) = @_; return $self->request('PATCH',  $path, %opts) }
sub delete { my ($self, $path, %opts) = @_; return $self->request('DELETE', $path, %opts) }

sub paginate {
    my ($self, $path, %opts) = @_;
    return HTTP::API::Client::Pagination->new(client => $self, path => $path, %opts);
}

sub request {
    my ($self, $method, $path, %opts) = @_;
    $method = uc($method // '');
    die "method is required\n" if $method eq '';
    die "path is required\n" if !defined $path;

    my $url = $path =~ m{\Ahttps?://} ? $path : $self->_join_url($path);

    my $query = exists $opts{query} ? delete($opts{query}) : {};
    die "query must be a hash reference\n" if ref($query) ne 'HASH';
    $url = _append_query($url, $query);

    my %headers = (%{ $self->{headers} }, %{ delete($opts{headers}) || {} });
    my $content;

    if (exists $opts{json}) {
        my $value = delete $opts{json};
        $content = eval { encode_json($value) };
        if ($@) {
            die HTTP::API::Client::Error->new(
                category => 'encode',
                method   => $method,
                url      => $url,
                message  => "failed to encode JSON request: $@",
            );
        }
        $headers{'content-type'} ||= 'application/json';
        $headers{'accept'}       ||= 'application/json';
    }
    elsif (exists $opts{content}) {
        $content = delete $opts{content};
    }

    my $retry = exists $opts{retry} ? delete($opts{retry}) : $self->{retry};
    if (ref($retry) eq 'HASH' && $retry != $self->{retry}) {
        $retry = _normalize_retry($retry);
    }
    elsif (!ref($retry)) {
        $retry = $retry ? $self->{retry} : _normalize_retry({ attempts => 1 });
    }

    my $request_hooks = exists $opts{hooks} ? _normalize_hooks(delete($opts{hooks})) : {};
    my $hooks = _merge_hooks($self->{hooks}, $request_hooks);

    die "unknown request option: $_\n" for sort keys %opts;

    my $attempts = _method_is_retryable($method, $retry) ? $retry->{attempts} : 1;
    my $attempt = 0;

    while (++$attempt <= $attempts) {
        my $context = {
            method  => $method,
            url     => $url,
            headers => { %headers },
            content => $content,
            attempt => $attempt,
        };

        my $hook_error = _run_hooks($hooks->{before_request}, $context);
        die _hook_error($hook_error, $method, $url) if $hook_error;

        my $started_at = time;
        $context->{started_at} = $started_at;

        my ($response, $error, $elapsed) = $self->_request_once(
            $context->{method},
            $context->{url},
            $context->{headers},
            $context->{content},
        );

        $context->{elapsed} = $elapsed;
        $context->{request_id} = $response
            ? $response->request_id
            : $error ? $error->request_id : undef;

        if ($response) {
            my $after_error = _run_hooks($hooks->{after_response}, $response, $context);
            die _hook_error($after_error, $context->{method}, $context->{url}) if $after_error;
            return $response;
        }

        my $on_error_error = _run_hooks($hooks->{on_error}, $error, $context);
        die _hook_error($on_error_error, $context->{method}, $context->{url}) if $on_error_error;

        die $error if $attempt >= $attempts || !$error->retryable;

        my $delay = _retry_delay($retry, $attempt, $error);
        sleep($delay) if $delay > 0;
    }

    die "unreachable retry state\n";
}

sub _request_once {
    my ($self, $method, $url, $headers, $content) = @_;
    my $raw;
    my $started_at = time;

    eval {
        if ($self->{transport}) {
            $raw = $self->{transport}->($method, $url, {
                headers => $headers,
                (defined($content) ? (content => $content) : ()),
            });
        }
        else {
            $raw = $self->{http}->request($method, $url, {
                headers => $headers,
                (defined($content) ? (content => $content) : ()),
            });
        }
        1;
    } or do {
        my $cause = $@;
        return (undef, $cause, time - $started_at) if blessed($cause) && $cause->isa('HTTP::API::Client::Error');
        my $elapsed = time - $started_at;
        return (undef, HTTP::API::Client::Error->new(
            category  => 'transport',
            method    => $method,
            url       => $url,
            retryable => 1,
            elapsed   => $elapsed,
            message   => "HTTP transport failed: $cause",
        ), $elapsed);
    };

    if (ref($raw) ne 'HASH' || !exists $raw->{status}) {
        my $elapsed = time - $started_at;
        return (undef, HTTP::API::Client::Error->new(
            category => 'transport', method => $method, url => $url,
            retryable => 1,
            elapsed => $elapsed,
            message => 'HTTP transport returned an invalid response',
        ), $elapsed);
    }

    my $elapsed = time - $started_at;
    my $response = HTTP::API::Client::Response->new(
        status  => 0 + $raw->{status},
        reason  => $raw->{reason},
        headers => $raw->{headers} || {},
        content => defined($raw->{content}) ? $raw->{content} : '',
        method  => $method,
        url     => $url,
        elapsed => $elapsed,
    );

    return ($response, undef, $elapsed) if $response->is_success;

    my $rate_limit = $response->rate_limit;
    my $rate_limited = ($response->status == 403 || $response->status == 429)
        && $rate_limit->exhausted;

    return (undef, HTTP::API::Client::Error->new(
        category    => 'http',
        status      => $response->status,
        method      => $method,
        url         => $url,
        retryable   => _retryable_status($response->status) || $rate_limited,
        retry_after => $response->header('retry-after'),
        request_id  => $response->request_id,
        elapsed     => $elapsed,
        response    => $response,
        message     => sprintf('HTTP %d%s', $response->status, defined($response->reason) && length($response->reason) ? ' ' . $response->reason : ''),
    ), $elapsed);
}

sub _normalize_hooks {
    my ($hooks) = @_;
    $hooks = {} if !defined $hooks;
    die "hooks must be a hash reference\n" if ref($hooks) ne 'HASH';

    my %copy = %$hooks;
    my %normalized;
    for my $name (qw(before_request after_response on_error)) {
        my $value = delete $copy{$name};
        next if !defined $value;

        my @callbacks = ref($value) eq 'ARRAY' ? @$value : ($value);
        die "hook $name must be a code reference or array reference of code references\n"
            if grep { ref($_) ne 'CODE' } @callbacks;
        $normalized{$name} = \@callbacks;
    }

    die "unknown hook: $_\n" for sort keys %copy;
    return \%normalized;
}

sub _clone_hooks {
    my ($hooks) = @_;
    return {
        map { $_ => [ @{ $hooks->{$_} || [] } ] }
        qw(before_request after_response on_error)
    };
}

sub _merge_hooks {
    my ($first, $second) = @_;
    return {
        map {
            $_ => [
                @{ $first->{$_} || [] },
                @{ $second->{$_} || [] },
            ]
        } qw(before_request after_response on_error)
    };
}

sub _run_hooks {
    my ($callbacks, @args) = @_;
    for my $callback (@{ $callbacks || [] }) {
        my $ok = eval { $callback->(@args); 1 };
        return $@ if !$ok;
    }
    return undef;
}

sub _hook_error {
    my ($cause, $method, $url) = @_;
    return $cause if blessed($cause) && $cause->isa('HTTP::API::Client::Error');
    return HTTP::API::Client::Error->new(
        category  => 'hook',
        method    => $method,
        url       => $url,
        retryable => 0,
        message   => "HTTP API client hook failed: $cause",
    );
}

sub _normalize_retry {
    my ($retry) = @_;
    my %copy = %$retry;

    my $attempts = exists $copy{attempts} ? delete($copy{attempts}) : 3;
    die "retry attempts must be a positive integer\n" if $attempts !~ /\A\d+\z/ || $attempts < 1;

    my $base_delay = exists $copy{base_delay} ? delete($copy{base_delay}) : 0.25;
    die "retry base_delay must be a non-negative number\n" if !_non_negative_number($base_delay);

    my $max_delay = exists $copy{max_delay} ? delete($copy{max_delay}) : 5;
    die "retry max_delay must be a non-negative number\n" if !_non_negative_number($max_delay);

    my $jitter = exists $copy{jitter} ? delete($copy{jitter}) : 1;
    $jitter = $jitter ? 1 : 0;

    my $methods = exists $copy{methods} ? delete($copy{methods}) : [qw(GET HEAD PUT DELETE OPTIONS)];
    die "retry methods must be an array reference\n" if ref($methods) ne 'ARRAY';
    my @methods = map { uc($_ // '') } @$methods;
    die "retry methods must not contain empty values\n" if grep { $_ eq '' } @methods;

    die "unknown retry option: $_\n" for sort keys %copy;

    return {
        attempts   => 0 + $attempts,
        base_delay => 0 + $base_delay,
        max_delay  => 0 + $max_delay,
        jitter     => $jitter,
        methods    => \@methods,
    };
}

sub _method_is_retryable {
    my ($method, $retry) = @_;
    my %allowed = map { $_ => 1 } @{ $retry->{methods} };
    return $allowed{$method} ? 1 : 0;
}

sub _retry_delay {
    my ($retry, $attempt, $error) = @_;

    my $retry_after = $error->retry_after;
    if (defined($retry_after) && $retry_after =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/) {
        return 0 + $retry_after;
    }

    my $rate_limit = $error->rate_limit;
    if ($rate_limit && $rate_limit->exhausted) {
        my $wait = $rate_limit->wait_seconds;
        return $wait if defined $wait;
    }

    my $delay = $retry->{base_delay} * (2 ** ($attempt - 1));
    $delay = $retry->{max_delay} if $delay > $retry->{max_delay};
    $delay = rand($delay) if $retry->{jitter} && $delay > 0;
    return $delay;
}

sub _append_query {
    my ($url, $query) = @_;
    my @pairs;

    for my $key (sort keys %$query) {
        my $value = $query->{$key};
        next if !defined $value;

        my @values;
        if (ref($value) eq 'ARRAY') {
            @values = grep { defined $_ } @$value;
        }
        elsif (ref($value)) {
            die "query values must be scalars, array references, or undef\n";
        }
        else {
            @values = ($value);
        }

        push @pairs, map { _uri_escape($key) . '=' . _uri_escape($_) } @values;
    }

    return $url if !@pairs;

    my $fragment = '';
    if ($url =~ s/(#.*)\z//) {
        $fragment = $1;
    }

    my $separator = index($url, '?') >= 0 ? '&' : '?';
    $separator = '' if $url =~ /[?&]\z/;
    return $url . $separator . join('&', @pairs) . $fragment;
}

sub _uri_escape {
    my ($value) = @_;
    my $bytes = encode('UTF-8', "$value");
    $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}

sub _retryable_status {
    my ($status) = @_;
    return 1 if $status == 408 || $status == 425 || $status == 429;
    return 1 if $status >= 500 && $status <= 599;
    return 0;
}

sub _non_negative_number {
    my ($value) = @_;
    return defined($value) && $value =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ && $value >= 0;
}

sub _join_url {
    my ($self, $path) = @_;
    return $self->{base_url} if $path eq '';
    return $self->{base_url} . ($path =~ m{\A/} ? $path : "/$path");
}

1;

__END__

=head1 NAME

HTTP::API::Client - Small foundation for HTTP JSON API clients

=head1 SYNOPSIS

    use HTTP::API::Client;

    my $api = HTTP::API::Client->new(
        base_url => 'https://api.example.com',
        headers  => { authorization => 'Bearer token' },
        timeout  => 5,
        retry    => { attempts => 3 },
    );

    my $response = $api->get('/users/42');
    my $user = $response->json;

=head1 DESCRIPTION

HTTP::API::Client is a small foundation for building HTTP JSON API clients. It
provides base URL handling, default headers, JSON request/response helpers,
timeout configuration, structured errors, conservative retries,
pagination helpers, normalized rate-limit metadata, and request observability.

=head1 RETRIES

Retries are enabled for GET, HEAD, PUT, DELETE, and OPTIONS by default. POST and
PATCH are not retried unless explicitly added to the retry C<methods> list.
Retryable failures include transport errors, HTTP 408, 425, 429, 5xx, and
exhausted-quota 403 responses. Numeric C<Retry-After> values take precedence;
rate-limit reset metadata is used as a fallback before exponential backoff.

=head1 PAGINATION

Use C<paginate> to create a lazy iterator. The iterator supports C<next_url>,
C<page>, and C<cursor> modes with dotted-path or coderef extractors.

=head1 RATE LIMITS

Responses and HTTP errors expose normalized rate-limit metadata via
C<rate_limit>. Numeric C<Retry-After> values are preferred for retry delays,
with rate-limit reset metadata used as a fallback for exhausted quotas.

=head1 HOOKS

Lifecycle hooks can be configured with C<hooks> at construction time or per
request. Supported hooks are C<before_request>, C<after_response>, and
C<on_error>. Client-level hooks run before per-request hooks. Hooks run once per
attempt, including retries. C<before_request> receives a mutable request context;
C<after_response> receives the response and context; C<on_error> receives the
error and context. Hook failures are wrapped as non-retryable C<hook> errors.

=head1 OBSERVABILITY

Responses expose C<elapsed> transport time and C<request_id>. Lifecycle hook
contexts receive C<started_at>, C<elapsed>, and C<request_id> for each attempt.
The core deliberately does not select a logging, metrics, tracing, or telemetry
backend.

=head1 QUERY PARAMETERS

Pass C<query =E<gt> \%params> to any request method. Scalar values produce one
key/value pair, array references produce repeated keys, and undefined values are
omitted. Existing query strings and URL fragments are preserved.

=head1 LICENSE

Same terms as Perl itself.
