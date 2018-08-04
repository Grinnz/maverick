# cpanm --installdeps --with-recommends --interactive .
# cpanm --installdeps --with-recommends --with-feature=DNS --with-feature=GeoIP --with-feature=Weather .
# cpanm --installdeps --with-recommends --with-all-features --without-feature=Hailo
requires 'perl' => '5.010001';
requires 'Autoload::AUTOCAN';
requires 'Carp';
requires 'Config::IniFiles' => '2.83';
requires 'DBM::Deep' => '2.0011';
requires 'Exporter';
requires 'File::Spec::Functions';
requires 'File::Path';
requires 'File::Temp';
requires 'FindBin';
requires 'Future::Mojo' => '0.003';
requires 'IRC::Utils' => '0.12';
requires 'List::Util';
requires 'Module::Runtime';
requires 'Mojolicious' => '7.31';
requires 'Mojo::IOLoop::Subprocess::Sereal' => '0.005';
requires 'Mojo::IRC' => '0.45';
requires 'Moo' => '2.000000';
requires 'Moo::Role' => '2.000000';
requires 'namespace::clean';
requires 'Parse::IRC' => '1.20';
requires 'Role::EventEmitter';
requires 'Scalar::Util';
requires 'Try::Tiny';
test_requires 'Test::More' => '0.88';
recommends 'IO::Socket::SSL' => '1.94';
recommends 'Mojo::JSON::MaybeXS';

feature Calc => sub {
  requires 'Math::Calc::Parser';
};
feature DNS => sub {
  requires 'Socket';
  recommends 'Net::DNS::Native', '0.15';
};
feature GeoIP => sub {
  requires 'Data::Validate::IP';
  requires 'GeoIP2', '2.000';
  recommends 'MaxMind::DB::Reader::XS';
};
feature Google => sub {
  requires 'Lingua::EN::Number::Format::MixWithWords'; # https://metacpan.org/release/SHARYANTO/Lingua-EN-Number-Format-MixWithWords-0.07
  requires 'List::UtilsBy';
};
feature Hailo => sub {
  requires 'Hailo';
};
feature LastFM => sub {
  requires 'Time::Duration';
};
feature PYX => sub {
};
feature Quotes => sub {
};
feature Repaste => sub {
};
feature Spell => sub {
  requires 'Text::Hunspell::FFI';
};
feature Translate => sub {
};
feature Twitter => sub {
  requires 'Mojo::Promise::Role::Futurify';
  requires 'Mojo::WebService::Twitter' => '1.000';
  requires 'Time::Duration';
};
feature Weather => sub {
};
feature Wikipedia => sub {
};
feature Wolfram => sub {
  requires 'Data::Validate::IP';
};
feature YouTube => sub {
  requires 'Time::Duration';
};
