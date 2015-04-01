package Bot::ZIRC::Plugin::Translate;

use Mojo::URL;

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant MICROSOFT_OAUTH_ENDPOINT => 'https://datamarket.accesscontrol.windows.net/v2/OAuth2-13/';
use constant MICROSOFT_ARRAY_SCHEMA => 'http://schemas.microsoft.com/2003/10/Serialization/Arrays';
use constant XML_SCHEMA_INSTANCE => 'http://www.w3.org/2001/XMLSchema-instance';
use constant TRANSLATE_OAUTH_SCOPE => 'http://api.microsofttranslator.com';
use constant TRANSLATE_API_ENDPOINT => 'http://api.microsofttranslator.com/v2/Http.svc/';
use constant MICROSOFT_API_KEY_MISSING => 
	"Translate plugin requires configuration options 'microsoft_client_id' and 'microsoft_client_secret' in section 'apis'\n" .
	"See http://blogs.msdn.com/b/translation/p/gettingstarted1.aspx " .
	"for more information on obtaining a Microsoft Client ID and Client secret.\n";

has 'client_id' => (
	is => 'rw',
);

has 'client_secret' => (
	is => 'rw',
);

has '_access_token' => (
	is => 'rw',
	lazy => 1,
	builder => 1,
	clearer => 1,
	init_arg => undef,
);

has '_access_token_expire' => (
	is => 'rw',
	predicate => 1,
	clearer => 1,
	init_arg => undef,
);

sub _build__access_token {
	my $self = shift;
	die MICROSOFT_API_KEY_MISSING unless defined $self->client_id and defined $self->client_secret;
	
	my $url = Mojo::URL->new(MICROSOFT_OAUTH_ENDPOINT);
	my %form = (
		client_id => $self->client_id,
		client_secret => $self->client_secret,
		scope => TRANSLATE_OAUTH_SCOPE,
		grant_type => 'client_credentials'
	);
	my $tx = $self->ua->post($url, form => \%form);
	die $self->ua_error($tx->error) if $tx->error;
	my $data = $tx->res->json;
	$self->_access_token_expire(time+$data->{expires_in});
	return $data->{access_token};
}

sub _retrieve_access_token {
	my $self = shift;
	if ($self->_has_access_token_expire and $self->_access_token_expire <= time) {
		$self->_clear_access_token;
		$self->_clear_access_token_expire;
	}
	return $self->_access_token;
}

has '_translate_languages' => (
	is => 'lazy',
	init_arg => undef,
);

has '_language_names' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub _build__translate_languages {
	my $self = shift;
	
	my $url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('GetLanguagesForTranslate');
	my $access_token = $self->_retrieve_access_token;
	my %headers = (Authorization => "Bearer $access_token");
	my $tx = $self->ua->get($url, \%headers);
	die $self->ua_error($tx->error) if $tx->error;
	my @languages = $tx->res->dom->xml(1)->find('string')->map('text')->each;
	
	$url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('GetLanguageNames')->query(locale => 'en');
	$headers{'Content-Type'} = 'text/xml';
	$tx = $self->ua->post($url, \%headers, _xml_string_array(@languages));
	die $self->ua_error($tx->error) if $tx->error;
	my @names = $tx->res->dom->xml(1)->find('string')->map('text')->each;
	
	my %languages;
	for my $i (0..$#languages) {
		my $lang = $languages[$i] // next;
		my $name = $names[$i] // next;
		$languages{$lang} = $name;
		$self->_language_names->{lc $name} = $lang;
		my @words = split ' ', $name;
		if (@words > 1) {
			$self->_language_names->{lc $_} //= $lang for @words;
		}
		$self->_language_names->{lc $lang} //= $lang;
	}
	
	return \%languages;
}

sub _xml_string_array {
	my $xml = Mojo::DOM->new->xml(1)->content('<ArrayOfstring></ArrayOfstring>');
	my $array = $xml->at('ArrayOfstring');
	$array->attr(xmlns => MICROSOFT_ARRAY_SCHEMA, 'xmlns:i' => XML_SCHEMA_INSTANCE);
	foreach my $string (@_) {
		my $elem = Mojo::DOM->new->xml(1)->content('<string></string>')->at('string');
		$elem->content($string);
		$array->append_content($elem->to_string);
	}
	return $xml->to_string;
}

sub register {
	my ($self, $bot) = @_;
	$self->client_id($bot->config->get('apis','microsoft_client_id'))
		unless defined $self->client_id;
	$self->client_secret($bot->config->get('apis','microsoft_client_secret'))
		unless defined $self->client_secret;
	die MICROSOFT_API_KEY_MISSING unless defined $self->client_id and defined $self->client_secret;
	
	$bot->add_command(
		name => 'translate',
		help_text => 'Translate text from one language to another (default: from detected language to English)',
		usage_text => '["]<text>["] [from <language>] [to <language>]',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $args) = @_;
			
			my ($text, $from, $to);
			if ($args =~ s/\s+from\s+([^"]+?)(?:\s+to\s+([^"]+))?$//i) {
				$text = $args;
				$from = $1;
				$to = $2;
			} elsif ($args =~ s/\s+to\s+([^"]+?)(?:\s+from\s+([^"]+))?$//i) {
				$text = $args;
				$to = $1;
				$from = $2;
			} else {
				$text = $args;
			}
			
			$text =~ s/^\s*"\s*//;
			$text =~ s/\s*"\s*$//;
			return 'usage' unless length $text;
			
			$to = 'en' unless defined $to and length $to;
			unless (defined $from and length $from) { # Detect language
				my $url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('Detect')->query(text => $text);
				my $access_token = $self->_retrieve_access_token;
				my %headers = (Authorization => "Bearer $access_token");
				return $self->ua->get($url, \%headers, sub {
					my ($ua, $tx) = @_;
					return $network->reply($sender, $channel, $self->ua_error($tx->error)) if $tx->error;
					my $from = $tx->res->dom->xml(1)->at('string')->text;
					$self->do_translate($network, $sender, $channel, $text, $from, $to);
				});
			}
			
			$self->do_translate($network, $sender, $channel, $text, $from, $to);
		},
	);
}

sub do_translate {
	my ($self, $network, $sender, $channel, $text, $from, $to) = @_;
	
	unless (exists $self->_translate_languages->{$from}) {
		my $lang = $self->_language_names->{lc $from};
		return $network->reply($sender, $channel, "Unknown language $from")
			unless defined $lang and exists $self->_translate_languages->{$lang};
		$from = $lang;
	}
	unless (exists $self->_translate_languages->{$to}) {
		my $lang = $self->_language_names->{lc $to};
		return $network->reply($sender, $channel, "Unknown language $to")
			unless defined $lang and exists $self->_translate_languages->{$lang};
		$to = $lang;
	}
	
	my $url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('Translate')
		->query(text => $text, from => $from, to => $to, contentType => 'text/plain');
	my $access_token = $self->_retrieve_access_token;
	my %headers = (Authorization => "Bearer $access_token");
	$self->ua->get($url, \%headers, sub {
		my ($ua, $tx) = @_;
		return $network->reply($sender, $channel, $self->ua_error($tx->error)) if $tx->error;
		my $translated = $tx->res->dom->xml(1)->at('string')->text;
		my $from_name = $self->_translate_languages->{$from};
		my $to_name = $self->_translate_languages->{$to};
		$network->reply($sender, $channel, "Translated $from_name => $to_name: $translated");
	});
}

1;
