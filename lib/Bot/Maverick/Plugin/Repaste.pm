package Bot::Maverick::Plugin::Repaste;

use Mojo::URL;

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.50';

use constant PASTEBIN_RAW_ENDPOINT => 'http://pastebin.com/raw/';
use constant HASTEBIN_RAW_ENDPOINT => 'https://hastebin.com/raw/';
use constant FPASTE_API_ENDPOINT => 'https://paste.fedoraproject.org/api/paste/';
use constant DPASTE_API_ENDPOINT => 'http://dpaste.com/api/v2/';
use constant PERLBOT_API_ENDPOINT => 'https://perl.bot/api/v1/';
use constant RPASTE_API_ENDPOINT => 'https://rpa.st/';
use constant HASTEBIN_API_KEY_MISSING =>
	"Repaste plugin requires configuration option 'hastebin_api_key' in section 'apis' to repaste from Hastebin.\n" .
	"See https://toptal.com/developers/hastebin/documentation to obtain a Hastebin API key.\n";

has 'hastebin_api_key' => (
	is => 'rw',
);

sub register {
	my ($self, $bot) = @_;
	
	$self->hastebin_api_key($bot->config->param('apis','hastebin_api_key')) unless defined $self->hastebin_api_key;
	$bot->add_helper(hastebin_api_key => sub { $self->hastebin_api_key });
	$bot->config->channel_default(repaste_lang => 'text');
	
	$bot->add_handler(sub {
		my ($bot, $m) = @_;
		return 0 if $m->sender->is_bot;
		
		my @pastebin_keys = ($m->text =~ m!\bpastebin\.com/(?:raw(?:/|\.php\?i=))?([a-z0-9]+)!ig);
		my @hastebin_keys = ($m->text =~ m!\bhastebin\.com/(?:raw/|share/)?([a-z]+)!ig);
		my @fpaste_keys = ($m->text =~ m!\b(?:paste\.fedoraproject\.org|fpaste\.org)/paste/([-a-z0-9=~]+)!ig);
		my @pastes = ((map { +{type => 'pastebin', key => $_} } @pastebin_keys),
			(map { +{type => 'hastebin', key => $_} } @hastebin_keys),
			(map { +{type => 'fpaste', key => $_} } @fpaste_keys));
		return 0 unless @pastes;
		
		my $future = _retrieve_pastes($m, \@pastes)->then(sub { _repaste_pastes($m, shift) })->on_done(sub {
			my $urls = shift;
			return() unless @$urls;
			my $reply = 'Repasted text';
			$reply .= ' from ' . $m->sender if defined $m->channel;
			$reply .= ': ' . join ' ', @$urls;
			$m->reply_bare($reply);
		})->on_fail(sub { chomp (my $err = $_[0]); $m->logger->error("Error repasting pastes from message '" . $m->text . "': $err") });
		$m->bot->adopt_future($future);
		return 1;
	});
}

sub _retrieve_pastes {
	my ($m, $pastes) = @_;
	
	my @futures;
	foreach my $paste (@$pastes) {
		if ($paste->{type} eq 'pastebin') {
			my $url = Mojo::URL->new(PASTEBIN_RAW_ENDPOINT)->path($paste->{key});
			push @futures, $m->bot->ua_request($url);
		} elsif ($paste->{type} eq 'hastebin') {
			my $api_key = $m->bot->hastebin_api_key;
			unless (defined $api_key) {
				$m->logger->warn(HASTEBIN_API_KEY_MISSING);
				next;
			}
			my $url = Mojo::URL->new(HASTEBIN_RAW_ENDPOINT)->path($paste->{key});
			push @futures, $m->bot->ua_request($url, {Authorization => "Bearer $api_key"});
		} elsif ($paste->{type} eq 'fpaste') {
			my $url = Mojo::URL->new(FPASTE_API_ENDPOINT)->path('details');
			my %params = (paste_id => $paste->{key});
			push @futures, $m->bot->ua_request(post => $url, json => \%params);
		} else {
			$m->logger->warn("Unknown paste type $paste->{type} for paste link $paste->{key}");
			next;
		}
		$m->logger->debug("Found $paste->{type} link to $paste->{key}");
	}
	return $m->bot->new_future->wait_all(@futures)->then(sub {
		my @results = @_;
		foreach my $i (0..$#results) {
			my $future = $results[$i];
			my $paste = $pastes->[$i];
			$m->logger->error("Error retrieving $paste->{type} paste $paste->{key}: " . $future->failure) if $future->is_failed;
			next unless $future->is_done;
			my $res = $future->get;
			if ($paste->{type} eq 'fpaste') {
				my $json = $res->json;
				$m->logger->error("Error retrieving $paste->{type} paste $paste->{key}: " . $json->{message}), next unless $json->{success};
				my $contents = $json->{details}{contents};
				$m->logger->debug("No paste contents for $paste->{type} paste $paste->{key}"), next unless length $contents;
				$paste->{contents} = $contents;
				$paste->{title} = $json->{details}{title};
				$paste->{lang} = $json->{details}{language};
			} else {
				my $contents = $res->text;
				$m->logger->debug("No paste contents for $paste->{type} paste $paste->{key}"), next unless length $contents;
				if ($paste->{type} eq 'pastebin' and $contents =~ /Please refresh the page to continue\.\.\./) {
					$paste->{recheck} = 1;
				} else {
					$paste->{contents} = $contents;
				}
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
	})->transform(done => sub { # this whole stupid extra step for pastebin.com
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
		
		my $lang = $m->config->channel_param($m->channel, 'repaste_lang') // $paste->{lang} // 'text';
		
		my %form = (
			raw => $paste->{contents},
			lexer => $lang,
			expiry => '1day',
		);
		
		$m->logger->debug("Repasting $paste->{type} paste $paste->{key} contents to rpaste");
		my $url = Mojo::URL->new(RPASTE_API_ENDPOINT)->path('curl');
		push @futures, $m->bot->ua_request(post => $url, form => \%form);
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
			
			my ($url) = $res->text =~ m/^Paste URL:\s+(.+)$/m;
			unless (length $url) {
				$m->logger->error("No paste URL returned");
				next;
			}
			
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
L<rpa.st|https://rpa.st>.

This plugin requires a Hastebin API key to repaste content from Hastebin, as
the configuration option C<hastebin_api_key> in section C<apis>. See
L<https://toptal.com/developers/hastebin/documentation> to obtain a Hastebin
API key.

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
