package MojoX::SocketStream::Redis;

use strict;
use warnings;

use base 'MojoX::SocketStream';

use MojoX::SocketStream::Redis::Message;

sub new_message { MojoX::SocketStream::Redis::Message->new }

1;
