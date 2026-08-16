package HTTP::API::Client::Response;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use HTTP::API::Client::Error;
use HTTP::API::Client::RateLimit;

sub new {
    my ($class, %args) = @_;
    return bless {
        status  => $args{status},
        reason  => $args{reason},
        headers => { map { lc($_) => $args{headers}{$_} } keys %{ $args{headers} || {} } },
        content => defined($args{content}) ? $args{content} : '',
        method  => $args{method},
        url     => $args{url},
        elapsed => $args{elapsed},
    }, $class;
}

sub status  { $_[0]->{status} }
sub reason  { $_[0]->{reason} }
sub headers { +{ %{ $_[0]->{headers} } } }
sub content { $_[0]->{content} }
sub method  { $_[0]->{method} }
sub elapsed { $_[0]->{elapsed} }
sub request_id {
    my ($self) = @_;
    for my $name (qw(x-request-id request-id x-correlation-id)) {
        my $value = $self->header($name);
        return $value if defined $value && length $value;
    }
    return undef;
}
sub url     { $_[0]->{url} }
sub is_success { $_[0]->{status} >= 200 && $_[0]->{status} < 300 }
sub header { my ($self, $name) = @_; return $self->{headers}{lc $name} }
sub rate_limit { HTTP::API::Client::RateLimit->from_headers($_[0]->{headers}) }

sub json {
    my ($self) = @_;
    my $decoded = eval { decode_json($self->{content}) };
    if ($@) {
        die HTTP::API::Client::Error->new(
            category   => 'decode',
            status     => $self->{status},
            method     => $self->{method},
            url        => $self->{url},
            response   => $self,
            message    => "failed to decode JSON response: $@",
        );
    }
    return $decoded;
}

1;
