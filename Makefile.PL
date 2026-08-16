use ExtUtils::MakeMaker;
WriteMakefile(
  NAME => 'HTTP::API::Client',
  VERSION_FROM => 'lib/HTTP/API/Client.pm',
  PREREQ_PM => {
    'HTTP::Tiny'   => 0,
    'JSON::PP'     => 0,
    'Scalar::Util' => 0,
    'Time::HiRes'  => 0,
  },
);
