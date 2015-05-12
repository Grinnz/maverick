package Bot::Maverick::Plugin::Pick;

use Moo;
extends 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'pick',
		help_text => 'Pick a random item from a list',
		usage_text => '<item>[, <item>...]',
		on_run => sub {
			my $m = shift;
			my $items = $m->args;
			return 'usage' unless length $items;
			my @items = split /\s*,\s*/, $items;
			my $choice = 1+int rand @items;
			my $item = $items[$choice-1];
			$m->reply("$choice: $item");
		},
	);
}

1;

=head1 NAME

Bot::Maverick::Plugin::Pick - Pick command plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Pick => 1 },
 );

=head1 DESCRIPTION

Adds command for randomly selecting an item from a list to a L<Bot::Maverick>
IRC bot.

=head1 COMMANDS

=head2 pick

 !pick something, something else, something else entirely

Chooses an item from the given comma-separated list at random.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>
