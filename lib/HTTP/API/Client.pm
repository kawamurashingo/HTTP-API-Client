package HTTP::API::Client;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(encode_json decode_json);
use Scalar::Util qw(blessed);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    die "base_url is required\n" unless defined $args{base_url} && length $args{base_url};

    my $base_url = $args{base_url};
    $base_url =~ s{/$}{};

    my $self = bless {
        base_url  => $base_url,
        headers   => $args{headers} || {},
        timeout   => defined $args{timeout} ? $args{timeout} : 30,
        transport => $args{transport},
    }, $class;

    return $self;
}

sub base_url { $_[0]->{base_url} }
sub timeout  { $_[0]->{timeout} }

sub get    { my ($self, $path, %opts) = @_; return $self->request('GET',    $path, %opts) }
sub post   { my ($self, $path, %opts) = @_; return $self->request('POST',   $path, %opts) }
sub put    { my ($self, $path, %opts) = @_; return $self->request('PUT',    $path, %opts) }
sub patch  { my ($self, $path, %opts) = @_; return $self->request('PATCH',  $path, %opts) }
sub delete { my ($self, $path, %opts) = @_; return $self->request('DELETE', $path, %opts) }

sub request {
    my ($self, $method, $path, %opts) = @_;

    my $url = $path =~ m{^https?://} ? $path : $self->{base_url} . ($path =~ m{^/} ? '' : '/') . $path;
    my %headers = (%{ $self->{headers} }, %{ $opts{headers} || {} });

    my $content;
    if (exists $opts{json}) {
        eval { $content = encode_json($opts{json}); 1 } or do {
            my $err = $@;
            die HTTP::API::Client::Error->new(
                category => 'encode',
                message  => "JSON encode failure: $err",
                method   => $method,
                url      => $url,
            );
        };
        $headers{'content-type'} ||= 'application/json';
    }
    elsif (exists $opts{content}) {
        $content = $opts{content};
    }

    my $transport = $self->{transport};
    my $raw;

    if ($transport) {
        my $call = ref($transport) eq 'CODE' ? $transport : $transport->can('request');
        if (!$call) {
            die HTTP::API::Client::Error->new(
                category => 'transport',
                message  => 'Invalid transport: expected coderef or object with request()',
                method   => $method,
                url      => $url,
            );
        }

        eval {
            if (ref($transport) eq 'CODE') {
                $raw = $transport->($method, $url, { headers => \%headers, content => $content });
            }
            else {
                $raw = $transport->request($method, $url, { headers => \%headers, content => $content });
            }
            1;
        } or do {
            my $err = $@;
            die $err if blessed($err) && $err->isa('HTTP::API::Client::Error');
            die HTTP::API::Client::Error->new(
                category => 'transport',
                message  => "Transport failure: $err",
                method   => $method,
                url      => $url,
            );
        };
    }
    else {
        my $http = HTTP::Tiny->new(timeout => $self->{timeout});
        eval {
            $raw = $http->request($method, $url, {
                headers => \%headers,
                (defined $content ? (content => $content) : ()),
            });
            1;
        } or do {
            my $err = $@;
            die HTTP::API::Client::Error->new(
                category => 'transport',
                message  => "Transport failure: $err",
                method   => $method,
                url      => $url,
            );
        };
    }

    my $response = HTTP::API::Client::Response->new(
        status  => $raw->{status},
        reason  => $raw->{reason},
        headers => $raw->{headers} || {},
        content => defined $raw->{content} ? $raw->{content} : '',
        method  => $method,
        url     => $url,
    );

    return $response if $response->is_success;

    my $request_id = $response->header('x-request-id')
                  || $response->header('request-id')
                  || $response->header('x-correlation-id');

    die HTTP::API::Client::Error->new(
        category    => 'http',
        message     => sprintf('HTTP %s%s', $response->status // 'error', $response->reason ? ' ' . $response->reason : ''),
        status      => $response->status,
        method      => $method,
        url         => $url,
        request_id  => $request_id,
        retry_after => $response->header('retry-after'),
        response    => $response,
    );
}

package HTTP::API::Client::Response;

use strict;
use warnings;
use JSON::PP qw(decode_json);

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub status  { $_[0]->{status} }
sub reason  { $_[0]->{reason} }
sub headers { $_[0]->{headers} }
sub content { $_[0]->{content} }
sub method  { $_[0]->{method} }
sub url     { $_[0]->{url} }

sub is_success {
    my ($self) = @_;
    return defined($self->{status}) && $self->{status} >= 200 && $self->{status} < 300;
}

sub header {
    my ($self, $name) = @_;
    my $headers = $self->{headers} || {};
    my $needle = lc $name;
    for my $key (keys %$headers) {
        return $headers->{$key} if lc($key) eq $needle;
    }
    return undef;
}

sub json {
    my ($self) = @_;
    return undef if !defined($self->{content}) || $self->{content} eq '';

    my $decoded;
    eval {
        $decoded = decode_json($self->{content});
        1;
    } or do {
        my $err = $@;
        die HTTP::API::Client::Error->new(
            category => 'decode',
            message  => "JSON decode failure: $err",
            status   => $self->{status},
            method   => $self->{method},
            url      => $self->{url},
            response => $self,
        );
    };

    return $decoded;
}

package HTTP::API::Client::Error;

use strict;
use warnings;
use overload '""' => sub { $_[0]->{message} }, fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub message     { $_[0]->{message} }
sub category    { $_[0]->{category} }
sub status      { $_[0]->{status} }
sub method      { $_[0]->{method} }
sub url         { $_[0]->{url} }
sub request_id  { $_[0]->{request_id} }
sub retry_after { $_[0]->{retry_after} }
sub response    { $_[0]->{response} }

sub retryable {
    my ($self) = @_;
    return 1 if $self->{category} eq 'transport';
    return 0 unless defined $self->{status};
    return 1 if $self->{status} == 429;
    return 1 if $self->{status} == 502 || $self->{status} == 503 || $self->{status} == 504;
    return 0;
}

1;

__END__

=head1 NAME

HTTP::API::Client - Small foundation for JSON-oriented HTTP API clients

=head1 SYNOPSIS

    use HTTP::API::Client;

    my $api = HTTP::API::Client->new(
        base_url => 'https://api.example.com',
        headers  => {
            Authorization => "Bearer $token",
        },
    );

    my $res = $api->get('/users');
    my $data = $res->json;

=head1 DESCRIPTION

HTTP::API::Client is a small foundation for building HTTP API clients. It
provides base URL handling, JSON request/response helpers, configurable
headers and timeout, structured responses, and structured errors.

=head1 METHODS

=head2 new

    my $api = HTTP::API::Client->new(
        base_url => 'https://api.example.com',
        headers  => { ... },
        timeout  => 30,
    );

=head2 get / post / put / patch / delete

Convenience methods around C<request>.

=head2 request

    my $res = $api->request('POST', '/items', json => { name => 'example' });

On a successful 2xx response, returns an C<HTTP::API::Client::Response>.
Non-2xx responses throw C<HTTP::API::Client::Error>.

=head1 ERROR CATEGORIES

=over 4

=item * C<transport>

The underlying transport failed.

=item * C<http>

An HTTP response outside the 2xx range was received.

=item * C<encode>

A request could not be encoded as JSON.

=item * C<decode>

A response could not be decoded as JSON.

=back

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl itself.

=cut
