package Bot::ZIRC::Command;

use Bot::ZIRC::Access qw/:access valid_access_level/;
use Carp;
use Scalar::Util 'blessed';

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

our @CARP_NOT = qw(Bot::ZIRC Bot::ZIRC::Network Moo);

has 'name' => (
	is => 'ro',
	isa => sub { croak "Invalid command name $_[0]"
		unless defined $_[0] and $_[0] =~ /^\w+$/ },
	required => 1,
);

has 'on_run' => (
	is => 'ro',
	isa => sub { croak "Invalid on_run subroutine $_[0]"
		unless defined $_[0] and ref $_[0] eq 'CODE' },
	required => 1,
);

has 'required_access' => (
	is => 'rw',
	isa => sub { croak "Invalid access level $_[0]"
		unless valid_access_level($_[0]) },
	lazy => 1,
	default => ACCESS_NONE,
);

has 'strip_formatting' => (
	is => 'ro',
	coerce => sub { $_[0] ? 1 : 0 },
	lazy => 1,
	default => 1,
);

has 'tokenize' => (
	is => 'ro',
	coerce => sub { $_[0] ? 1 : 0 },
	lazy => 1,
	default => 1,
);

has 'is_enabled' => (
	is => 'rw',
	coerce => sub { $_[0] ? 1 : 0 },
	lazy => 1,
	default => 1,
);

has 'help_text' => (
	is => 'ro',
);

has 'usage_text' => (
	is => 'ro',
);

# Methods

sub run {
	my ($self, $network, $sender, $channel, @args) = @_;
	my $on_run = $self->on_run;
	local $@;
	local $SIG{__WARN__} = sub { my $msg = shift; chomp $msg; $network->logger->warn($msg) };
	my $rc;
	eval { $rc = $on_run->($network, $sender, $channel, @args); 1 };
	if ($@) {
		my $err = $@;
		chomp $err;
		my $cmd_name = $self->name;
		$network->logger->error("Error running command $cmd_name: $err");
		$network->reply($sender, $channel, "Internal error");
	} elsif (lc $rc eq 'usage') {
		my $text = 'Usage: $trigger$name';
		$text .= ' ' . $self->usage_text if defined $self->usage_text;
		$network->reply($sender, $channel, $self->parse_usage_text($network, $text));
	}
	return $self;
}

sub parse_usage_text {
	my ($self, $network, $text) = @_;
	my $trigger = $network->config->get('commands','trigger') || $network->nick . ': ';
	my $name = $self->name;
	$text =~ s/\$(?:{trigger}|trigger\b)/$trigger/g;
	$text =~ s/\$(?:{name}|name\b)/$name/g;
	return $text;
}

1;
