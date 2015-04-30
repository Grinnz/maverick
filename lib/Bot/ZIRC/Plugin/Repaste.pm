package Bot::ZIRC::Plugin::Repaste;

use Mojo::URL;

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant PASTEBIN_RAW_ENDPOINT => 'http://pastebin.com/raw.php';
use constant FPASTE_PASTE_ENDPOINT => 'http://fpaste.org/';

sub register {
	my ($self, $bot) = @_;
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		return unless defined $m->channel;
		return unless $m->text =~ m!\bpastebin.com/(?:raw.php\?i=)?([a-zA-Z0-9]+)!;
		my $paste_key = $1;
		my $url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->query(i => $paste_key);
		$m->logger->debug("Found pastebin link to $paste_key: $url");
		Mojo::IOLoop->delay(sub {
			$bot->ua->get($url, shift->begin);
		}, sub {
			my ($delay, $tx) = @_;
			die $self->ua_error($tx->error) if $tx->error;
			my $contents = $tx->res->text;
			return $m->logger->debug("No paste contents") unless length $contents;
			
			my %form = (
				paste_data => $contents,
				paste_lang => 'text',
				paste_user => $m->sender->nick,
				paste_private => 'yes',
				paste_expire => 86400,
				api_submit => 'true',
				mode => 'json',
			);
			
			$m->logger->debug("Repasting contents to fpaste");
			$bot->ua->post(FPASTE_PASTE_ENDPOINT, form => \%form, $delay->begin);
		}, sub {
			my ($delay, $tx) = @_;
			die $self->ua_error($tx->error) if $tx->error;
			
			my $id = $tx->res->json->{result}{id};
			my $hash = $tx->res->json->{result}{hash} // '';
			die "No paste ID returned" unless defined $id;
			
			my $url = Mojo::URL->new(FPASTE_PASTE_ENDPOINT)->path("$id/$hash");
			$m->logger->debug("Repasted to $url");
			
			my $sender = $m->sender;
			$m->reply_bare("Repasted text from $sender: $url");
		})->catch(sub { $m->logger->error("Error repasting pastebin $paste_key: $_[1]") });
	});
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Repaste - Repasting plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Repaste => 1 },
 );

=head1 DESCRIPTION

Hooks into public messages of a L<Bot::ZIRC> IRC bot and whenever a
L<pastebin.com|http://pastebin.com> link is detected, repastes it to another
pastebin site like L<fpaste|http://fpaste.org>.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::ZIRC>
