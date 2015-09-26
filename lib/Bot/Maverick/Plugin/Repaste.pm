package Bot::Maverick::Plugin::Repaste;

use Mojo::URL;

use Moo;
with 'Bot::Maverick::Plugin';

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
		my @pastes = (map { +{type => 'pastebin', key => $_} } @pastebin_keys),
			(map { +{type => 'hastebin', key => $_} } @hastebin_keys);
		return undef unless @pastes;
		
		Mojo::IOLoop->delay(sub {
			my $delay = shift;
			_retrieve_pastes($m, \@pastes, $delay->begin(0))
				->catch(sub { $delay->emit(error => $_[1]) });
		}, sub {
			my ($delay, $pastes) = @_;
			_repaste_pastes($m, $pastes, $delay->begin(0))
				->catch(sub { $delay->emit(error => $_[1]) });
		}, sub {
			my ($delay, $urls) = @_;
			return undef unless @$urls;
			my $reply = 'Repasted text';
			$reply .= ' from ' . $m->sender if defined $m->channel;
			$reply .= ': ' . join ' ', @$urls;
			$m->reply_bare($reply);
		})->catch(sub { chomp (my $err = $_[1]); $m->logger->error("Error repasting pastes from message '" . $m->text . "': $err") });
	});
}

sub _retrieve_pastes {
	my $cb = pop;
	my ($m, $pastes) = @_;
	
	return Mojo::IOLoop->delay(sub {
		my $delay = shift;
		foreach my $paste (@$pastes) {
			my $url;
			if ($paste->{type} eq 'pastebin') {
				$url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->query(i => $paste->{key});
			} elsif ($paste->{type} eq 'hastebin') {
				$url = Mojo::URL->new(HASTEBIN_RAW_ENDPOINT)->path($paste->{key});
			}
			$m->logger->debug("Found $paste->{type} link to $paste->{key}: $url");
			$m->bot->ua->get($url, $delay->begin);
		}
	}, sub {
		my ($delay, @txs) = @_;
		my $recheck_pastebin;
		foreach my $i (0..$#txs) {
			my $tx = $txs[$i];
			my $paste = $pastes->[$i];
			$m->logger->error($m->bot->ua_error($tx->error)), next if $tx->error;
			my $contents = $tx->res->text;
			$m->logger->debug("No paste contents for $paste->{type} paste $paste->{key}"), next unless length $contents;
			if ($paste->{type} eq 'pastebin' and $contents =~ /Please refresh the page to continue\.\.\./) {
				$paste->{recheck} = $recheck_pastebin = 1;
			} else {
				$paste->{contents} = $contents;
			}
		}
		
		if ($recheck_pastebin) {
			foreach my $paste (@$pastes) {
				$delay->pass(undef), next unless $paste->{recheck};
				my $url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->query(i => $paste->{key});
				$m->logger->debug("Rechecking $paste->{type} paste $paste->{key}: $url");
				my $end = $delay->begin;
				Mojo::IOLoop->timer(1 => sub { $m->bot->ua->get($url, $end) });
			}
		} else {
			$cb->($pastes);
		}
	}, sub {
		my ($delay, @txs) = @_;
		foreach my $i (0..$#txs) {
			my $tx = $txs[$i];
			my $paste = $pastes->[$i];
			next unless defined $tx;
			$m->logger->error($m->bot->ua_error($tx->error)), next if $tx->error;
			my $contents = $tx->res->text;
			$m->logger->debug("No paste contents for $paste->{type} paste $paste->{key}"), next unless length $contents;
			$paste->{contents} = $contents;
		}
		$cb->($pastes);
	});
}

sub _repaste_pastes {
	my $cb = pop;
	my ($m, $pastes) = @_;
	
	return Mojo::IOLoop->delay(sub {
		my $delay = shift;
		foreach my $paste (@$pastes) {
			$delay->pass(undef), next unless defined $paste->{contents};
			
			my $lang = $m->config->channel_param($m->channel, 'repaste_lang') // 'text';
			
			my %form = (
				paste_data => $paste->{contents},
				paste_lang => $lang,
				paste_user => $m->sender->nick,
				paste_private => 'yes',
				paste_expire => 86400,
				api_submit => 'true',
				mode => 'json',
			);
			
			$m->logger->debug("Repasting $paste->{type} paste $paste->{key} contents to fpaste");
			$m->bot->ua->post(FPASTE_PASTE_ENDPOINT, form => \%form, $delay->begin);
		}
	}, sub {
		my ($delay, @txs) = @_;
		my @urls;
		foreach my $i (0..$#txs) {
			my $tx = $txs[$i];
			my $paste = $pastes->[$i];
			next unless defined $tx;
			$m->logger->error($m->bot->ua_error($tx->error)), next if $tx->error;
			
			my $result = $tx->res->json->{result} // {};
			$m->logger->error("Paste error: ".$result->{error}), next if $result->{error};
			
			my $id = $result->{id};
			my $hash = $result->{hash} // '';
			$m->logger->error("No paste ID returned"), next unless defined $id;
			
			my $url = Mojo::URL->new(FPASTE_PASTE_ENDPOINT)->path("$id/$hash/");
			$m->logger->debug("Repasted $paste->{type} paste $paste->{key} to $url");
			push @urls, $url;
		}
		
		$cb->(\@urls);
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
