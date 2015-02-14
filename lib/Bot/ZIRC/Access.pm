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
