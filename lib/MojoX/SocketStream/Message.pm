package MojoX::SocketStream::Message;

use strict;
use warnings;

use base 'Mojo::Stateful';

use Mojo::Buffer;
use Carp 'croak';

__PACKAGE__->attr('address');
__PACKAGE__->attr('port');

__PACKAGE__->attr(write_buffer => sub { Mojo::Buffer->new });
__PACKAGE__->attr(read_buffer  => sub { Mojo::Buffer->new });

__PACKAGE__->attr('answer');

__PACKAGE__->attr('_offset' => 0);
__PACKAGE__->attr(_to_write => 0);

sub connected {
    my $self = shift;

    $self->state('write');
    $self->_to_write($self->write_buffer->size);
}

sub is_writing { shift->is_state('write') }

sub get_chunk {
    my $self = shift;

    # Get next chunk
    my $chunk = substr($self->write_buffer, $self->_offset);

    # End
    if (defined $chunk && !length $chunk) {
        $self->state('read');
        return;
    }

    # Written
    my $written = defined $chunk ? length $chunk : 0;
    $self->_to_write($self->_to_write - $written);
    $self->_offset($self->_offset + $written);

    return $chunk;
}

sub parse { croak 'Method "parse" not implemented by subclass' }

sub build { croak 'Method "build" not implemented by subclass' }

sub read {
    my ($self, $chunk) = @_;

    # Length
    my $read = length $chunk;

    if ($self->is_state('read')) {
        $self->done if $read == 0;

        # Append chunk to the response
        $self->read_buffer->add_chunk($chunk);

        # Parse response
        $self->parse;
    }

    return $self;
}

sub spin {
    my $self = shift;

    # Everything is written, switch to reading a response
    if ($self->is_state('write')) {
        $self->state('read') if $self->_to_write <= 0;
    }
}

1;
