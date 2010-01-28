package MojoX::SocketStream::Redis::Message;

use strict;
use warnings;

use base 'MojoX::SocketStream::Message';

__PACKAGE__->attr(address => '127.0.0.1');
__PACKAGE__->attr(port    => 6379);

__PACKAGE__->attr('_type');
__PACKAGE__->attr(_state => 'start');

__PACKAGE__->attr(_bulk_counter => 0);
__PACKAGE__->attr(_bulk_state   => '');
__PACKAGE__->attr(_bulk_length  => 0);

my $STATUS    = '+';
my $ERROR     = '-';
my $INTEGER   = ':';
my $BULK      = '$';
my $MULTIBULK = '*';
my $TYPE_RE   = '[' . quotemeta("$STATUS$ERROR$INTEGER$BULK$MULTIBULK") . ']';

my %BULK_COMMANDS = map { $_ => 1 }
  qw( SET SETNX RPUSH LPUSH LSET LREM SADD SREM SISMEMBER ECHO );

sub build {
    my $self = shift;

    foreach my $cmd (ref $_[0] eq 'ARRAY' ? @_ : ([@_])) {
        $self->write_buffer->add_chunk($self->_build(@$cmd));

        $self->commands($self->commands + 1);
    }


    return $self;
}

sub _build {
    my $self = shift;

    my $command = uc shift;

    my $chunk = $command;
    if ($BULK_COMMANDS{$command}) {
        my $value = pop;
        $chunk .= ' '
            . join(' ', @_)
            . ' '
            . length($value)
            . "\x0d\x0a"
            . $value;
        $value .= length($value);
    }
    else {
        $chunk .= ' ' . join(' ', @_);
    }

    $chunk .= "\x0d\x0a";

    return $chunk;
}

sub type {
    my $self = shift;

    if (@_) {
        my $token = shift;

        if ($token eq $STATUS) {
            $self->_type('status');
        }
        elsif ($token eq $ERROR) {
            $self->_type('error');
        }
        elsif ($token eq $INTEGER) {
            $self->_type('integer');
        }
        elsif ($token eq $BULK) {
            $self->_type('bulk');
        }
        elsif ($token eq $MULTIBULK) {
            $self->_type('multibulk');
        }
        else {
        }

        return $self;
    }

    return $self->_type;
}

sub parse {
    my $self = shift;

    if (my $chunk = shift) {
        $self->read_buffer->add_chunk($chunk);
    }

    if ($self->_state eq 'start') {
        my $line = $self->read_buffer->get_line;
        return unless defined $line;

        unless ($line =~ s/^($TYPE_RE)//) {
            $self->error('Unknown type');
            return;
        }

        $self->type($1);

        if (grep { $_ eq $self->type } (qw/status error integer/)) {
            $self->answer($line);
            $self->done;
            return;
        }

        if ($line < 0) {
            $self->done;
            return;
        }

        if ($self->type eq 'bulk') {
            $self->_bulk_counter(1);
            $self->_bulk_length($line);
            $self->_bulk_state('parse');
        }
        else {
            $self->answer([]);
            $self->_bulk_counter($line);
            $self->_bulk_state('length');
        }

        $self->_state('parse');
    }

    while (1) {

        if ($self->_bulk_counter <= 0) {
            $self->done;
            return;
        }

        if ($self->_bulk_state eq 'length') {

            my $line = $self->read_buffer->get_line;
            return unless defined $line;

            $line =~ s/^\$//;

            if ($line == -1) {
                push @{$self->answer}, undef;
                $self->_bulk_counter($self->_bulk_counter - 1);
            }
            else {
                $self->_bulk_length(int $line);
                $self->_bulk_state('parse');
            }
        }
        else {
            if ($self->read_buffer->size < $self->_bulk_length) {
                return;
            }

            my $ending = substr($self->read_buffer, $self->_bulk_length, 2);
            return unless $ending && $ending =~ m/^(\x0d?\x0a)/;

            my $offset = length $1;

            my $answer = $self->read_buffer->remove($self->_bulk_length);
            $self->read_buffer->remove($offset);

            if ($self->type eq 'multibulk') {
                push @{$self->answer}, $answer;
            }
            else {
                $self->answer($answer);
            }

            $self->_bulk_counter($self->_bulk_counter - 1);
            $self->_bulk_state('length');
        }
    }

    return 1;
}

1;
