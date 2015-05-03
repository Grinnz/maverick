use Bot::ZIRC;
use Test::More;
use Mojo::IOLoop;
use File::Temp 'tempdir';

my $dir = tempdir(CLEANUP => 1);

my %results;
my $server = Mojo::IOLoop->server({address => '127.0.0.1'} => sub {
	my ($loop, $stream, $id) = @_;
	my $buffer = '';
	$stream->on(read => sub {
		$buffer .= $_[1];
		$buffer = _read_buffer($_[0], $buffer, \%results) if $buffer =~ /\n/;
	});
});
my $port = Mojo::IOLoop->acceptor($server)->port;

my $nick = 'Tester';
my $name = 'Testing bot 123';
my $bot = Bot::ZIRC->new(name => $nick, config_dir => $dir, networks => {
	test => { irc => { server => '127.0.0.1', port => $port, realname => $name } }
});

Mojo::IOLoop->timer(0.25 => sub { $bot->stop; Mojo::IOLoop->acceptor($server)->stop });

my $guard = Mojo::IOLoop->timer(1 => sub { Mojo::IOLoop->stop; $results{stopped} = 0; });

$results{stopped} = 1;
$bot->start;

is $results{nick}, $nick, "Bot set nick to $nick";
is $results{user}, $nick, "Bot set user to $nick";
is $results{name}, $name, "Bot set name to $name";
ok $results{quit}, 'Bot has quit';
ok $results{stopped}, 'Bot has stopped';

done_testing;

sub _read_buffer {
	my ($stream, $buffer, $results) = @_;
	while ($buffer =~ s/(.*\n)//) {
		my $line = $1;
		if ($line =~ /^QUIT\b/) {
			$results->{quit} = 1;
			$stream->close;
			Mojo::IOLoop->remove($guard) if defined $guard;
		} elsif ($line =~ /^NICK ([^\s]+)/) {
			$results->{nick} = $1;
		} elsif ($line =~ /^USER ([^\s]+)[^:]+:([^\r\n]+)/) {
			$results->{user} = $1;
			$results->{name} = $2;
		}
	}
	return $buffer;
}

