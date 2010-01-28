package MojoX::SocketStream::Redis;

use strict;
use warnings;

use base 'MojoX::SocketStream';

use MojoX::SocketStream::Redis::Message;

our $AUTOLOAD;

sub new_message { MojoX::SocketStream::Redis::Message->new }

sub AUTOLOAD {
    my $self = shift;
    my ($method, @params) = @_;

    return if $method =~ /^[A-Z]+?$/;
    return if $method =~ /^_/;
    return if $method =~ /(?:\:*?)DESTROY$/;

    $method =~ s/^.+:://;

    $self->send($method => @_);
}

1;
