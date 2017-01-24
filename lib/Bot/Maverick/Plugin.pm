package Bot::Maverick::Plugin;

use Bot::Maverick;
use Carp;
use Scalar::Util 'blessed';

use Moo::Role;

our $VERSION = '0.50';

requires 'register';

has 'bot' => (
	is => 'ro',
	isa => sub { croak "Invalid bot object"
		unless blessed $_[0] and $_[0]->isa('Bot::Maverick') },
	lazy => 1,
	default => sub { Bot::Maverick->new },
	weak_ref => 1,
);

1;

=head1 NAME

Bot::Maverick::Plugin - Role for Maverick plugins

=head1 SYNOPSIS

  package My::Maverick::Plugin;
  use Moo;
  with 'Bot::Maverick::Plugin';
  sub register { my ($self, $bot) = @_; ... }
  
  my $plugin = My::Maverick::Plugin->new(bot => $bot, %$params);
  $plugin->register($bot);

=head1 DESCRIPTION

L<Bot::Maverick::Plugin> is a role for plugins for the L<Bot::Maverick> IRC bot
framework.

=head1 ATTRIBUTES

=head2 bot

Weakened reference to L<Bot::Maverick> object.

=head1 METHODS

=head2 register

Register plugin with bot. Required by classes consuming this role.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<Bot::Maverick::Plugin::Core>
