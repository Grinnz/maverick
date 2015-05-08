package Bot::ZIRC::EventEmitter;

use Moo::Role;
use Mojo::EventEmitter;

requires 'logger';

has '_event_emitter' => (
	is => 'ro',
	lazy => 1,
	default => sub { Mojo::EventEmitter->new },
	init_arg => undef,
	handles => [qw(has_subscribers on once subscribers unsubscribe)],
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

=head1 NAME

Bot::ZIRC::EventEmitter - Event emitter role for Bot::ZIRC

=head1 SYNOPSIS

  package EventThingy;
  use Moo;
  with 'Bot::ZIRC::EventEmitter';
  
  package main;
  my $thingy = EventThingy->new;
  $thingy->on(something => sub {
    my ($thingy, $stuff) = @_;
    say "Got $stuff!";
  });
  
  $thingy->emit('something');

=head1 DESCRIPTION

Moo role that provides a L<Mojo::EventEmitter> for subscribing to and emitting
events. Used for emitting events from L<Bot::ZIRC> and L<Bot::ZIRC::Network>.

=head1 METHODS

=head2 emit

  $e = $e->emit('foo');
  $e = $e->emit('foo', 123);

Emit event.

=head2 has_subscribers

  my $bool = $e->has_subscribers('foo');

Check if event has subscribers.

=head2 on

  my $cb = $e->on(foo => sub {...});

Subscribe to event.

  $e->on(foo => sub {
    my ($e, @args) = @_;
    ...
  });

=head2 once

  my $cb = $e->once(foo => sub {...});

Subscribe to event and unsubscribe again after it has been emitted once.

  $e->once(foo => sub {
    my ($e, @args) = @_;
    ...
  });

=head2 subscribers

  my $subscribers = $e->subscribers('foo');

All subscribers for event.

  # Unsubscribe last subscriber
  $e->unsubscribe(foo => $e->subscribers('foo')->[-1]);

=head2 unsubscribe

  $e = $e->unsubscribe('foo');
  $e = $e->unsubscribe(foo => $cb);

Unsubscribe from event.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::ZIRC>, L<Moo::Role>, L<Mojo::EventEmitter>
