package ZIRCBot::Command;

use ZIRCBot::Access;
use Scalar::Util 'blessed';

use Moo::Role;
use warnings NONFATAL => 'all';

requires 'name', 'strip_special', 'default_access', 'default_enabled';

has 'required_access' => (
	is => 'rw',
	isa => sub { die 'Invalid access level' unless ZIRCBot::Access::valid_access_level($_[0]) },
	builder => 'default_access',
);

has 'is_enabled' => (
	is => 'rw',
	coerce => sub { $_[0] ? 1 : 0 },
	builder => 'default_enabled',
);

has 'bot' => (
	is => 'ro',
	isa => sub { die 'Invalid ZIRCBot reference' unless defined $_[0] and blessed $_[0] and $_[0]->isa('ZIRCBot') },
	weak_ref => 1,
);

1;

