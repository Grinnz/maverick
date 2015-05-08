package Bot::ZIRC::EventEmitter;

use Moo::Role;
use Mojo::EventEmitter;

requires 'logger';

has '_event_emitter' => (
	is => 'ro',
	lazy => 1,
	default => sub { Mojo::EventEmitter->new },
	init_arg => undef,
	handles => [qw(catch has_subscribers on once subscribers unsubscribe)],
);

sub emit {
	my ($self, $name) = (shift, shift);
	my $subscribers = $self->subscribers($name);
	foreach my $sub (@$subscribers) {
		local $@;
		unless (eval { $self->$sub(@_); 1 }) {
			chomp (my $err = $@);
			$self->logger->error("Error in $name event: $err");
		}
	}
	return $self;
}

1;
