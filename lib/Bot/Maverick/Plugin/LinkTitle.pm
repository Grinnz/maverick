package Bot::Maverick::Plugin::LinkTitle;

use Future::Utils 'fmap_concat';
use Mojo::Util 'trim';
use URL::Search 'extract_urls';

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.50';

sub register {
	my ($self, $bot) = @_;

	$bot->config->channel_default('linktitle_trigger', 0);
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		my $message = $m->text;
		return unless defined $m->channel;
		return unless $m->config->channel_param($m->channel, 'linktitle_trigger');
		return if $m->sender->is_bot;
		
		$m->network->after_who($m->sender->nick, sub {
			my ($network, $user) = @_;
			return if $user->is_bot;
			
			return unless my @urls = extract_urls $message;
			$m->logger->debug("Checking link titles for URLs: @urls");
			my $future = _get_link_titles($m, @urls)->on_done(sub {
				my @titles = @_;
				return() unless @titles;
				$m->reply_bare('Link title(s): ' . join ' ', map { "[ $_ ]" } @titles);
			})->on_fail(sub { $m->logger->error("Error retrieving link titles: $_[0]") });
			$m->bot->adopt_future($future);
		});
	});
}

sub _get_link_titles {
	my ($m, @urls) = @_;
	return fmap_concat {
		my $url = shift;
		return $m->bot->ua_request(get => $url)->followed_by(sub {
			my $f = shift;
			$m->logger->error("Error retrieving link title [$url]: " . $f->failure) if $f->is_failed;
			my $title_f = $m->bot->new_future;
			if ($f->is_done) {
				my $title = $f->get->dom->at('title');
				$title = trim $title->text if defined $title;
				$title = substr($title, 0, 47) . '...' if length($title) > 50;
				$title_f->done($title) if length $title;
			}
			$title_f->done unless $title_f->is_ready;
			return $title_f;
		});
	} foreach => \@urls, concurrent => 5;
}

1;

=head1 NAME

Bot::Maverick::Plugin::LinkTitle - Link title plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { LinkTitle => 1 },
 );
 
=head1 DESCRIPTION

Adds a hook to display link titles to a L<Bot::Maverick> IRC bot.

=head1 CONFIGURATION

=head2 linktitle_trigger

 !set #bots linktitle_trigger 0

Enable or disable automatic response with link titles. Defaults to 0 (off).

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
