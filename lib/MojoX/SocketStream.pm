package MojoX::SocketStream;

use strict;
use warnings;

use base 'Mojo::Base';
use bytes;

use Mojo::IOLoop;
use MojoX::SocketStream::Message;
use Scalar::Util 'weaken';

__PACKAGE__->attr([qw/address port/]);

__PACKAGE__->attr([qw/default_cb/]);
__PACKAGE__->attr([qw/max_keep_alive_connections/] => 5);
__PACKAGE__->attr(ioloop     => sub { Mojo::IOLoop->singleton });
__PACKAGE__->attr(keep_alive_timeout => 15);

__PACKAGE__->attr(_cache       => sub { [] });
__PACKAGE__->attr(_connections => sub { {} });
__PACKAGE__->attr([qw/_finite _queued/] => 0);

# Make sure we leave a clean ioloop behind
sub DESTROY {
    my $self = shift;

    # Shortcut
    return unless $self->ioloop;

    # Cleanup active connections
    for my $id (keys %{$self->_connections}) {
        $self->ioloop->drop($id);
    }

    # Cleanup keep alive connections
    for my $cached (@{$self->_cache}) {
        my $id = $cached->[1];
        $self->ioloop->drop($id);
    }
}

sub new_message { MojoX::SocketStream::Message->new };

sub process {
    my $self = shift;

    # Queue transactions
    $self->queue(@_) if @_;

    # Already running
    return $self if $self->_finite;

    # Loop is finite
    $self->_finite(1);

    # Start ioloop
    $self->ioloop->start;

    # Loop is not finite if it's still running
    $self->_finite(undef);

    return $self;
}

sub queue {
    my $self = shift;

    # Callback
    my $cb = pop @_ if ref $_[-1] && ref $_[-1] eq 'CODE';

    # Queue transactions
    $self->_queue($_, $cb) for @_;

    return $self;
}

sub send { shift->_build_message(@_) }

sub _build_message {
    my $self = shift;

    # New message
    my $message = $self->new_message;

    # Callback
    my $cb = pop @_ if ref $_[-1] && ref $_[-1] eq 'CODE';

    my @body = @_ == 1 && ref $_[0] eq 'ARRAY' ? @{$_[0]} : @_;

    # Address
    $message->address($self->address) if $self->address;

    # Port
    $message->port($self->port) if $self->port;

    # Body
    $message->build(@_);

    # Queue transaction with callback
    $self->queue($message, $cb);
}

sub _connect {
    my ($self, $id) = @_;

    # Transaction
    my $message = $self->_connections->{$id}->{message};

    # Connected
    $message->connected;

    # Keep alive timeout
    $self->ioloop->connection_timeout($id => $self->keep_alive_timeout);

    # Weaken
    weaken $self;

    # Callbacks
    $self->ioloop->error_cb($id => sub { $self->_error(@_) });
    $self->ioloop->hup_cb($id => sub { $self->_hup(@_) });
    $self->ioloop->read_cb($id => sub { $self->_read(@_) });
    $self->ioloop->write_cb($id => sub { $self->_write(@_) });
}

sub _deposit {
    my ($self, $name, $id) = @_;

    # Limit keep alive connections
    while (@{$self->_cache} >= $self->max_keep_alive_connections) {
        my $cached = shift @{$self->_cache};
        $self->_drop($cached->[1]);
    }

    # Deposit
    push @{$self->_cache}, [$name, $id];
}

sub _drop {
    my ($self, $id) = @_;

    # Keep connection alive
    if (my $message = $self->_connections->{$id}->{message}) {

        # Read only
        $self->ioloop->not_writing($id);

        # Deposit
        my $address = $message->address;
        my $port    = $message->port;
        $self->_deposit("$address:$port", $id);
    }

    # Connection close
    else {
        $self->ioloop->finish($id);
        $self->_withdraw($id);
    }

    # Drop connection
    delete $self->_connections->{$id};
}

sub _error {
    my ($self, $loop, $id, $error) = @_;

    # Transaction
    if (my $message = $self->_connections->{$id}->{message}) {

        # Add error message
        $message->error($error);
    }

    # Finish
    $self->_finish($id);
}

sub _finish {
    my ($self, $id) = @_;

    # Connection
    my $c = $self->_connections->{$id};

    # Message
    my $message = $c->{message};

    # Drop old connection so we can reuse it
    $self->_drop($id);

    # Message still in progress
    if ($message) {

        # Counter
        $self->_queued($self->_queued - 1);

        # Get callback
        my $cb = $c->{cb} || $self->default_cb;

        # Callback
        $self->$cb($message) if $cb;
    }

    # Stop ioloop
    $self->ioloop->stop if $self->_finite && !$self->_queued;
}

sub _hup {
    my ($self, $loop, $id) = @_;

    # Message
    if (my $message = $self->_connections->{$id}->{message}) {

        # Add error message
        $message->error('Connection closed.');
    }

    # Finish
    $self->_finish($id);
}

sub _queue {
    my ($self, $message, $cb) = @_;

    # Info
    my $address = $message->address;
    my $port    = $message->port;

    # Weaken
    weaken $self;

    # Connect callback
    my $connected = sub {
        my ($loop, $id) = @_;

        # Connected
        $self->_connect($id);
    };

    # Cached connection
    my $id;
    if ($id = $self->_withdraw("$address:$port")) {

        # Writing
        $self->ioloop->writing($id);

        # Add new connection
        $self->_connections->{$id} = {cb => $cb, message => $message};

        # Connected
        $self->_connect($id);
    }

    # New connection
    else {

        # Connect
        $id = $self->ioloop->connect(
            cb      => $connected,
            address => $address,
            port    => $port
        );

        # Error
        unless (defined $id) {
            $message->error("Couldn't create connection.");
            $cb ||= $self->default_cb;
            $self->$cb($message) if $cb;
            #die 'fuck';
            return;
        }

        # Add new connection
        $self->_connections->{$id} = {cb => $cb, message => $message};
    }

    # Weaken
    weaken $message;

    # State change callback
    $message->state_cb(
        sub {

            # Finished?
            return $self->_finish($id) if $message->is_finished;

            # Writing?
            $message->is_writing
              ? $self->ioloop->writing($id)
              : $self->ioloop->not_writing($id);
        }
    );

    # Counter
    $self->_queued($self->_queued + 1);

    return $id;
}

sub _read {
    my ($self, $loop, $id, $chunk) = @_;

    # Message
    if (my $message = $self->_connections->{$id}->{message}) {

        # Read
        $message->read($chunk);

        # State machine
        $message->spin;
    }

    # Corrupted connection
    else { $self->_drop($id) }
}

sub _withdraw {
    my ($self, $name) = @_;

    # Withdraw
    my $found;
    my @cache;
    for my $cached (@{$self->_cache}) {

        # Search for name or id
        $found = $cached->[1] and next
          if $cached->[1] eq $name || $cached->[0] eq $name;

        # Cache again
        push @cache, $cached;
    }
    $self->_cache(\@cache);

    return $found;
}

sub _write {
    my ($self, $loop, $id) = @_;

    # Message
    if (my $message = $self->_connections->{$id}->{message}) {

        # Get chunk
        my $chunk = $message->get_chunk;

        # State machine
        $message->spin;

        return $chunk;
    }

    # Corrupted connection
    else { $self->_drop($id) }

    return;
}

1;
