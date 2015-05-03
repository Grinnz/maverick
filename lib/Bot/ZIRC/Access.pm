package Bot::ZIRC::Access;

use strict;
use warnings;
use Exporter 'import';

use constant ACCESS_LEVELS => {
	ACCESS_NONE => 0,
	ACCESS_CHANNEL_VOICE => 1,
	ACCESS_BOT_VOICE => 2,
	ACCESS_CHANNEL_HALFOP => 3,
	ACCESS_CHANNEL_OP => 4,
	ACCESS_CHANNEL_ADMIN => 5,
	ACCESS_CHANNEL_OWNER => 6,
	ACCESS_BOT_ADMIN => 7,
	ACCESS_BOT_MASTER => 8,
};
use constant ACCESS_LEVELS();

our @EXPORT = keys %{ACCESS_LEVELS()};
our @EXPORT_OK = qw/ACCESS_LEVELS access_levels valid_access_level channel_access_level/;
our %EXPORT_TAGS = (
	access => [keys %{ACCESS_LEVELS()}],
);

our $VERSION = '0.20';

my %level_nums = map { $_ => 1 } values %{ACCESS_LEVELS()};
my %channel_access = (
	'' => ACCESS_NONE,
	'+' => ACCESS_CHANNEL_VOICE,
	'%' => ACCESS_CHANNEL_HALFOP,
	'@' => ACCESS_CHANNEL_OP,
	'&' => ACCESS_CHANNEL_ADMIN,
	'~' => ACCESS_CHANNEL_OWNER,
	'-' => ACCESS_CHANNEL_OWNER,
);

sub access_levels {
	return wantarray ? (values %{ACCESS_LEVELS()}) : [values %{ACCESS_LEVELS()}];
}

sub valid_access_level {
	my $level = shift // return;
	return (exists $level_nums{$level} and $level_nums{$level}) ? 1 : '';
}

sub channel_access_level {
	my $symbol = shift // return;
	return undef unless exists $channel_access{$symbol};
	return $channel_access{$symbol};
}

1;

=head1 NAME

Bot::ZIRC::Access - Access level management for Bot::ZIRC

=head1 SYNOPSIS

  use Bot::ZIRC::Access ':access', 'valid_access_level', 'channel_access_level';
  my $valid = valid_access_level(ACCESS_BOT_VOICE);
  my $access = channel_access_level('@');

=head1 DESCRIPTION

L<Bot::ZIRC::Access> is a module to manage the access levels available for a
L<Bot::ZIRC> IRC bot. Commands and other user behavior is often dependent on
the user's access level, either internally or in the channel.

=head1 FUNCTIONS

All functions are individually exportable on demand.

=head2 access_levels

Returns a list of all available access levels.

=head2 channel_access_level

  my $access = channel_access_level('+');

Returns the access level associated with the given channel access symbol, if
any. The empty string will map to the access level of none.

=head2 valid_access_level

  my $valid = valid_access_level(ACCESS_NONE);

Returns a boolean whether the given access level is valid.

=head1 LEVELS

The recognized access levels are listed by the constants exported by the
C<:access> tag, from lowest access to highest.

=head2 ACCESS_NONE

No specific access, either to the bot or channel.

=head2 ACCESS_CHANNEL_VOICE

User is voiced in the channel, but has no bot access. Maps to channel access
C<+>.

=head2 ACCESS_BOT_VOICE

User has bot voice access, but no access (or voice access) in the channel.

=head2 ACCESS_CHANNEL_HALFOP

User has half-op access in the channel. Maps to channel access C<%>.

=head2 ACCESS_CHANNEL_OP

User has operator access in the channel. Maps to channel access C<@>.

=head2 ACCESS_CHANNEL_ADMIN

User has admin access in the channel. Maps to channel access C<&>.

=head2 ACCESS_CHANNEL_OWNER

User has owner access in the channel. Maps to channel access C<~> or C<->.

=head2 ACCESS_BOT_ADMIN

User has bot admin access.

=head2 ACCESS_BOT_MASTER

User is the configured bot master.

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
