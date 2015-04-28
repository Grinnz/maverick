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
		return unless $m->text =~ m!\bpastebin.com/(?:raw.php?i=)?([a-zA-Z0-9]+)!;
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
			
			my $summary = $contents;
			$summary =~ s/\n.+//s;
			
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
