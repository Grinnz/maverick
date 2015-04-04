package Bot::ZIRC::Plugin::Quotes;

use Bot::ZIRC::Access ':access';
use Mojo::Util qw/decode encode slurp spurt/;

use Moo;
extends 'Bot::ZIRC::Plugin';

has 'quote_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
	clearer => 1,
);

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'addquote',
		help_text => 'Add a quote',
		usage_text => '<quote>',
		tokenize => 0,
		strip_formatting => 0,
		on_run => sub {
			my ($network, $sender, $channel, $quote) = @_;
			return 'usage' unless length $quote;
			
			my $quotes = $self->bot->storage->data->{quotes} //= [];
			push @$quotes, $quote;
			my $num = @$quotes;
			
			$self->clear_quote_cache;
			$network->reply($sender, $channel, "Added quote $num");
		},
		required_access => ACCESS_BOT_ADMIN,
	);
	
	$bot->add_command(
		name => 'delquote',
		help_text => 'Delete a quote',
		usage_text => '<quote num>',
		on_run => sub {
			my ($network, $sender, $channel, $num) = @_;
			return 'usage' unless defined $num;
			
			return $network->reply($sender, $channel, "Invalid quote number")
				unless $num =~ /^\d+$/ and $num > 0;
			
			my $quotes = $self->bot->storage->data->{quotes} // [];
			my $count = @$quotes;
			return $network->reply($sender, $channel, "There are only $count quotes")
				unless $num <= $count;
			
			my ($quote) = splice @$quotes, $num-1, 1;
			
			$self->clear_quote_cache;
			return $network->reply($sender, $channel, "Deleted quote $num: $quote");
		},
		required_access => ACCESS_BOT_ADMIN,
	);
	
	$bot->add_command(
		name => 'quote',
		help_text => 'Retrieve a quote by number or search regex',
		usage_text => '[<quote num>|[!]<regex> [<result num>]]',
		tokenize => 0,
		strip_formatting => 0,
		on_run => sub {
			my ($network, $sender, $channel, $args) = @_;
			
			my $quotes = $self->bot->storage->data->{quotes};
			return $network->reply($sender, $channel, "No quotes stored")
				unless $quotes and @$quotes;
			
			# Quotes by number
			my $num;
			if ($args =~ m/^\d+$/ and $args > 0) {
				$num = $args;
			} elsif (!length $args) {
				$num = 1+int rand @$quotes;
			}
			
			if (defined $num) {
				$num = @$quotes if $num > @$quotes;
				return $self->display_quote($network, $sender, $channel, $quotes, undef, $num);
			}
			
			# Quotes by search regex
			if ($args =~ m/^(.+?)\s+(\d+)$/ and $2 > 0) {
				$args = $1;
				$num = $2;
			}
			
			my $match_by = '=';
			if (length $args > 1 and $args =~ s/^!//) {
				$match_by = '!';
			}
			
			my $results = $self->quote_cache->{$match_by}{lc $args};
			if (defined $results) {
				$self->display_quote($network, $sender, $channel, $quotes, $results, $num);
			} else {
				$self->fork_call(sub {
					my $re = qr/$args/i;
					$quotes->lock_shared;
					my $num_quotes = @$quotes;
					my @matches = $match_by eq '='
						? grep { $quotes->[$_-1] =~ $re } (1..$num_quotes)
						: grep { $quotes->[$_-1] !~ $re } (1..$num_quotes);
					$quotes->unlock;
					return \@matches;
				}, sub {
					my ($self, $err, $matches) = @_;
					if ($err) {
						chomp $err;
						$err =~ s/ at .+? line .+?\.$//;
						return $network->reply($sender, $channel, "Invalid search regex: $err");
					}
					$results = $self->quote_cache->{$match_by}{lc $args} = $matches;
					$self->display_quote($network, $sender, $channel, $quotes, $results, $num);
				});
			}
			
		},
	);
	
	$bot->add_command(
		name => 'loadquotes',
		help_text => 'Load quotes from text file',
		usage_text => '<filename>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $filename) = @_;
			return 'usage' unless length $filename;
			return $network->reply($sender, $channel, "Invalid filename $filename")
				if $filename =~ m!/!;
			return $network->reply($sender, $channel, "File $filename not found")
				unless -r $filename;
			
			my $quotes = $self->bot->storage->data->{quotes} //= [];
			$self->fork_call(sub {
				my @add_quotes = grep { length } split /\r?\n/, decode 'UTF-8', slurp $filename;
				return 0 unless @add_quotes;
				my $num_quotes = @add_quotes;
				push @$quotes, @add_quotes;
				return $num_quotes;
			}, sub {
				my ($self, $err, $num_quotes) = @_;
				die $err if $err;
				return $network->reply($sender, $channel, "No quotes to add")
					unless $num_quotes;
				$self->clear_quote_cache;
				$network->reply($sender, $channel, "Loaded $num_quotes from $filename");
			});
		},
		required_access => ACCESS_BOT_MASTER,
	);
	
	$bot->add_command(
		name => 'storequotes',
		help_text => 'Store quotes to text file',
		usage_text => '<filename>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $filename) = @_;
			return 'usage' unless length $filename;
			return $network->reply($sender, $channel, "Invalid filename $filename")
				if $filename =~ m!/!;
			return $network->reply($sender, $channel, "File $filename exists")
				if -e $filename;
			
			my $quotes = $self->bot->storage->data->{quotes} // [];
			$self->fork_call(sub {
				spurt encode('UTF-8', join("\n", @$quotes)."\n"), $filename;
				return scalar @$quotes;
			}, sub {
				my ($self, $err, $num_quotes) = @_;
				die $err if $err;
				$network->reply($sender, $channel, "Stored $num_quotes quotes to $filename");
			});
		},
		required_access => ACCESS_BOT_MASTER,
	);
	
	$bot->add_command(
		name => 'clearquotes',
		help_text => 'Delete all quotes',
		on_run => sub {
			my ($network, $sender, $channel) = @_;
			$self->fork_call(sub {
				$self->bot->storage->data->{quotes} = [];
				return 1;
			}, sub {
				my ($self, $err) = @_;
				die $err if $err;
				$self->clear_quote_cache;
				$network->reply($sender, $channel, "Deleted all quotes");
			});
		},
		required_access => ACCESS_BOT_MASTER,
	);
}

sub display_quote {
	my ($self, $network, $sender, $channel, $quotes, $results, $num) = @_;
	my ($result_num, $result_count);
	if ($results) {
		return $network->reply($sender, $channel, "No matches") unless @$results;
		$result_count = @$results;
		$result_num = $num //= 1+int rand $result_count;
		$result_num = $result_count if $result_num > $result_count;
		$num = $results->[$result_num-1];
	}
	my $quote = $quotes->[$num-1];
	my $msg = "[$num] $quote";
	$msg = "$msg ($result_num/$result_count)" if $results;
	$network->reply($sender, $channel, $msg);
}

1;
