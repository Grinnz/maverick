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
		my @paste_keys = ($m->text =~ m!\bpastebin.com/(?:raw\.php\?i=)?([a-z0-9]+)!ig);
		return unless @paste_keys;
		
		Mojo::IOLoop->delay(sub {
			my $delay = shift;
			foreach my $paste_key (@paste_keys) {
				my $url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->query(i => $paste_key);
				$m->logger->debug("Found pastebin link to $paste_key: $url");
				$bot->ua->get($url, $delay->begin);
			}
		}, sub {
			my $delay = shift;
			foreach my $tx (@_) {
				$m->logger->error($self->ua_error($tx->error)), next if $tx->error;
				my $contents = $tx->res->text;
				$m->logger->debug("No paste contents"), next unless length $contents;
				
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
			}
		}, sub {
			my $delay = shift;
			my @urls;
			foreach my $tx (@_) {
				$m->logger->error($self->ua_error($tx->error)), next if $tx->error;
				
				my $id = $tx->res->json->{result}{id};
				my $hash = $tx->res->json->{result}{hash} // '';
				$m->logger->error("No paste ID returned"), next unless defined $id;
				
				my $url = Mojo::URL->new(FPASTE_PASTE_ENDPOINT)->path("$id/$hash/");
				$m->logger->debug("Repasted to $url");
				push @urls, $url;
			}
			
			my $sender = $m->sender;
			$m->reply_bare("Repasted text from $sender: ".join(' ', @urls));
		})->catch(sub { chomp (my $err = $_[1]); $m->logger->error("Error repasting pastebin @paste_keys: $err") });
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
