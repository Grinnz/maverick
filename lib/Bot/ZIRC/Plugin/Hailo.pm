package Bot::ZIRC::Plugin::Hailo;

use Carp;
use Hailo;
use Scalar::Util 'blessed';

use Moo;
with 'Bot::ZIRC::Plugin';

has 'hailo' => (
	is => 'rwp',
	isa => sub { croak "Invalid Hailo object $_[0]"
		unless blessed $_[0] and $_[0]->isa('Hailo') },
	predicate => 1,
);

sub register {
	my ($self, $bot, @args) = @_;
	
	my $brain = $bot->config->get('hailo', 'brain') // 'brain.sqlite';
	
	unless ($self->has_hailo) {
		$self->_set_hailo(Hailo->new(@args, brain => $brain));
	}
	
	$bot->config->set_channel_default('hailo_speak', 0);
	
	$bot->add_hook_privmsg(sub {
		my ($network, $sender, $channel, $message) = @_;
		return if $sender->is_bot;
		
		my $directed;
		my $bot_nick = $network->nick;
		if ($message =~ s/^\Q$bot_nick\E[:,]?\s+//) {
			$directed = 1;
		}
		
		$self->hailo->learn($message);
		$network->logger->debug("Learned: $message");
		$self->hailo->save;
		
		my $speak = 1;
		$speak = $network->config->get_channel($channel, 'hailo_speak') if defined $channel;
		my $do_reply = $directed ? 1 : ($speak > rand);
		return unless $do_reply;
		
		my $reply = $self->hailo->reply($message);
		$network->logger->debug("Reply: $reply");
		
		$network->reply($sender, $channel, $reply);
	});
}

1;
