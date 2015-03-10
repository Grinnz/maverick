package Bot::ZIRC::Command;

use Bot::ZIRC::Access qw/:access valid_access_level/;
use Carp;
use Scalar::Util 'blessed';

use Moo 2;
use namespace::clean;

use overload '""' => sub { shift->name }, 'cmp' => sub { $_[2] ? lc $_[1] cmp lc $_[0] : lc $_[0] cmp lc $_[1] };

our @CARP_NOT = qw(Bot::ZIRC Bot::ZIRC::Network Bot::ZIRC::User Bot::ZIRC::Channel Moo);

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

has 'on_more' => (
	is => 'ro',
	isa => sub { croak "Invalid on_more subroutine $_[0]"
		unless defined $_[0] and ref $_[0] eq 'CODE' },
	predicate => 1,
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
	my $before_hooks = $network->get_hooks('before_command');
	my $after_hooks = $network->get_hooks('after_command');
	my $on_run = $self->on_run;
	local $SIG{__WARN__} = sub { my $msg = shift; chomp $msg; $network->logger->warn($msg) };
	foreach my $hook (@$before_hooks) {
		local $@;
		eval { $self->$hook($network, $sender, $channel, @args) };
		$network->logger->error("Error in before-command hook: $@") if $@;
	}
	local $@;
	my $rc = eval { $on_run->($network, $sender, $channel, @args) };
	if ($@) {
		my $err = $@;
		chomp $err;
		$network->logger->error("Error running command $self: $err");
		$network->reply($sender, $channel, "Internal error");
	} elsif (defined $rc and lc $rc eq 'usage') {
		my $text = 'Usage: $trigger$name';
		$text .= ' ' . $self->usage_text if defined $self->usage_text;
		$network->reply($sender, $channel, $self->parse_usage_text($network, $text));
	}
	foreach my $hook (@$after_hooks) {
		local $@;
		eval { $self->$hook($network, $sender, $channel, @args) };
		$network->logger->error("Error in after-command hook: $@") if $@;
	}
	return $self;
}

sub parse_usage_text {
	my ($self, $network, $text) = @_;
	my $trigger = $network->config->get('commands','trigger');
	$trigger = $trigger ? substr $trigger, 0, 1 : $network->nick . ': ';
	$text =~ s/\$(?:{trigger}|trigger\b)/$trigger/g;
	$text =~ s/\$(?:{name}|name\b)/$self/g;
	return $text;
}

1;
