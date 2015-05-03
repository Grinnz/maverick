package Bot::ZIRC::Plugin;

use Bot::ZIRC;
use Carp;
use Mojo::IOLoop::ForkCall;
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

our $VERSION = '0.20';

has 'bot' => (
	is => 'ro',
	isa => sub { croak "Invalid bot object"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC') },
	lazy => 1,
	default => sub { Bot::ZIRC->new },
	weak_ref => 1,
	handles => [qw/logger ua/],
);

sub register { die "Method must be overloaded by subclass" }

sub ua_error {
	my ($self, $err) = @_;
	return $err->{code}
		? "Transport error $err->{code}: $err->{message}\n"
		: "Connection error: $err->{message}\n";
}

sub fork_call {
	my ($self, @args) = @_;
	my $cb = (@args > 1 and ref $args[-1] eq 'CODE') ? pop @args : undef;
	my $fc = Mojo::IOLoop::ForkCall->new;
	return $fc->run(@args, sub {
		my $fc = shift;
		$self->$cb(@_) if $cb;
	});
}

1;

=head1 NAME

Bot::ZIRC::Plugin - Base class for Bot::ZIRC plugins

=head1 SYNOPSIS

  package My::ZIRC::Plugin;
  use Moo;
  extends 'Bot::ZIRC::Plugin';
  sub register { my ($self, $bot) = @_; ... }
  
  my $plugin = My::ZIRC::Plugin->new(bot => $bot, %$params);
  $plugin->register($bot);

=head1 DESCRIPTION

L<Bot::ZIRC::Plugin> is an abstract base class for plugins for the L<Bot::ZIRC>
IRC bot framework.

=head1 ATTRIBUTES

=head2 bot

Weakened reference to L<Bot::ZIRC> object.

=head1 METHODS

=head2 register

Register plugin with bot, intended to be overloaded in a subclass.

=head2 ua_error

Forms a simple error message from a L<Mojo::UserAgent> transaction error hash.

=head2 fork_call

Runs the first callback in a forked process using L<Mojo::IOLoop::ForkCall> and
calls the second callback when it completes. The returned
L<Mojo::IOLoop::ForkCall> object can be used to catch errors.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::ZIRC>, L<Bot::ZIRC::Plugin::Core>
