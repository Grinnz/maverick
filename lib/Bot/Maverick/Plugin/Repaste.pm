package Bot::Maverick::Plugin::Repaste;

use Mojo::URL;

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.50';

use constant PASTEBIN_RAW_ENDPOINT => 'http://pastebin.com/raw.php';
use constant HASTEBIN_RAW_ENDPOINT => 'http://hastebin.com/raw/';
use constant FPASTE_PASTE_ENDPOINT => 'http://paste.fedoraproject.org/';
use constant FPASTE_PASTE_VIEW => 'http://fpaste.org/';

sub register {
	my ($self, $bot) = @_;
	
	$bot->config->channel_default(repaste_lang => 'text');
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		
		my @pastebin_keys = ($m->text =~ m!\bpastebin\.com/(?:raw(?:/|\.php\?i=))?([a-z0-9]+)!ig);
		my @hastebin_keys = ($m->text =~ m!\bhastebin\.com/(?:raw/)?([a-z]+)!ig);
		my @pastes = ((map { +{type => 'pastebin', key => $_} } @pastebin_keys),
			(map { +{type => 'hastebin', key => $_} } @hastebin_keys));
		return() unless @pastes;
		
		my $future = _retrieve_pastes($m, \@pastes)->then(sub { _repaste_pastes($m, shift) })->on_done(sub {
			my $urls = shift;
			return() unless @$urls;
			my $reply = 'Repasted text';
			$reply .= ' from ' . $m->sender if defined $m->channel;
			$reply .= ': ' . join ' ', @$urls;
			$m->reply_bare($reply);
		})->on_fail(sub { chomp (my $err = $_[0]); $m->logger->error("Error repasting pastes from message '" . $m->text . "': $err") });
		$m->bot->adopt_future($future);
	});
}

sub _retrieve_pastes {
	my ($m, $pastes) = @_;
	
	my @futures;
	foreach my $paste (@$pastes) {
		my $url;
		if ($paste->{type} eq 'pastebin') {
			$url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->query(i => $paste->{key});
		} elsif ($paste->{type} eq 'hastebin') {
			$url = Mojo::URL->new(HASTEBIN_RAW_ENDPOINT)->path($paste->{key});
		}
		$m->logger->debug("Found $paste->{type} link to $paste->{key}: $url");
		push @futures, $m->bot->ua_request($url);
	}
	return $m->bot->new_future->wait_all(@futures)->then(sub {
		my @results = @_;
		foreach my $i (0..$#results) {
			my $future = $results[$i];
			my $paste = $pastes->[$i];
			$m->logger->error("Error retrieving $paste->{type} paste $paste->{key}: " . $future->failure) if $future->is_failed;
			next unless $future->is_done;
			my $res = $future->get;
			my $contents = $res->text;
			$m->logger->debug("No paste contents for $paste->{type} paste $paste->{key}"), next unless length $contents;
			if ($paste->{type} eq 'pastebin' and $contents =~ /Please refresh the page to continue\.\.\./) {
				$paste->{recheck} = 1;
			} else {
				$paste->{contents} = $contents;
			}
		}
		
		my @futures;
		foreach my $paste (@$pastes) {
			if ($paste->{recheck}) {
				my $url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->query(i => $paste->{key});
				$m->logger->debug("Rechecking $paste->{type} paste $paste->{key}: $url");
				push @futures, $m->bot->timer_future(1)
					->then(sub { $m->bot->ua_request($url) });
			} else {
				push @futures, $m->bot->new_future->done(undef);
			}
		}
		return $m->bot->new_future->wait_all(@futures);
	})->transform(done => sub {
		my @results = @_;
		foreach my $i (0..$#results) {
			my $future = $results[$i];
			my $paste = $pastes->[$i];
			$m->logger->error("Error retrieving $paste->{type} paste $paste->{key}: " . $future->failure) if $future->is_failed;
			next unless $future->is_done;
			my $res = $future->get // next;
			my $contents = $res->text;
			$m->logger->debug("No paste contents for $paste->{type} paste $paste->{key}"), next unless length $contents;
			$paste->{contents} = $contents;
		}
		return $pastes;
	});
}

sub _repaste_pastes {
	my ($m, $pastes) = @_;
	
	my @futures;
	foreach my $paste (@$pastes) {
		unless (defined $paste->{contents}) {
			push @futures, $m->bot->new_future->done(undef);
			next;
		}
		
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
		push @futures, $m->bot->ua_request(post => FPASTE_PASTE_ENDPOINT, form => \%form);
	}
	return $m->bot->new_future->wait_all(@futures)->transform(done => sub {
		my @results = @_;
		my @urls;
		foreach my $i (0..$#results) {
			my $future = $results[$i];
			my $paste = $pastes->[$i];
			$m->logger->error("Error repasting $paste->{type} paste $paste->{key}: " . $future->failure) if $future->is_failed;
			next unless $future->is_done;
			
			my $res = $future->get // next;
			my $json = $res->json;
			$m->logger->error("Did not receive JSON response: ".$res->text), next unless defined $json;
			my $result = $json->{result} // {};
			$m->logger->error("Paste error: ".$result->{error}), next if $result->{error};
			
			my $id = $result->{id};
			my $hash = $result->{hash} // '';
			$m->logger->error("No paste ID returned"), next unless defined $id;
			
			my $url = Mojo::URL->new(FPASTE_PASTE_VIEW)->path("$id/$hash/");
			$m->logger->debug("Repasted $paste->{type} paste $paste->{key} to $url");
			push @urls, $url;
		}
		return \@urls;
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
