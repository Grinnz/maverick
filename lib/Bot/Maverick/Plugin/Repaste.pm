package Bot::Maverick::Plugin::Repaste;

use Mojo::URL;

use Moo;
extends 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

use constant PASTEBIN_RAW_ENDPOINT => 'http://pastebin.com/raw.php';
use constant HASTEBIN_RAW_ENDPOINT => 'http://hastebin.com/raw/';
use constant FPASTE_PASTE_ENDPOINT => 'http://fpaste.org/';

sub register {
	my ($self, $bot) = @_;
	
	$bot->config->channel_default(repaste_lang => 'text');
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		
		my @pastebin_keys = ($m->text =~ m!\bpastebin\.com/(?:raw\.php\?i=)?([a-z0-9]+)!ig);
		my @hastebin_keys = ($m->text =~ m!\bhastebin\.com/(?:raw/)?([a-z]+)!ig);
		return unless @pastebin_keys or @hastebin_keys;
		
		Mojo::IOLoop->delay(sub {
			my $delay = shift;
			foreach my $paste_key (@pastebin_keys) {
				my $url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->query(i => $paste_key);
				$m->logger->debug("Found pastebin link to $paste_key: $url");
				$bot->ua->get($url, $delay->begin);
			}
			foreach my $paste_key (@hastebin_keys) {
				my $url = Mojo::URL->new(HASTEBIN_RAW_ENDPOINT)->path($paste_key);
				$m->logger->debug("Found hastebin link to $paste_key: $url");
				$bot->ua->get($url, $delay->begin);
			}
		}, sub {
			my $delay = shift;
			foreach my $tx (@_) {
				$m->logger->error($self->ua_error($tx->error)), next if $tx->error;
				my $contents = $tx->res->text;
				$m->logger->debug("No paste contents"), next unless length $contents;
				
				my $lang = $m->config->channel_param($m->channel, 'repaste_lang') // 'text';
				
				my %form = (
					paste_data => $contents,
					paste_lang => $lang,
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
				
				my $result = $tx->res->json->{result} // {};
				$m->logger->error("Paste error: ".$result->{error}), next if $result->{error};
				
				my $id = $result->{id};
				my $hash = $result->{hash} // '';
				$m->logger->error("No paste ID returned"), next unless defined $id;
				
				my $url = Mojo::URL->new(FPASTE_PASTE_ENDPOINT)->path("$id/$hash/");
				$m->logger->debug("Repasted to $url");
				push @urls, $url;
			}
			
			return undef unless @urls;
			my $reply = 'Repasted text';
			$reply .= ' from ' . $m->sender if defined $m->channel;
			$reply .= ': ' . join ' ', @urls;
			$m->reply_bare($reply);
		})->catch(sub { chomp (my $err = $_[1]); $m->logger->error("Error repasting pastebin @pastebin_keys @hastebin_keys: $err") });
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
L<pastebin.com|http://pastebin.com> or L<hastebin.com|http://hastebin.com> link
is detected, repastes it to another pastebin site like
L<fpaste|http://fpaste.org>.

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
