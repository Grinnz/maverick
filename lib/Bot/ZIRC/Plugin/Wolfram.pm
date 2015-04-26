package Bot::ZIRC::Plugin::Wolfram;

use Carp 'croak';
use Data::Validate::IP qw/is_ipv4 is_ipv6/;
use Mojo::DOM;
use Mojo::IOLoop;
use Mojo::URL;

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant WOLFRAM_API_ENDPOINT => 'http://api.wolframalpha.com/v2/query';
use constant WOLFRAM_API_KEY_MISSING => 
	"Wolfram plugin requires configuration option 'wolfram_api_key' in section 'apis'\n" .
	"See http://products.wolframalpha.com/api/ for more information on obtaining a Wolfram API key.\n";

has 'api_key' => (
	is => 'rw',
);

sub register {
	my ($self, $bot) = @_;
	$self->api_key($bot->config->get('apis','wolfram_api_key')) unless defined $self->api_key;
	die WOLFRAM_API_KEY_MISSING unless defined $self->api_key;
	
	$bot->add_plugin_method($self, 'wolfram_query');
	
	$bot->add_command(
		name => 'wolframalpha',
		help_text => 'Query the Wolfram|Alpha computational knowledge engine',
		usage_text => '<query>',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			my $api_key = $m->config->get('apis','wolfram_api_key');
			die WOLFRAM_API_KEY_MISSING unless defined $api_key;
			
			my $host = $m->sender->host;
			Mojo::IOLoop->delay(sub {
				my $delay = shift;
				if (is_ipv4 $host or is_ipv6 $host) {
					$delay->pass($host);
				} elsif ($self->bot->has_plugin_method('dns_resolve_ips')) {
					my $cb = $delay->begin(0);
					$self->bot->dns_resolve_ips($host, sub {
						my $addrs = shift;
						$cb->($addrs->[0]);
					})->catch(sub { $cb->(undef) });
				} else {
					$delay->pass(undef);
				}
			}, sub {
				my ($delay, $ip) = @_;
				$self->wolfram_query($query, $ip, $delay->begin(0))
					->catch(sub { $m->reply("Wolfram|Alpha query error: $_[1]") });
			}, sub {
				my ($delay, $result) = @_;
				return $m->reply('No results from Wolfram|Alpha') unless defined $result;
				
				my $success = $result->attr('success');
				if (defined $success and $success eq 'false') {
					$self->_reply_wolfram_error($m, $result);
				} else {
					$self->_reply_wolfram_success($m, $result);
				}
			})->catch(sub { $m->reply("Internal error"); chomp (my $err = $_[1]); $m->logger->error($err) });
		},
	);
}

sub wolfram_query {
	my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
	my ($self, $query, $ip) = @_;
	croak 'Undefined Wolfram query' unless defined $query;
	die WOLFRAM_API_KEY_MISSING unless defined $self->api_key;
	
	my $url = Mojo::URL->new(WOLFRAM_API_ENDPOINT)
		->query(input => $query, appid => $self->api_key, format => 'plaintext');
	$url->query({ip => $ip}) if defined $ip;
	
	unless ($cb) {
		my $tx = $self->ua->get($url);
		die $self->ua_error($tx->error) if $tx->error;
		return Mojo::DOM->new->xml(1)->parse($tx->res->text)->children('queryresult')->first;
	}
	return Mojo::IOLoop->delay(sub {
		$self->ua->get($url, shift->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $self->ua_error($tx->error) if $tx->error;
		$cb->(Mojo::DOM->new->xml(1)->parse($tx->res->text)->children('queryresult')->first);
	});
}

sub _reply_wolfram_error {
	my ($self, $m, $result) = @_;
	
	my $error = $result->attr('error');
	if (defined $error and $error eq 'true') {
		my $err_msg = $result->children('error > msg')->first->text;
		return $m->reply("Error querying Wolfram|Alpha: $err_msg");
	}
	
	my @warning_output;
	my $languagemsg = $result->find('languagemsg')->first;
	if (defined $languagemsg) {
		my $msg = $languagemsg->attr('english');
		push @warning_output, "Language error: $msg";
	}
	my $tips = $result->find('tips > tip');
	if ($tips->size) {
		my $tips_str = $tips->map(sub { $_->attr('text') })->join('; ');
		push @warning_output, "Query not understood: $tips_str";
	}
	my $didyoumeans = $result->find('didyoumeans > didyoumean');
	if ($didyoumeans->size) {
		my $didyoumean_str = $didyoumeans->map(sub { $_->text })->join('; ');
		push @warning_output, "Did you mean: $didyoumean_str";
	}
	my $futuretopic = $result->find('futuretopic')->first;
	if (defined $futuretopic) {
		my $topic = $futuretopic->attr('topic');
		my $msg = $futuretopic->attr('msg');
		push @warning_output, "$topic: $msg";
	}
	my $relatedexamples = $result->find('relatedexamples > relatedexample');
	if ($relatedexamples->size) {
		my $example_str = $relatedexamples->map(sub { $_->attr('category') })->join('; ');
		push @warning_output, "Related categories: $example_str";
	}
	my $examplepage = $result->find('examplepage')->first;
	if (defined $examplepage) {
		my $category = $examplepage->attr('category');
		my $url = $examplepage->attr('url');
		push @warning_output, "See category $category: $url";
	}
	
	if (@warning_output) {
		my $output_str = join ' || ', @warning_output;
		return $m->reply($output_str);
	} else {
		return $m->reply("Wolfram|Alpha query was unsuccessful");
	}
}

sub _reply_wolfram_success {
	my ($self, $m, $result) = @_;
	
	my @pod_contents;
	my $pods = $result->find('pod');
	foreach my $pod (@{$pods->to_array}) {
		my $title = $pod->attr('title');
		my @contents;
		my $subpods = $pod->find('subpod');
		foreach my $subpod (@{$subpods->to_array}) {
			my $subtitle = $subpod->attr('title');
			my $plaintext = $subpod->find('plaintext')->first // next;
			my $content = $plaintext->text;
			next unless defined $content and length $content;
			$content = _reformat_wolfram_content($content);
			$content = "$subtitle: $content" if defined $subtitle and length $subtitle;
			push @contents, $content;
		}
		
		push @pod_contents, "$title: ".join '; ', @contents if @contents;
	}
	
	if (@pod_contents) {
		my $output = join ' || ', @pod_contents;
		$m->reply($output);
	} else {
		$m->reply("Empty response to Wolfram|Alpha query");
	}
}

sub _reformat_wolfram_content {
	my $content = shift // return undef;
	$content =~ s/ \| / - /g;
	$content =~ s/^\r?\n//;
	$content =~ s/\r?\n\z//;
	$content =~ s/\r?\n/, /g;
	$content =~ s/\\\:([0-9a-f]{4})/chr(hex($1))/egi;
	$content =~ s/~~/\x{2248}/g;
	return $content;
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Wolfram - Wolfram|Alpha plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Wolfram => 1 },
 );
 
 # Standalone usage
 my $wolfram = Bot::ZIRC::Plugin::Wolfram->new(api_key => $api_key);
 my $results = $wolfram->wolfram_query($query);

=head1 DESCRIPTION

Adds plugin methods and commands for querying Wolfram|Alpha to a L<Bot::ZIRC>
IRC bot.

This plugin requires a Wolfram|Alpha API key, as the configuration option
C<wolfram_api_key> in the C<apis> section. See
L<http://products.wolframalpha.com/api/> for information on obtaining an API
key.

=head1 ATTRIBUTES

=head2 api_key

API key for Wolfram|Alpha API, defaults to value of configuration option
C<wolfram_api_key> in section C<apis>.

=head1 METHODS

=head2 wolfram_query

 my $results = $bot->wolfram_query($query);
 $bot->wolfram_query($query, sub {
   my $results = @_;
 })->catch(sub { $m->reply("Wolfram|Alpha query error: $_[1]") });

Query Wolfram|Alpha. Returns the results as a L<Mojo::DOM> object, or throws an
exception on transport error. Pass a callback to perform the query
non-blocking.

Wolfram|Alpha will set the C<success> attribute of the root element to C<true>
if the query was successful, and the C<error> attribute to C<true> if an error
occurred (it is possible neither will be set). On a successful query, the
results will be contained in the DOM structure as C<pod> elements, which may
have a C<title> attribute and any number of C<subpod> elements. On an
unsuccessful query, either the error message or other reasons will be contained
in the DOM structure.

=head1 COMMANDS

=head2 wolframalpha

 !wolframalpha distance from earth to sun
 !wolframalpha convert 1000 BTC to USD
 !wolframalpha 1001st digit of pi

Query Wolfram|Alpha and display results or errors.

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
