package Bot::ZIRC::Plugin::Wolfram;

use Data::Validate::IP qw/is_ipv4 is_ipv6/;
use Mojo::URL;

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant WOLFRAM_API_ENDPOINT => 'http://api.wolframalpha.com/v2/query';
use constant WOLFRAM_API_KEY_MISSING => 
	"Wolfram plugin requires configuration option 'wolfram_api_key' in section 'apis'\n" .
	"See http://products.wolframalpha.com/api/ for more information on obtaining a Wolfram API key.\n";

sub register {
	my ($self, $bot) = @_;
	my $api_key = $bot->config->get('apis','wolfram_api_key');
	die WOLFRAM_API_KEY_MISSING unless defined $api_key;
	
	$bot->add_command(
		name => 'wolframalpha',
		help_text => 'Query the Wolfram|Alpha computational knowledge engine',
		usage_text => '<query>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			my $api_key = $network->config->get('apis','wolfram_api_key');
			die WOLFRAM_API_KEY_MISSING unless defined $api_key;
			
			my $ip;
			my $host = $sender->host;
			if (is_ipv4 $host or is_ipv6 $host) {
				$ip = $host;
				do_wolfram_query($network, $sender, $channel, $query, $ip);
			} elsif ($network->bot->has_plugin_method('dns_resolve')) {
				$network->bot->dns_resolve($host, sub {
					my ($err, @results) = @_;
					my $addrs = $network->bot->dns_ip_results(\@results);
					my $ip = @$addrs ? $addrs->[0] : undef;
					do_wolfram_query($network, $sender, $channel, $query, $ip);
				});
			} else {
				do_wolfram_query($network, $sender, $channel, $query);
			}
		},
	);
}

sub do_wolfram_query {
	my ($network, $sender, $channel, $query, $ip) = @_;
	my $api_key = $network->config->get('apis','wolfram_api_key');
	die WOLFRAM_API_KEY_MISSING unless defined $api_key;
	
	my $url = Mojo::URL->new(WOLFRAM_API_ENDPOINT)
		->query(input => $query, appid => $api_key, format => 'plaintext');
	$url->query({ip => $ip}) if defined $ip;
	
	$network->ua->get($url, sub {
		my ($ua, $tx) = @_;
		return $network->reply($sender, $channel, ua_error($tx->error)) if $tx->error;
		
		my $result = $tx->res->dom->xml(1)->children('queryresult')->first;
		return $network->reply($sender, $channel, "Error querying Wolfram|Alpha")
			unless defined $result;
		
		my $success = $result->attr('success');
		if (defined $success and $success eq 'false') {
			reply_wolfram_error($network, $sender, $channel, $result);
		} else {
			reply_wolfram_success($network, $sender, $channel, $result);
		}
	});
}

sub reply_wolfram_error {
	my ($network, $sender, $channel, $result) = @_;
	
	my $error = $result->attr('error');
	if (defined $error and $error eq 'true') {
		my $err_msg = $result->children('error > msg')->first->text;
		return $network->reply($sender, $channel, "Error querying Wolfram|Alpha: $err_msg");
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
		return $network->reply($sender, $channel, $output_str);
	} else {
		return $network->reply($sender, $channel, "Wolfram|Alpha query was unsuccessful");
	}
}

sub reply_wolfram_success {
	my ($network, $sender, $channel, $result) = @_;
	
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
			$content = reformat_wolfram_content($content);
			$content = "$subtitle: $content" if defined $subtitle and length $subtitle;
			push @contents, $content;
		}
		
		push @pod_contents, "$title: ".join '; ', @contents if @contents;
	}
	
	if (@pod_contents) {
		my $output = join ' || ', @pod_contents;
		$network->reply($sender, $channel, $output);
	} else {
		$network->reply($sender, $channel, "Empty response to Wolfram|Alpha query");
	}
}

sub reformat_wolfram_content {
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
