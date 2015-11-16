package Bot::Maverick::Plugin::Hailo;

use Carp;
use Hailo;
use Scalar::Util 'blessed';

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

has 'brain' => (
	is => 'rw',
);

has 'hailo' => (
	is => 'lazy',
	isa => sub { croak "Invalid Hailo object $_[0]"
		unless blessed $_[0] and $_[0]->isa('Hailo') },
	predicate => 1,
);

sub _build_hailo {
	my $self = shift;
	return Hailo->new(brain => $self->brain);
}

sub register {
	my ($self, $bot) = @_;
	
	$self->brain($bot->config->param('hailo', 'brain') // 'brain.sqlite');
	
	$bot->config->channel_default('hailo_speak', 0);
	$bot->config->channel_default('hailo_reply_when_addressed', 1);
	$bot->config->channel_default('hailo_reply_when_mentioned', 0);
	
	$bot->add_helper(hailo => sub { $self->hailo });
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		my $message = $m->text;
		return if $m->sender->is_bot;
		
		my ($addressed, $mentioned);
		my $bot_nick = $m->nick;
		if ($message =~ s/^\Q$bot_nick\E[:,]?\s+//i) {
			$addressed = 1;
		}
		if ($message =~ m/\b\Q$bot_nick\E\b/i) {
			$mentioned = 1;
		}
		
		$m->bot->hailo->learn($message);
		$m->logger->debug("Learned: $message");
		$m->bot->hailo->save;
		
		my $speak = 1;
		$speak = $m->config->channel_param($m->channel, 'hailo_speak') if defined $m->channel;
		my $do_reply = $speak > rand() ? 1 : 0;
		my $when_addressed = $m->config->channel_param($m->channel, 'hailo_reply_when_addressed');
		my $when_mentioned = $m->config->channel_param($m->channel, 'hailo_reply_when_mentioned');
		$do_reply = 1 if $when_addressed and $addressed;
		$do_reply = 1 if $when_mentioned and $mentioned;
		return unless $do_reply;
		
		my $reply = $m->bot->hailo->reply($message);
		$m->logger->debug("Reply: $reply");
		
		if ($addressed) {
			$m->reply($reply);
		} else {
			$m->reply_bare($reply);
		}
	});
}

1;

=head1 NAME

Bot::Maverick::Plugin::Hailo - Hailo artificial intelligence plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Hailo => 1 },
 );

=head1 DESCRIPTION

Hooks into private and public messages of a L<Bot::Maverick> IRC bot to train a
L<Hailo> Markov engine artificial intelligence brain and generate responses.

=head1 ATTRIBUTES

=head2 brain

Filename to use for SQLite brain, defaults to value of configuration option
C<brain> in section C<hailo>, or filename C<brain.sqlite>.

=head1 CONFIGURATION

=head2 hailo_speak

 !set #bots hailo_speak 0.01

Free-speak ratio for channel. If C<0> (default), bot will not reply unless
addressed directly. If C<1>, bot will reply to every message it sees (not
recommended). Ratios in between will set the approximate percentage of messages
that the bot will reply to.

=head2 hailo_reply_when_addressed

 !set #bots hailo_reply_when_addressed 0

Whether to always reply when addressed by name. Defaults to 1 (on).

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<Hailo>
