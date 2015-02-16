package Bot::ZIRC::Plugin;

use Moo::Role;
use warnings NONFATAL => 'all';

requires 'register';

sub start {}
sub stop {}

1;
