package ZIRCBot::Command;

use Moose::Roles;
use ZIRCBot::Access;

requires 'name', 'strip_special', 'default_access', 'default_enabled';

enum 'ZIRCBot::AccessLevel' => [ZIRCBot::Access::access_levels];

has 'required_access' => (
	is => 'rw',
	isa => 'ZIRCBot::AccessLevel',
	builder => 'default_access',
);

has 'is_enabled' => (
	is => 'rw',
	isa => 'Bool',
	builder => 'default_enabled',
);

has 'bot' => (
	is => 'ro',
	isa => 'ZIRCBot',
	weak_ref => 1,
);

no Moose::Roles;
__PACKAGE__->meta->make_immutable;

1;

