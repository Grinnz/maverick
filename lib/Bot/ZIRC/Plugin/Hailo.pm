package Bot::ZIRC::Plugin::Hailo;

use Carp;
use Hailo;
use Scalar::Util 'blessed';

use Moo;
extends 'Bot::ZIRC::Plugin';

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
	
	$self->brain($bot->config->get('hailo', 'brain') // 'brain.sqlite');
	
	$bot->config->set_channel_default('hailo_speak', 0);
	$bot->config->set_channel_default('hailo_reply_when_addressed', 1);
	
	$bot->add_hook_privmsg(sub {
		my ($network, $sender, $channel, $message) = @_;
		return if $sender->is_bot;
		
		my $addressed;
		my $bot_nick = $network->nick;
		if ($message =~ s/^\Q$bot_nick\E[:,]?\s+//) {
			$addressed = 1;
		}
		
		$self->hailo->learn($message);
		$network->logger->debug("Learned: $message");
		$self->hailo->save;
		
		my $speak = 1;
		$speak = $network->config->get_channel($channel, 'hailo_speak') if defined $channel;
		my $do_reply = $speak > rand ? 1 : 0;
		my $when_addressed = $network->config->get_channel($channel, 'hailo_reply_when_addressed');
		$do_reply = 1 if $when_addressed and $addressed;
		return unless $do_reply;
		
		my $reply = $self->hailo->reply($message);
		$network->logger->debug("Reply: $reply");
		
		$network->reply($sender, $channel, $reply);
	});
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Hailo - Hailo artificial intelligence plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Hailo => 1 },
 );

=head1 DESCRIPTION

Hooks into private and public messages of a L<Bot::ZIRC> IRC bot to train a
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

L<Bot::ZIRC>, L<Hailo>
