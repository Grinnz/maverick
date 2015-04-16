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
		strip_formatting => 0,
		on_run => sub {
			my $m = shift;
			my $quote = $m->args;
			return 'usage' unless length $quote;
			
			my $quotes = $self->bot->storage->data->{quotes} //= [];
			push @$quotes, $quote;
			my $num = @$quotes;
			
			$self->clear_quote_cache;
			$m->reply("Added quote $num");
		},
		required_access => ACCESS_BOT_ADMIN,
	);
	
	$bot->add_command(
		name => 'delquote',
		help_text => 'Delete a quote',
		usage_text => '<quote num>',
		on_run => sub {
			my $m = shift;
			my ($num) = $m->args_list;
			return 'usage' unless defined $num;
			
			return $m->reply("Invalid quote number")
				unless $num =~ /^\d+$/ and $num > 0;
			
			my $quotes = $self->bot->storage->data->{quotes} // [];
			my $count = @$quotes;
			return $m->reply("There are only $count quotes")
				unless $num <= $count;
			
			my ($quote) = splice @$quotes, $num-1, 1;
			
			$self->clear_quote_cache;
			return $m->reply("Deleted quote $num: $quote");
		},
		required_access => ACCESS_BOT_ADMIN,
	);
	
	$bot->add_command(
		name => 'quote',
		help_text => 'Retrieve a quote by number or search regex',
		usage_text => '[<quote num>|[!]<regex> [<result num>]]',
		strip_formatting => 0,
		on_run => sub {
			my $m = shift;
			my $args = $m->args;
			
			my $quotes = $self->bot->storage->data->{quotes};
			return $m->reply("No quotes stored")
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
				return $self->_display_quote($m, $quotes, undef, $num);
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
				$self->_display_quote($m, $quotes, $results, $num);
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
						return $m->reply("Invalid search regex: $err");
					}
					$results = $self->quote_cache->{$match_by}{lc $args} = $matches;
					$self->_display_quote($m, $quotes, $results, $num);
				});
			}
			
		},
	);
	
	$bot->add_command(
		name => 'loadquotes',
		help_text => 'Load quotes from text file',
		usage_text => '<filename>',
		on_run => sub {
			my $m = shift;
			my $filename = $m->args;
			return 'usage' unless length $filename;
			return $m->reply("Invalid filename $filename")
				if $filename =~ m!/!;
			return $m->reply("File $filename not found")
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
				return $m->reply("No quotes to add")
					unless $num_quotes;
				$self->clear_quote_cache;
				$m->reply("Loaded $num_quotes from $filename");
			});
		},
		required_access => ACCESS_BOT_MASTER,
	);
	
	$bot->add_command(
		name => 'storequotes',
		help_text => 'Store quotes to text file',
		usage_text => '<filename>',
		on_run => sub {
			my $m = shift;
			my $filename = $m->args;
			return 'usage' unless length $filename;
			return $m->reply("Invalid filename $filename")
				if $filename =~ m!/!;
			return $m->reply("File $filename exists")
				if -e $filename;
			
			my $quotes = $self->bot->storage->data->{quotes} // [];
			$self->fork_call(sub {
				spurt encode('UTF-8', join("\n", @$quotes)."\n"), $filename;
				return scalar @$quotes;
			}, sub {
				my ($self, $err, $num_quotes) = @_;
				die $err if $err;
				$m->reply("Stored $num_quotes quotes to $filename");
			});
		},
		required_access => ACCESS_BOT_MASTER,
	);
	
	$bot->add_command(
		name => 'clearquotes',
		help_text => 'Delete all quotes',
		on_run => sub {
			my $m = shift;
			$self->fork_call(sub {
				$self->bot->storage->data->{quotes} = [];
				return 1;
			}, sub {
				my ($self, $err) = @_;
				die $err if $err;
				$self->clear_quote_cache;
				$m->reply("Deleted all quotes");
			});
		},
		required_access => ACCESS_BOT_MASTER,
	);
}

sub _display_quote {
	my ($self, $m, $quotes, $results, $num) = @_;
	my ($result_num, $result_count);
	if ($results) {
		return $m->reply("No matches") unless @$results;
		$result_count = @$results;
		$result_num = $num //= 1+int rand $result_count;
		$result_num = $result_count if $result_num > $result_count;
		$num = $results->[$result_num-1];
	}
	my $quote = $quotes->[$num-1];
	my $msg = "[$num] $quote";
	$msg = "$msg ($result_num/$result_count)" if $results;
	$m->reply($msg);
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Quotes - Quote storage and retrieval plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Quotes => 1 },
 );

=head1 DESCRIPTION

Adds commands for storing and retrieving quotes to a L<Bot::ZIRC> IRC bot.

=head1 COMMANDS

=head2 addquote

 !addquote <Somebody> something funny!

Adds a quote to the quote database.

=head2 delquote

 !delquote 900

Deletes a quote from the quote database.

=head2 quote

 !quote
 !quote 900
 !quote <Somebody>
 !quote <Somebody> 3

Retrieves a quote from the quote database. With no arguments, retrieves a
quote at random. If a quote number is specified, retrieves that quote.
Otherwise, the arguments are used as a regex to search quotes, and a random
quote from those results is returned. A specific quote from a regex search can
be retrieved by appending a result number.

=head2 loadquotes

 !loadquotes quotes.txt

Loads quotes from a given text file into the quote database, file must be in
the bot's working directory. Each line is interpreted to be a quote.

=head2 storequotes

 !storequotes quotes.txt

Stores all quotes from the quote database to a text file in the bot's working
directory (File must not already exist). Each quote is stored as a separate
line.

=head2 clearquotes

 !clearquotes

Clears all quotes from the quote database.

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
