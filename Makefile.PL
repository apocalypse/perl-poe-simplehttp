use ExtUtils::MakeMaker;

# Build the prerequisite list
my $prereqs = {
	'HTTP::Date'			=>	0,
	'Carp'				=>	0,
	'Sys::Hostname'			=>	0,
	'POE'				=>	'0.27',
	'Storable'			=>	0,
	'Socket'			=>	0,
	'HTTP::Request'			=>	0,
	'HTTP::Response'		=>	0,
};

# Ask users if they want SSL support
my $value = prompt( 'Do you want SSL support ( requires POE::Component::SSLify ) [Y/n]?', 'Y' );

# Add to the prereqs PoCo::SSLify?
if ( $value =~ /^Y$/i ) {
	$prereqs->{ 'POE::Component::SSLify' } = '0.04';
}

# Ask users if they want PreFork support
$value = prompt( 'Do you want PreFork support ( requires IPC::Shareable ) [Y/n]?', 'Y' );

# Add to the prereqs IPC::Shareable?
if ( $value =~ /^Y$/i ) {
	$prereqs->{ 'IPC::Shareable' } = '0';
}

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
	'NAME'		=>	'POE::Component::Server::SimpleHTTP',
	'VERSION_FROM'	=>	'lib/POE/Component/Server/SimpleHTTP.pm', # finds $VERSION
	'PREREQ_PM'	=>	$prereqs,
	(	$] >= 5.005 ?		# Add new keywords
		(
			'ABSTRACT_FROM'	=> 'lib/POE/Component/Server/SimpleHTTP.pm', # retrieve abstract from module
			'AUTHOR'	=> 'Apocalypse <APOCAL@cpan.org>',
		) : ()
	),

	# Thanks POE!
	'dist'		=> {
		'PREOP'		=> (
			"echo 'license: perl' >> ./META.yml;" .
			'/bin/cp -f ./META.yml ./$(DISTNAME)-$(VERSION)/META.yml &2>/dev/null'
		),
	},
);
