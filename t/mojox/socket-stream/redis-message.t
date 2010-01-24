#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 49;

use MojoX::SocketStream::Redis::Message;

# Body part

my $message = MojoX::SocketStream::Redis::Message->new;
$message->build(auth => 'foo');
is($message->write_buffer, "AUTH foo\r\n");
is($message->get_chunk, "AUTH foo\r\n");
$message = MojoX::SocketStream::Redis::Message->new;
$message->build(auth => 'foo');
$message->_offset(1);
is($message->get_chunk, "UTH foo\r\n");
$message = MojoX::SocketStream::Redis::Message->new;
$message->build(auth => 'foo');
$message->_offset(9);
ok($message->get_chunk, '');
$message = MojoX::SocketStream::Redis::Message->new;
$message->build(auth => 'foo');
$message->_offset(10);
ok(not defined $message->get_chunk);

# Answer part

# Empty
$message = MojoX::SocketStream::Redis::Message->new;
ok(!$message->parse(""));

# Unknown response type
$message = MojoX::SocketStream::Redis::Message->new;
ok(!$message->parse("%2\r\n"));

# Inline response
$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("+PONG\r\n");
ok($message->is_done);
is($message->type, 'status');
is($message->answer, 'PONG');

# Error response
$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("-Error\r\n");
is($message->type, 'error');
ok($message->is_done);
is($message->answer, 'Error');

# Integer response
$message = MojoX::SocketStream::Redis::Message->new;
$message->parse(":-1\r\n");
ok($message->is_done);
is($message->type, 'integer');
is($message->answer, -1);

# Bulk response
$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("\$6\r\nfoobar\r\n");
ok($message->is_done);
is($message->type, 'bulk');
is($message->answer, 'foobar');

$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("\$6\r\nfoo");
ok(!$message->is_done);
$message->parse("bar\r\n");
ok($message->is_done);
is($message->type, 'bulk');
is($message->answer, 'foobar');

$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("\$8\r\nfoobar\r\n\r\n");
ok($message->is_done);
is($message->type, 'bulk');
is($message->answer, "foobar\r\n");

# Bulk nil response
$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("\$-1\r\n");
is($message->type, 'bulk');
ok($message->is_done);
ok(not defined $message->answer);

# Multibulk nil response
$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("*-1\r\n");
is($message->type, 'multibulk');
ok($message->is_done);
ok(not defined $message->answer);

# Multibulk 0 length response
$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("*0\r\n");
is($message->type, 'multibulk');
ok($message->is_done);
is_deeply($message->answer, []);

# \r\n
$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("*4\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n\$5\r\nHello\r\n\$5\r\nWorld\r\n");
is($message->type, 'multibulk');
ok($message->is_done);
is_deeply($message->answer, ['foo', 'bar', 'Hello', 'World']);

# \n
$message = MojoX::SocketStream::Redis::Message->new;
$message->parse(<<'EOF');
*4
$3
foo
$3
bar
$5
Hello
$5
World
EOF
ok($message->is_done);
is($message->type, 'multibulk');
is_deeply($message->answer, ['foo', 'bar', 'Hello', 'World']);

$message = MojoX::SocketStream::Redis::Message->new;
$message->parse("*");
ok(!$message->is_done);
$message->parse("4\r\n\$");
ok(!$message->is_done);
$message->parse("3\r\nfo");
ok(!$message->is_done);
$message->parse("o\r\n\$3\r\nbar\r");
ok(!$message->is_done);
$message->parse("\n\$5\r\nHello\r\n");
ok(!$message->is_done);
$message->parse("\$5\r\nWorld\r\n");
ok($message->is_done);
is($message->type, 'multibulk');
is_deeply($message->answer, ['foo', 'bar', 'Hello', 'World']);
