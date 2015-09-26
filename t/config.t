use strict;
use warnings;
use Test::More;
use File::Spec::Functions 'catfile';
use File::Temp 'tempfile', 'tempdir';

use Bot::Maverick::Config;

# Empty existing file
my ($temp_fh, $temp_file) = tempfile;
my $config = Bot::Maverick::Config->new(file => $temp_file);
is $config->dir, undef, 'no dir name';
is $config->file, $temp_file, 'right filename';
is_deeply $config->to_hash, {}, 'empty configuration';

# Existing configuration file
print $temp_fh <<'EOF';
[foo]
bar=baz
baz=foo

[bar]
bar=bar
EOF

seek $temp_fh, 0, 0 or die $!;

$config = Bot::Maverick::Config->new(file => $temp_file);
is_deeply $config->to_hash, {foo => {bar => 'baz', baz => 'foo'}, bar => {bar => 'bar'}}, 'right configuration';

# Non-existing file in specified dir
my $temp_dir = tempdir(CLEANUP => 1);
my $filename = 'foo.conf';
$config = Bot::Maverick::Config->new(dir => $temp_dir, file => $filename);
is $config->dir, $temp_dir, 'right dir name';
is $config->file, $filename, 'right filename';
is_deeply $config->to_hash, {}, 'empty configuration';

# With default config hash
my $hash = {foo => {abc => 'def'}, bar => {bar => 'ghi'}};
$config = Bot::Maverick::Config->new(file => $temp_file, defaults_hash => $hash);
is_deeply $config->to_hash, {foo => {abc => 'def', bar => 'baz', baz => 'foo'}, bar => {bar => 'bar'}}, 'right configuration';
my $defaults_config = $config->defaults;
ok $defaults_config, 'has defaults config object';
is_deeply $defaults_config->to_hash, {foo => {abc => 'def'}, bar => {bar => 'ghi'}}, 'right configuration';

# With default config object
my $config2 = Bot::Maverick::Config->new(dir => $temp_dir, file => $filename, defaults => $config);
is_deeply $config2->to_hash, {foo => {abc => 'def', bar => 'baz', baz => 'foo'}, bar => {bar => 'bar'}}, 'right configuration';
is_deeply $config2->defaults->to_hash, $config->to_hash, 'defaults configuration matches';

# From existing INI object
$config2 = Bot::Maverick::Config->new(ini => $config2->ini);
is_deeply $config2->ini->GetFileName, catfile($temp_dir, $filename), 'right filename';
is_deeply $config2->to_hash, {foo => {abc => 'def', bar => 'baz', baz => 'foo'}, bar => {bar => 'bar'}}, 'right configuration';

($temp_fh, $temp_file) = tempfile;
$config = Bot::Maverick::Config->new(file => $temp_file);
is_deeply $config->to_hash, {}, 'empty configuration';

# Set configuration
$config->param('foo', 'bar', 'baz');
is_deeply $config->to_hash, {foo => {bar => 'baz'}}, 'right configuration';

# Get configuration
is $config->param('foo', 'bar'), 'baz', 'right configuration value';
is $config->param('foo', 'baz'), undef, 'no configuration value';
is $config->param('bar', 'baz'), undef, 'no configuration value';

# Set channel configuration
$config->channel_param(undef, 'foo', 'bar');
is_deeply $config->to_hash, {foo => {bar => 'baz'}, network => {foo => 'bar'}}, 'right configuration';
$config->channel_param('network', 'foo', 'ban');
is_deeply $config->to_hash, {foo => {bar => 'baz'}, network => {foo => 'ban'}}, 'right configuration';
$config->channel_param('#foo', 'foo', 'baz');
is_deeply $config->to_hash, {foo => {bar => 'baz'}, network => {foo => 'ban'}, '#foo' => {foo => 'baz'}}, 'right configuration';

# Get channel configuration
is $config->channel_param(undef, 'foo'), 'ban', 'right configuration';
is $config->channel_param('network', 'foo'), 'ban', 'right configuration';
is $config->channel_param('#foo', 'foo'), 'baz', 'right configuration';
is $config->channel_param('#bar', 'foo'), 'ban', 'right configuration';
is $config->channel_param('#foo', 'bar'), undef, 'no configuration value';
is $config->channel_param('#bar', 'bar'), undef, 'no configuration value';

done_testing;
