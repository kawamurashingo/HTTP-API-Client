package HTTP::API::Client;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(encode_json);
use Scalar::Util qw(blessed);
use Time::HiRes qw(sleep);

use HTTP::API::Client::Response;
use HTTP::API::Client::Error;
use HTTP::API::Client::Pagination;

our $VERSION = '0.04';

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

    die "unknown constructor option: $_\n" for sort keys %args;

    my $self = bless {
        base_url  => $base_url,
        headers   => { %$headers },
        timeout   => $timeout,
        transport => $transport,
        retry     => $retry,
    }, $class;

    $self->{http} = HTTP::Tiny->new(timeout => $timeout) if !$transport;
    return $self;
}

sub base_url { $_[0]->{base_url} }
sub timeout  { $_[0]->{timeout} }
sub retry    { +{ %{ $_[0]->{retry} }, methods => [ @{ $_[0]->{retry}{methods} } ] } }

sub get    { my ($self, $path, %opts) = @_; return $self->request('GET',    $path, %opts) }
sub post   { my ($self, $path, %opts) = @_; return $self->request('POST',   $path, %opts) }
sub put    { my ($self, $path, %opts) = @_; return $self->request('PUT',    $path, %opts) }
sub patch  { my ($self, $path, %opts) = @_; return $self->request('PATCH',  $path, %opts) }
sub delete { my ($self, $path, %opts) = @_; return $self->request('DELETE', $path, %opts) }

sub paginate {
    my ($self, $path, %opts) = @_;
    return HTTP::API::Client::Pagination->new(
        client => $self,
        path   => $path,
        %opts,
    );
}

sub request {
    my ($self, $method, $path, %opts) = @_;
    $method = uc($method // '');
    die "method is required\n" if $method eq '';
    die "path is required\n" if !defined $path;

    my $url = $path =~ m{\Ahttps?://} ? $path : $self->_join_url($path);

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

    die "unknown request option: $_\n" for sort keys %opts;

    my $attempts = _method_is_retryable($method, $retry) ? $retry->{attempts} : 1;
    my $attempt = 0;

    while (++$attempt <= $attempts) {
        my ($response, $error) = $self->_request_once($method, $url, \%headers, $content);
        return $response if $response;

        die $error if $attempt >= $attempts || !$error->retryable;

        my $delay = _retry_delay($retry, $attempt, $error);
        sleep($delay) if $delay > 0;
    }

    die "unreachable retry state\n";
}

sub _request_once {
    my ($self, $method, $url, $headers, $content) = @_;
    my $raw;

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
        return (undef, $cause) if blessed($cause) && $cause->isa('HTTP::API::Client::Error');
        return (undef, HTTP::API::Client::Error->new(
            category  => 'transport',
            method    => $method,
            url       => $url,
            retryable => 1,
            message   => "HTTP transport failed: $cause",
        ));
    };

    if (ref($raw) ne 'HASH' || !exists $raw->{status}) {
        return (undef, HTTP::API::Client::Error->new(
            category => 'transport', method => $method, url => $url,
            retryable => 1,
            message => 'HTTP transport returned an invalid response',
        ));
    }

    my $response = HTTP::API::Client::Response->new(
        status  => 0 + $raw->{status},
        reason  => $raw->{reason},
        headers => $raw->{headers} || {},
        content => defined($raw->{content}) ? $raw->{content} : '',
        method  => $method,
        url     => $url,
    );

    return ($response, undef) if $response->is_success;

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
        request_id  => _request_id($response),
        response    => $response,
        message     => sprintf('HTTP %d%s', $response->status, defined($response->reason) && length($response->reason) ? ' ' . $response->reason : ''),
    ));
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

sub _non_negative_number {
    my ($value) = @_;
    return defined($value) && $value =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ && $value >= 0;
}

sub _join_url {
    my ($self, $path) = @_;
    $path =~ s{\A/+}{};
    return $self->{base_url} . '/' . $path;
}

sub _retryable_status {
    my ($status) = @_;
    return 1 if $status == 408 || $status == 425 || $status == 429;
    return 1 if $status >= 500 && $status <= 599;
    return 0;
}

sub _request_id {
    my ($response) = @_;
    for my $name (qw(x-request-id request-id x-correlation-id)) {
        my $value = $response->header($name);
        return $value if defined $value && length $value;
    }
    return undef;
}

1;

__END__

=head1 NAME

HTTP::API::Client - Small foundation for JSON HTTP API clients

=head1 SYNOPSIS

  use HTTP::API::Client;

  my $api = HTTP::API::Client->new(
      base_url => 'https://api.example.com',
      headers  => { Authorization => "Bearer $token" },
      timeout  => 10,
      retry    => {
          attempts   => 3,
          base_delay => 0.25,
          max_delay  => 5,
          jitter     => 1,
      },
  );

  my $response = $api->get('/users');
  my $users = $response->json;
  my $rate = $response->rate_limit;

  my $pager = $api->paginate(
      '/users',
      mode  => 'cursor',
      items => 'data.users',
      next  => 'meta.next_cursor',
  );

  while (my $user = $pager->next) {
      ...
  }

=head1 DESCRIPTION

HTTP::API::Client is a deliberately small base layer for building HTTP API
clients. It provides base URL handling, default headers, JSON request/response
helpers, timeout configuration, structured errors, conservative retries,
pagination helpers, and normalized rate-limit metadata.

Retry is enabled by default for GET, HEAD, PUT, DELETE, and OPTIONS. POST and
PATCH are not retried automatically. Retryable failures include transport
errors, HTTP 408, 425, 429, 5xx responses, and 403 responses that explicitly
report an exhausted rate limit.

=head1 METHODS

=head2 new

  my $api = HTTP::API::Client->new(
      base_url => 'https://api.example.com',
      headers  => { ... },
      timeout  => 10,
      retry    => { attempts => 3 },
  );

C<base_url> is required. C<headers>, C<timeout>, and C<retry> are optional.
Retry defaults to three attempts with exponential backoff and jitter.

=head2 get, post, put, patch, delete

Convenience methods around C<request>.

=head2 paginate

  my $pager = $api->paginate(
      '/users',
      mode  => 'next_url',
      items => 'data.items',
      next  => 'links.next',
  );

Returns an L<HTTP::API::Client::Pagination> iterator. Supported modes are
C<next_url>, C<page>, and C<cursor>.

=head2 request

  my $response = $api->request('POST', '/items', json => { ... });

Pass C<json> to encode a Perl value as JSON, or C<content> to send raw content.
Per-request C<headers> override default headers. Pass C<retry =E<gt> 0> to
disable retry for one request, or a retry hash to override the policy.

Non-2xx responses throw L<HTTP::API::Client::Error> after retry is exhausted.
Successful responses expose normalized rate-limit metadata through
C<$response-E<gt>rate_limit>.

=head1 RETRY POLICY

The retry hash accepts C<attempts>, C<base_delay>, C<max_delay>, C<jitter>, and
C<methods>. Exponential backoff is capped by C<max_delay>. A numeric
C<Retry-After> response header takes precedence over the calculated delay.
When a 403 or 429 response reports an exhausted quota, C<RateLimit-Reset> or
C<X-RateLimit-Reset> is used as a fallback delay when available.

=head1 RATE LIMITS

L<HTTP::API::Client::RateLimit> normalizes C<RateLimit-*>, C<X-RateLimit-*>,
and C<Retry-After> response headers. It exposes C<limit>, C<remaining>,
C<used>, C<resource>, reset metadata, C<exhausted>, and C<wait_seconds>.

=head1 ERROR HANDLING

Errors expose stable fields such as C<category>, C<status>, C<method>, C<url>,
C<retryable>, C<retry_after>, C<request_id>, and C<rate_limit>. Exact error
message wording is not intended as a machine-readable API.

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl itself.

=cut
