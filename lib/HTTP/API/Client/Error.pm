package HTTP::API::Client::Error;

use strict;
use warnings;
use overload '""' => 'as_string', fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub message     { $_[0]->{message} }
sub category    { $_[0]->{category} }
sub status      { $_[0]->{status} }
sub method      { $_[0]->{method} }
sub url         { $_[0]->{url} }
sub retryable   { $_[0]->{retryable} ? 1 : 0 }
sub retry_after { $_[0]->{retry_after} }
sub request_id  { $_[0]->{request_id} }
sub response    { $_[0]->{response} }
sub rate_limit  { $_[0]->{response} ? $_[0]->{response}->rate_limit : undef }
sub as_string   { defined($_[0]->{message}) ? $_[0]->{message} : 'HTTP API client error' }

1;
