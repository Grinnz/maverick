package Bot::Maverick::Command;

use Bot::Maverick::Access qw/:access valid_access_level/;
use Carp;
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

use overload 'cmp' => sub { $_[2] ? lc $_[1] cmp lc $_[0] : lc $_[0] cmp lc $_[1] },
	'""' => sub { shift->name }, bool => sub {1}, fallback => 1;

our @CARP_NOT = qw(Bot::Maverick Bot::Maverick::Network Bot::Maverick::User Bot::Maverick::Channel Moo);

our $VERSION = '0.20';

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
	my ($self, $m) = @_;
	local $SIG{__WARN__} = sub { chomp(my $msg = shift); $m->logger->warn($msg) };
	$m->bot->emit(before_command => $m);
	local $@;
	my $rc;
	unless (eval { $rc = $self->on_run->($m); 1 }) {
		chomp (my $err = $@);
		$m->reply("Internal error");
		$m->logger->error(qq{"$self" failed: $err});
	}
	if (blessed $rc and $rc->isa('Future')) {
		$m->bot->adopt_future($rc);
		$rc->on_fail(sub {
			chomp(my $err = shift);
			$m->logger->error(qq{"$self" failed: $err});
		});
	} elsif (defined $rc and lc $rc eq 'usage') {
		my $text = 'Usage: $trigger$name';
		$text .= ' ' . $self->usage_text if defined $self->usage_text;
		$m->reply($self->parse_usage_text($m->network, $text));
	}
	$m->bot->emit(after_command => $m);
	return $self;
}

sub parse_usage_text {
	my ($self, $network, $text) = @_;
	my $trigger = $network->config->param('commands','trigger');
	$trigger = $trigger ? substr $trigger, 0, 1 : $network->nick . ': ';
	$text =~ s/\$(?:{trigger}|trigger\b)/$trigger/g;
	$text =~ s/\$(?:{name}|name\b)/$self/g;
	return $text;
}

1;

=head1 NAME

Bot::Maverick::Command - User commands for Maverick

=head1 SYNOPSIS

  my $command = Bot::Maverick::Command->new(
    name => 'do_stuff',
    help_text => 'Does stuff',
    usage_text => '<thing>',
    required_access => ACCESS_BOT_VOICE,
    on_run => sub {
      my $m = shift;
      my $arg = $m->args;
      $m->reply("Did stuff with $arg");
    },
  );

=head1 DESCRIPTION

Represents a command to be recognized by a L<Bot::Maverick> IRC bot. Can also
be instantiated by the method L<Bot::Maverick/"add_command">.

=head1 ATTRIBUTES

=head2 name

Command name. Required and must be unique among commands added to the same
L<Bot::Maverick> bot.

=head2 on_run

  on_run => sub {
    my $m = shift;
  },

Required. Callback to be called when command is triggered by user. Will be
called with the L<Bot::Maverick::Message> object as an argument. Bot will reply
with C<Internal error> if an exception is thrown, but note that this does not
apply to asynchronous code. If the string C<usage> is returned, the bot will
reply with usage text.

=head2 on_more

Callback to be executed if the C<more> command from
L<Bot::Maverick::Plugin::Core> is executed on this command. Called with the
L<Bot::Maverick::Message> object as an argument. Usually intended to display
additional results from a cached result set.

=head2 help_text

Text to display to the user when help is requested for this command. Will be
automatically punctuated and have usage text appended.

=head2 usage_text

Text to display after help text or when C<usage> is returned from the
L</"on_run"> callback. Will be prepended with the command name and a trigger
if appropriate.

=head2 required_access

Access level that must be satisfied to allow user to run command. The user will
be messaged privately if this access level is not met.

=head2 strip_formatting

  strip_formatting => 0,

If set to a true value, IRC formatting codes will be stripped from the command
arguments. Defaults to 1.

=head2 is_enabled

Enable or disable command. The user will be messaged privately if attempting to
run a disabled command.

=head1 METHODS

=head2 run

  $command = $command->run($m);

Run command based on the input L<Bot::Maverick::Message>, and emit
C<before_command> and C<after_command> hooks.

=head2 parse_usage_text

  my $parsed = $command->parse_usage_text($network, $text);

Parse text, replacing instances of C<$trigger> and C<$name> with the bot's
current trigger mechanism and nick on the given network. Variables can also be
specified as C<${trigger}> or C<${name}>.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<Bot::Maverick::Message>
