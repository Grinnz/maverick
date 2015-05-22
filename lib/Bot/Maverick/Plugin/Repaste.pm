package Bot::Maverick::Plugin::Repaste;

use Mojo::URL;

use Moo;
extends 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

use constant PASTEBIN_RAW_ENDPOINT => 'http://pastebin.com/raw.php';
use constant FPASTE_PASTE_ENDPOINT => 'http://fpaste.org/';

sub register {
	my ($self, $bot) = @_;
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		return unless defined $m->channel;
		return unless $m->text =~ m!\bpastebin.com/(raw.php\?i=)?([a-zA-Z0-9]+)!;
		my $is_raw = (defined $1 and length $1) ? 1 : 0;
		my $paste_key = $2;
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
			
			my $raw_path = $is_raw ? "raw/" : "";
			my $url = Mojo::URL->new(FPASTE_PASTE_ENDPOINT)->path("$id/$hash/$raw_path");
			$m->logger->debug("Repasted to $url");
			
			my $sender = $m->sender;
			$m->reply_bare("Repasted text from $sender: $url");
		})->catch(sub { chomp (my $err = $_[1]); $m->logger->error("Error repasting pastebin $paste_key: $err") });
	});
}

1;

=head1 NAME

Bot::Maverick::Plugin::Repaste - Repasting plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Repaste => 1 },
 );

=head1 DESCRIPTION

Hooks into public messages of a L<Bot::Maverick> IRC bot and whenever a
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

L<Bot::Maverick>