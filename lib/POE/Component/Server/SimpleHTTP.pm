# Declare our package
package POE::Component::Server::SimpleHTTP;

# Standard stuff to catch errors
use strict qw(subs vars refs);				# Make sure we can't mess up
use warnings FATAL => 'all';				# Enable warnings to catch errors

# Initialize our version
# $Revision: 1181 $
our $VERSION = '1.13';

# Import what we need from the POE namespace
use POE;
use POE::Wheel::SocketFactory;
use POE::Wheel::ReadWrite;
use POE::Driver::SysRW;
use POE::Filter::HTTPD;

# Other miscellaneous modules we need
use Carp qw( croak );

# HTTP-related modules
use HTTP::Date qw( time2str );

# Our own HTTP modules
use POE::Component::Server::SimpleHTTP::Connection;
use POE::Component::Server::SimpleHTTP::Response;

# Set some constants
BEGIN {
	# Debug fun!
	if ( ! defined &DEBUG ) {
		eval "sub DEBUG () { 0 }";
	}

	# Our own definition of the max retries
	if ( ! defined &MAX_RETRIES ) {
		eval "sub MAX_RETRIES () { 5 }";
	}
}

# Set things in motion!
sub new {
	# Get the OOP's type
	my $type = shift;

	# Sanity checking
	if ( @_ & 1 ) {
		croak( 'POE::Component::Server::SimpleHTTP->new needs even number of options' );
	}

	# The options hash
	my %opt = @_;

	# Our own options
	my ( $ALIAS, $ADDRESS, $PORT, $HOSTNAME, $HEADERS, $HANDLERS, $SSLKEYCERT );

	# You could say I should do this: $Stuff = delete $opt{'Stuff'}
	# But, that kind of behavior is not defined, so I would not trust it...

	# Get the SSL array
	if ( exists $opt{'SSLKEYCERT'} and defined $opt{'SSLKEYCERT'} ) {
		# Test if it is an array
		if ( ref( $opt{'SSLKEYCERT'} ) eq 'ARRAY' and scalar( @{ $opt{'SSLKEYCERT'} } ) == 2 ) {
			$SSLKEYCERT = $opt{'SSLKEYCERT'};
			delete $opt{'SSLKEYCERT'};

			# Okay, pull in what is necessary
			eval {
				use POE::Component::SSLify qw( SSLify_Options SSLify_GetSocket Server_SSLify SSLify_GetCipher );
				SSLify_Options( @$SSLKEYCERT );
			};
			if ( $@ ) {
				if ( DEBUG ) {
					warn "Unable to load PoCo::SSLify -> $@";
				}

				# Force ourself to not use SSL
				$SSLKEYCERT = undef;
			}
		} else {
			if ( DEBUG ) {
				warn 'The SSLKEYCERT option must be an array with exactly 2 elements in it!';
			}
		}
	} else {
		$SSLKEYCERT = undef;
	}

	# Get the session alias
	if ( exists $opt{'ALIAS'} and defined $opt{'ALIAS'} and length( $opt{'ALIAS'} ) ) {
		$ALIAS = $opt{'ALIAS'};
		delete $opt{'ALIAS'};
	} else {
		# Debugging info...
		if ( DEBUG ) {
			warn 'Using default ALIAS = SimpleHTTP';
		}

		# Set the default
		$ALIAS = 'SimpleHTTP';

		# Get rid of any lingering ALIAS
		if ( exists $opt{'ALIAS'} ) {
			delete $opt{'ALIAS'};
		}
	}

	# Get the PORT
	if ( exists $opt{'PORT'} and defined $opt{'PORT'} and length( $opt{'PORT'} ) ) {
		$PORT = $opt{'PORT'};
		delete $opt{'PORT'};
	} else {
		croak( 'PORT is required to create a new POE::Component::Server::SimpleHTTP instance!' );
	}

	# Get the ADDRESS
	if ( exists $opt{'ADDRESS'} and defined $opt{'ADDRESS'} and length( $opt{'ADDRESS'} ) ) {
		$ADDRESS = $opt{'ADDRESS'};
		delete $opt{'ADDRESS'};
	} else {
		croak( 'ADDRESS is required to create a new POE::Component::Server::SimpleHTTP instance!' );
	}

	# Get the HOSTNAME
	if ( exists $opt{'HOSTNAME'} and defined $opt{'HOSTNAME'} and length( $opt{'HOSTNAME'} ) ) {
		$HOSTNAME = $opt{'HOSTNAME'};
		delete $opt{'HOSTNAME'};
	} else {
		if ( DEBUG ) {
			warn 'Using Sys::Hostname for HOSTNAME';
		}

		# Figure out the hostname
		require Sys::Hostname;
		$HOSTNAME = Sys::Hostname::hostname();

		# Get rid of any lingering HOSTNAME
		if ( exists $opt{'HOSTNAME'} ) {
			delete $opt{'HOSTNAME'};
		}
	}

	# Get the HEADERS
	if ( exists $opt{'HEADERS'} and defined $opt{'HEADERS'} ) {
		# Make sure it is ref to hash
		if ( ref $opt{'HEADERS'} and ref( $opt{'HEADERS'} ) eq 'HASH' ) {
			$HEADERS = $opt{'HEADERS'};
			delete $opt{'HEADERS'};
		} else {
			croak( 'HEADERS must be a reference to a HASH!' );
		}
	} else {
		# Set to none
		$HEADERS = {};

		# Get rid of any lingering HEADERS
		if ( exists $opt{'HEADERS'} ) {
			delete $opt{'HEADERS'};
		}
	}

	# Get the HANDLERS
	if ( exists $opt{'HANDLERS'} and defined $opt{'HANDLERS'} ) {
		# Make sure it is ref to array
		if ( ref $opt{'HANDLERS'} and ref( $opt{'HANDLERS'} ) eq 'ARRAY' ) {
			$HANDLERS = $opt{'HANDLERS'};
			delete $opt{'HANDLERS'};
		} else {
			croak( 'HANDLERS must be a reference to an ARRAY!' );
		}
	} else {
		croak( 'HANDLERS is required to create a new POE::Component::Server::SimpleHTTP instance!' );
	}

	# Anything left over is unrecognized
	if ( DEBUG ) {
		if ( keys %opt > 0 ) {
			croak( 'Unrecognized options were present in POE::Component::Server::SimpleHTTP->new -> ' . join( ', ', keys %opt ) );
		}
	}

	# Create a new session for ourself
	POE::Session->create(
		# Our subroutines
		'inline_states'	=>	{
			# Maintenance events
			'_start'	=>	\&StartServer,
			'_stop'		=>	\&FindRequestLeaks,
			'_child'	=>	sub {},

			# HANDLER stuff
			'GETHANDLERS'	=>	\&GetHandlers,
			'SETHANDLERS'	=>	\&SetHandlers,

			# SocketFactory events
			'SHUTDOWN'	=>	\&StopServer,
			'STOPLISTEN'	=>	\&StopListen,
			'STARTLISTEN'	=>	\&StartListen,
			'SetupListener'	=>	\&SetupListener,
			'ListenerError'	=>	\&ListenerError,

			# Wheel::ReadWrite stuff
			'Got_Connection'	=>	\&Got_Connection,
			'Got_Input'		=>	\&Got_Input,
			'Got_Flush'		=>	\&Got_Flush,
			'Got_Error'		=>	\&Got_Error,

			# Send output to connection!
			'DONE'		=>	\&Request_Output,

			# Kill the connection!
			'CLOSE'		=>	\&Request_Close,
		},

		# Set up the heap for ourself
		'heap'		=>	{
			'ALIAS'		=>	$ALIAS,
			'ADDRESS'	=>	$ADDRESS,
			'PORT'		=>	$PORT,
			'HEADERS'	=>	$HEADERS,
			'HOSTNAME'	=>	$HOSTNAME,
			'HANDLERS'	=>	$HANDLERS,
			'REQUESTS'	=>	{},
			'RETRIES'	=>	0,
			'SSLKEYCERT'	=>	$SSLKEYCERT,
		},
	) or die 'Unable to create a new session!';

	# Return success
	return 1;
}

# This subroutine, when SimpleHTTP exits, will search for leaks
sub FindRequestLeaks {
	# Loop through all of the requests
	foreach my $req ( keys %{ $_[HEAP]->{'REQUESTS'} } ) {
		# Bite the programmer!
		warn 'Did not get DONE/CLOSE event for Wheel ID ' . $req . ' from IP ' . $_[HEAP]->{'REQUESTS'}->{ $req }->[2]->connection->remote_ip;
	}

	# All done!
	return 1;
}

# Starts the server!
sub StartServer {
	# Debug stuff
	if ( DEBUG ) {
		warn 'Starting up SimpleHTTP now';
	}

	# Register an alias for ourself
	$_[KERNEL]->alias_set( $_[HEAP]->{'ALIAS'} );

	# Massage the handlers!
	MassageHandlers( $_[HEAP]->{'HANDLERS'} );

	# Setup the wheel
	$_[KERNEL]->yield( 'SetupListener' );

	# All done!
	return 1;
}

# Stops the server!
sub StopServer {
	# Shutdown the SocketFactory wheel
	if ( exists $_[HEAP]->{'SOCKETFACTORY'} ) {
		delete $_[HEAP]->{'SOCKETFACTORY'};
	}

	# Debug stuff
	if ( DEBUG ) {
		warn 'Stopped listening for new connections!';
	}

	# Are we gracefully shutting down or not?
	if ( defined $_[ARG0] and $_[ARG0] eq 'GRACEFUL' ) {
		# Check for number of requests
		if ( keys( %{ $_[HEAP]->{'REQUESTS'} } ) == 0 ) {
			# Alright, shutdown anyway

			# Delete our alias
			$_[KERNEL]->alias_remove( $_[HEAP]->{'ALIAS'} );

			# Debug stuff
			if ( DEBUG ) {
				warn 'Stopped SimpleHTTP gracefully, no requests left';
			}
		}

		# All done!
		return 1;
	}

	# Forcibly close all sockets that are open
	foreach my $conn ( keys %{ $_[HEAP]->{'REQUESTS'} } ) {
		# Can't call method "shutdown_input" on an undefined value at
		# /usr/lib/perl5/site_perl/5.8.2/POE/Component/Server/SimpleHTTP.pm line 323.
		if ( defined $_[HEAP]->{'REQUESTS'}->{ $conn }->[0] and defined $_[HEAP]->{'REQUESTS'}->{ $conn }->[0]->[ POE::Wheel::ReadWrite::HANDLE_INPUT ] ) {
			$_[HEAP]->{'REQUESTS'}->{ $conn }->[0]->shutdown_input;
			$_[HEAP]->{'REQUESTS'}->{ $conn }->[0]->shutdown_output;
		}

		# Delete this request
		delete $_[HEAP]->{'REQUESTS'}->{ $conn };
	}

	# Delete our alias
	$_[KERNEL]->alias_remove( $_[HEAP]->{'ALIAS'} );

	# Debug stuff
	if ( DEBUG ) {
		warn 'Successfully stopped SimpleHTTP';
	}

	# Return success
	return 1;
}

# Sets up the SocketFactory wheel :)
sub SetupListener {
	# Debug stuff
	if ( DEBUG ) {
		warn 'Creating SocketFactory wheel now';
	}

	# Check if we should set up the wheel
	if ( $_[HEAP]->{'RETRIES'} == MAX_RETRIES ) {
		die 'POE::Component::Server::SimpleHTTP tried ' . MAX_RETRIES . ' times to create a Wheel and is giving up...';
	} else {
		# Increment the retry count if we did not get 'NOINC' as an argument
		if ( ! defined $_[ARG0] ) {
			# Increment the retries count
			$_[HEAP]->{'RETRIES'}++;
		}

		# Create our own SocketFactory Wheel :)
		$_[HEAP]->{'SOCKETFACTORY'} = POE::Wheel::SocketFactory->new(
			'BindPort'	=>	$_[HEAP]->{'PORT'},
			'BindAddress'	=>	$_[HEAP]->{'ADDRESS'},
			'Reuse'		=>	'yes',
			'SuccessEvent'	=>	'Got_Connection',
			'FailureEvent'	=>	'ListenerError',
		);
	}

	# Success!
	return 1;
}

# Got some sort of error from SocketFactory
sub ListenerError {
	# ARG0 = operation, ARG1 = error number, ARG2 = error string, ARG3 = wheel ID
	my ( $operation, $errnum, $errstr, $wheel_id ) = @_[ ARG0 .. ARG3 ];

	# Debug stuff
	if ( DEBUG ) {
		warn "SocketFactory Wheel $wheel_id generated $operation error $errnum: $errstr\n";
	}

	# Setup the SocketFactory wheel
	$_[KERNEL]->call( $_[SESSION], 'SetupListener' );

	# Success!
	return 1;
}

# Starts listening on the socket
sub StartListen {
	if ( DEBUG ) {
		warn 'STARTLISTEN called, resuming accepts on SocketFactory';
	}

	# Setup the SocketFactory wheel
	$_[KERNEL]->call( $_[SESSION], 'SetupListener', 'NOINC' );

	# All done!
	return 1;
}

# Stops listening on the socket
sub StopListen {
	if ( DEBUG ) {
		warn 'STOPLISTEN called, pausing accepts on SocketFactory';
	}

	# We have to get rid of the SocketFactory wheel...
	if ( exists $_[HEAP]->{'SOCKETFACTORY'} ) {
		$_[HEAP]->{'SOCKETFACTORY'} = undef;
	}

	# All done!
	return 1;
}

# Sets the HANDLERS
sub SetHandlers {
	# ARG0 = ref to handlers array
	my $handlers = $_[ARG0];

	# Validate it...
	MassageHandlers( $handlers );

	# If we got here, passed tests!
	$_[HEAP]->{'HANDLERS'} = $handlers;

	# All done!
	return 1;
}

# Gets the HANDLERS
sub GetHandlers {
	# ARG0 = session, ARG1 = event
	my( $session, $event ) = @_[ ARG0, ARG1 ];

	# Validation
	if ( ! defined $session or ! defined $event ) {
		return undef;
	}

	# Make a deep copy of the handlers
	require Storable;

	my $handlers = Storable::dclone( $_[HEAP]->{'HANDLERS'} );

	# Remove the RE part
	foreach my $ary ( @$handlers ) {
		delete $ary->{'RE'};
	}

	# All done!
	$_[KERNEL]->post( $session, $event, $handlers );

	# All done!
	return 1;
}

# This subroutine massages the HANDLERS for internal use
sub MassageHandlers {
	# Get the ref to handlers
	my $handler = shift;

	# Make sure it is ref to array
	if ( ! ref $handler or ref( $handler ) ne 'ARRAY' ) {
		croak( "HANDLERS is not a ref to an array!" );
	}

	# Massage the handlers
	my $count = 0;
	while ( $count < scalar( @$handler ) ) {
		# Must be ref to hash
		if ( ref $handler->[ $count ] and ref( $handler->[ $count ] ) eq 'HASH' ) {
			# Make sure it got the 3 parts necessary
			if ( ! exists $handler->[ $count ]->{'SESSION'} or ! defined $handler->[ $count ]->{'SESSION'} ) {
				croak( "HANDLER number $count does not have a SESSION argument!" );
			}
			if ( ! exists $handler->[ $count ]->{'EVENT'} or ! defined $handler->[ $count ]->{'EVENT'} ) {
				croak( "HANDLER number $count does not have an EVENT argument!" );
			}
			if ( ! exists $handler->[ $count ]->{'DIR'} or ! defined $handler->[ $count ]->{'DIR'} ) {
				croak( "HANDLER number $count does not have a DIR argument!" );
			}

			# Convert SESSION to ID
			if ( UNIVERSAL::isa( $handler->[ $count ]->{'SESSION'}, 'POE::Session' ) ) {
				$handler->[ $count ]->{'SESSION'} = $handler->[ $count ]->{'SESSION'}->ID;
			}

			# Convert DIR to qr// format
			my $regex = undef;
			eval { $regex = qr/$handler->[ $count ]->{'DIR'}/ };

			# Check for errors
			if ( $@ ) {
				croak( "HANDLER number $count has a malformed DIR -> $@" );
			} else {
				# Store it!
				$handler->[ $count ]->{'RE'} = $regex;
			}
		} else {
			croak( "HANDLER number $count is not a reference to a HASH!" );
		}

		# Done with this one!
		$count++;
	}

	# Got here, success!
	return 1;
}

# The actual manager of connections
sub Got_Connection {
	# ARG0 = Socket, ARG1 = Remote Address, ARG2 = Remote Port
	my $socket = $_[ ARG0 ];

	# Should we SSLify it?
	if ( defined $_[HEAP]->{'SSLKEYCERT'} ) {
		# SSLify it!
		eval { $socket = Server_SSLify( $socket ) };
		if ( $@ ) {
			warn "Unable to turn on SSL for connection from " . Socket::inet_ntoa( $_[ARG1] ) . " -> $@";
			close $socket;
			return 1;
		}
	}

	# Set up the Wheel to read from the socket
	my $wheel = POE::Wheel::ReadWrite->new(
		'Handle'	=>	$socket,
		'Driver'	=>	POE::Driver::SysRW->new(),
		'Filter'	=>	POE::Filter::HTTPD->new(),
		'InputEvent'	=>	'Got_Input',
		'FlushedEvent'	=>	'Got_Flush',
		'ErrorEvent'	=>	'Got_Error',
	);

	# Save this wheel!
	# 0 = wheel, 1 = Output done?, 2 = SimpleHTTP::Response object
	$_[HEAP]->{'REQUESTS'}->{ $wheel->ID } = [ $wheel, 0, undef ];

	# Debug stuff
	if ( DEBUG ) {
		warn "Got_Connection completed creation of ReadWrite wheel ( " . $wheel->ID . " )";
	}

	# Success!
	return 1;
}

# Finally got input, set some stuff and send away!
sub Got_Input {
	# ARG0 = HTTP::Request object, ARG1 = Wheel ID
	my( $request, $id ) = @_[ ARG0, ARG1 ];

	# Quick check to see if the socket died already...
	# Initially reported by Tim Wood
	if ( ! defined $_[HEAP]->{'REQUESTS'}->{ $id }->[0] or ! defined $_[HEAP]->{'REQUESTS'}->{ $id }->[0]->[ POE::Wheel::ReadWrite::HANDLE_INPUT ] ) {
		if ( DEBUG ) {
			warn 'Got a request, but socket died already!';
		}

		# Destroy this wheel!
		delete $_[HEAP]->{'REQUESTS'}->{ $id }->[0];
		delete $_[HEAP]->{'REQUESTS'}->{ $id };

		# All done!
		return;
	}

	# The HTTP::Response object, the path
	my ( $response, $path );

	# Check if it is HTTP::Request or Response
	# Quoting POE::Filter::HTTPD
	# The HTTPD filter parses the first HTTP 1.0 request from an incoming stream into an
	# HTTP::Request object (if the request is good) or an HTTP::Response object (if the
	# request was malformed).
	if ( ref( $request ) eq 'HTTP::Response' ) {
		# Make the request nothing
		$response = $request;
		$request = undef;

		# Hack it to simulate POE::Component::Server::SimpleHTTP::Response->new( $id, $conn );
		bless( $response, 'POE::Component::Server::SimpleHTTP::Response' );
		$response->{'WHEEL_ID'} = $id;

		# Directly access POE::Wheel::ReadWrite's HANDLE_INPUT -> to get the socket itself
		# Hmm, if we are SSL, then have to do an extra step!
		if ( defined $_[HEAP]->{'SSLKEYCERT'} ) {
			$response->{'CONNECTION'} = POE::Component::Server::SimpleHTTP::Connection->new( SSLify_GetSocket( $_[HEAP]->{'REQUESTS'}->{ $id }->[0]->[ POE::Wheel::ReadWrite::HANDLE_INPUT ] ) );
		} else {
			$response->{'CONNECTION'} = POE::Component::Server::SimpleHTTP::Connection->new( $_[HEAP]->{'REQUESTS'}->{ $id }->[0]->[ POE::Wheel::ReadWrite::HANDLE_INPUT ] );
		}

		# Set the path to an empty string
		$path = '';
	} else {
		# Add stuff it needs!
		my $uri = $request->uri;
		$uri->scheme( 'http' );
		$uri->host( $_[HEAP]->{'HOSTNAME'} );
		$uri->port( $_[HEAP]->{'PORT'} );

		# Get the path
		$path = $uri->path();
		if ( ! defined $path or $path eq '' ) {
			# Make it the default handler
			$path = '/';
		}

		# Get the response
		# Directly access POE::Wheel::ReadWrite's HANDLE_INPUT -> to get the socket itself
		# Hmm, if we are SSL, then have to do an extra step!
		if ( defined $_[HEAP]->{'SSLKEYCERT'} ) {
			$response = POE::Component::Server::SimpleHTTP::Response->new(
				$id,
				POE::Component::Server::SimpleHTTP::Connection->new( SSLify_GetSocket( $_[HEAP]->{'REQUESTS'}->{ $id }->[0]->[ POE::Wheel::ReadWrite::HANDLE_INPUT ] ) )
			);
		} else {
			$response = POE::Component::Server::SimpleHTTP::Response->new(
				$id,
				POE::Component::Server::SimpleHTTP::Connection->new( $_[HEAP]->{'REQUESTS'}->{ $id }->[0]->[ POE::Wheel::ReadWrite::HANDLE_INPUT ] )
			);
		}

		# Stuff the default headers
		if ( keys( %{ $_[HEAP]->{'HEADERS'} } ) != 0 ) {
			$response->header( %{ $_[HEAP]->{'HEADERS'} } );
		}
	}

	# Check if the SimpleHTTP::Connection object croaked ( happens when sockets just disappear )
	if ( ! defined $response->{'CONNECTION'} ) {
		# Debug stuff
		if ( DEBUG ) {
			warn "could not make connection object";
		}

		# Destroy this wheel!
		delete $_[HEAP]->{'REQUESTS'}->{ $id }->[0];
		delete $_[HEAP]->{'REQUESTS'}->{ $id };

		# All done!
		return;
	} else {
		# If we used SSL, turn on the flag!
		if ( defined $_[HEAP]->{'SSLKEYCERT'} ) {
			$response->{'CONNECTION'}->{'SSLified'} = 1;

			# Put the cipher type for people who want it
			$response->{'CONNECTION'}->{'SSLCipher'} = SSLify_GetCipher( $_[HEAP]->{'REQUESTS'}->{ $id }->[0]->[ POE::Wheel::ReadWrite::HANDLE_INPUT ] );
		}
	}

	# Add this response to the wheel
	$_[HEAP]->{'REQUESTS'}->{ $id }->[2] = $response;

	# Find which handler will handle this one
	foreach my $handler ( @{ $_[HEAP]->{'HANDLERS'} } ) {
		# Check if this matches
		if ( $path =~ $handler->{'RE'} ) {
			# Send this off!
			$_[KERNEL]->post(	$handler->{'SESSION'},
						$handler->{'EVENT'},
						$request,
						$response,
						$handler->{'DIR'},
			);

			# All done!
			return;
		}
	}

	# If we reached here, no handler was able to handle it...
	die 'No handler was able to handle ' . $path;
}

# Finished with a request!
sub Got_Flush {
	# ARG0 = wheel ID
	my $id = $_[ ARG0 ];

	# Debug stuff
	if ( DEBUG ) {
		warn "Got Flush event for wheel ID ( $id )";
	}

	# Check if we are shutting down
	if ( $_[HEAP]->{'REQUESTS'}->{ $id }->[1] ) {
		# Shutdown read/write on the wheel
		$_[HEAP]->{'REQUESTS'}->{ $id }->[0]->shutdown_input();
		$_[HEAP]->{'REQUESTS'}->{ $id }->[0]->shutdown_output();

		# Delete the wheel
		# Tracked down by Paul Visscher
		delete $_[HEAP]->{'REQUESTS'}->{ $id }->[0];
		delete $_[HEAP]->{'REQUESTS'}->{ $id };
	} else {
		# Ignore this, eh?
		if ( DEBUG ) {
			warn "Got Flush event for socket ( $id ) when we did not send anything!";
		}
	}

	# Alright, do we have to shutdown?
	if ( ! exists $_[HEAP]->{'SOCKETFACTORY'} ) {
		# Check to see if we have any more requests
		if ( keys( %{ $_[HEAP]->{'REQUESTS'} } ) == 0 ) {
			# Shutdown!
			$_[KERNEL]->yield( 'SHUTDOWN' );
		}
	}

	# Success!
	return 1;
}

# Got some sort of error from ReadWrite
sub Got_Error {
	# ARG0 = operation, ARG1 = error number, ARG2 = error string, ARG3 = wheel ID
	my ( $operation, $errnum, $errstr, $id ) = @_[ ARG0 .. ARG3 ];

	# Only do this for non-EOF on read
	unless ( $operation eq 'read' and $errnum == 0 ) {
		# Debug stuff
		if ( DEBUG ) {
			warn "Wheel $id generated $operation error $errnum: $errstr\n";
		}

		# Make the client dead
		$_[HEAP]->{'REQUESTS'}->{ $id }->[2]->{'CONNECTION'}->{'DIED'} = 1;

		# Delete this connection
		delete $_[HEAP]->{'REQUESTS'}->{ $id };
	}

	# Success!
	return 1;
}

# Output to the client!
sub Request_Output {
	# ARG0 = HTTP::Response object
	my $response = $_[ ARG0 ];

	# Check if we got it
	if ( ! defined $response or ! UNIVERSAL::isa( $response, 'HTTP::Response' ) ) {
		if ( DEBUG ) {
			warn 'Did not get a HTTP::Response object!';
		}

		# Abort...
		return undef;
	}

	# Get the wheel ID
	my $id = $response->_WHEEL;

	# Check if the wheel exists ( sometimes it gets closed by the client, but the application doesn't know that... )
	if ( ! exists $_[HEAP]->{'REQUESTS'}->{ $id } ) {
		# Debug stuff
		if ( DEBUG ) {
			warn 'Wheel disappeared, but the application sent us a DONE event, discarding it';
		}

		# All done!
		return 1;
	}

	# Check if we have already sent the response
	if ( $_[HEAP]->{'REQUESTS'}->{ $id }->[1] ) {
		# Tried to send twice!
		die 'Tried to send a response to the same connection twice!';
	}

	# Quick check to see if the wheel/socket died already...
	# Initially reported by Tim Wood
	if ( ! defined $_[HEAP]->{'REQUESTS'}->{ $id }->[0] or ! defined $_[HEAP]->{'REQUESTS'}->{ $id }->[0]->[ POE::Wheel::ReadWrite::HANDLE_INPUT ] ) {
		if ( DEBUG ) {
			warn 'Tried to send data over a closed/nonexistant socket!';
		}
		return;
	}

	# Set the date if needed
	if ( ! $response->header( 'Date' ) ) {
		$response->header( 'Date', time2str( time ) );
	}

	# Set the Content-Length if needed
	if ( ! $response->header( 'Content-Length' ) ) {
		use bytes;
		$response->header( 'Content-Length', length( $response->content ) );
	}

	# Set the Content-Type if needed
	if ( ! $response->header( 'Content-Type' ) ) {
		$response->header( 'Content-Type', 'text/html' );
	}

	# Send it out!
	$_[HEAP]->{'REQUESTS'}->{ $id }->[0]->put( $response );

	# Mark this socket done
	$_[HEAP]->{'REQUESTS'}->{ $id }->[1] = 1;

	# Debug stuff
	if ( DEBUG ) {
		warn "Completed with Wheel ID $id";
	}

	# Success!
	return 1;
}

# Closes the connection
sub Request_Close {
	# ARG0 = HTTP::Response object
	my $response = $_[ ARG0 ];

	# Check if we got it
	if ( ! defined $response or ! UNIVERSAL::isa( $response, 'HTTP::Response' ) ) {
		if ( DEBUG ) {
			warn 'Did not get a HTTP::Response object!';
		}

		# Abort...
		return undef;
	}

	# Get the wheel ID
	my $id = $response->_WHEEL;

	# Check if the wheel exists ( sometimes it gets closed by the client, but the application doesn't know that... )
	if ( ! exists $_[HEAP]->{'REQUESTS'}->{ $id } ) {
		# Debug stuff
		if ( DEBUG ) {
			warn 'Wheel disappeared, but the application sent us a CLOSE event, discarding it';
		}

		# All done!
		return 1;
	}

	# Kill it!
	if ( defined $_[HEAP]->{'REQUESTS'}->{ $id }->[0] and defined $_[HEAP]->{'REQUESTS'}->{ $id }->[0]->[ POE::Wheel::ReadWrite::HANDLE_INPUT ] ) {
		$_[HEAP]->{'REQUESTS'}->{ $id }->[0]->shutdown_input;
		$_[HEAP]->{'REQUESTS'}->{ $id }->[0]->shutdown_output;
	}

	# Delete it!
	delete $_[HEAP]->{'REQUESTS'}->{ $id }->[0];
	delete $_[HEAP]->{'REQUESTS'}->{ $id };

	# All done!
	return 1;
}

# End of module
1;

__END__

=head1 NAME

POE::Component::Server::SimpleHTTP - Perl extension to serve HTTP requests in POE.

=head1 SYNOPSIS

	use POE;
	use POE::Component::Server::SimpleHTTP;

	# Start the server!
	POE::Component::Server::SimpleHTTP->new(
		'ALIAS'		=>	'HTTPD',
		'ADDRESS'	=>	'192.168.1.1',
		'PORT'		=>	11111,
		'HOSTNAME'	=>	'MySite.com',
		'HANDLERS'	=>	[
			{
				'DIR'		=>	'^/bar/.*',
				'SESSION'	=>	'HTTP_GET',
				'EVENT'		=>	'GOT_BAR',
			},
			{
				'DIR'		=>	'^/$',
				'SESSION'	=>	'HTTP_GET',
				'EVENT'		=>	'GOT_MAIN',
			},
			{
				'DIR'		=>	'^/foo/.*',
				'SESSION'	=>	'HTTP_GET',
				'EVENT'		=>	'GOT_NULL',
			},
			{
				'DIR'		=>	'.*',
				'SESSION'	=>	'HTTP_GET',
				'EVENT'		=>	'GOT_ERROR',
			},
		],

		# In the testing phase...
		'SSLKEYCERT'	=>	[ 'public-key.pem', 'public-cert.pem' ],
	) or die 'Unable to create the HTTP Server';

	# Create our own session to receive events from SimpleHTTP
	POE::Session->create(
		inline_states => {
			'_start'	=>	sub {	$_[KERNEL]->alias_set( 'HTTP_GET' );
							$_[KERNEL]->post( 'HTTPD', 'GETHANDLERS', $_[SESSION], 'GOT_HANDLERS' );
						},

			'GOT_BAR'	=>	\&GOT_REQ,
			'GOT_MAIN'	=>	\&GOT_REQ,
			'GOT_ERROR'	=>	\&GOT_ERR,
			'GOT_NULL'	=>	\&GOT_NULL,
			'GOT_HANDLERS'	=>	\&GOT_HANDLERS,
		},
	);

	# Start POE!
	POE::Kernel->run();

	sub GOT_HANDLERS {
		# ARG0 = HANDLERS array
		my $handlers = $_[ ARG0 ];

		# Move the first handler to the last one
		push( @$handlers, shift( @$handlers ) );

		# Send it off!
		$_[KERNEL]->post( 'HTTPD', 'SETHANDLERS', $handlers );
	}

	sub GOT_NULL {
		# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
		my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];

		# Kill this!
		$_[KERNEL]->post( 'HTTPD', 'CLOSE', $response );
	}

	sub GOT_REQ {
		# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
		my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];

		# Do our stuff to HTTP::Response
		$response->code( 200 );
		$response->content( 'Some funky HTML here' );

		# We are done!
		# For speed, you could use $_[KERNEL]->call( ... )
		$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
	}

	sub GOT_ERR {
		# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
		my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];

		# Check for errors
		if ( ! defined $request ) {
			$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
			return;
		}

		# Do our stuff to HTTP::Response
		$response->code( 404 );
		$response->content( "Hi visitor from " . $response->connection->remote_ip . ", Page not found -> '" . $request->uri->path . "'" );

		# We are done!
		# For speed, you could use $_[KERNEL]->call( ... )
		$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
	}

=head1 ABSTRACT

	An easy to use HTTP daemon for POE-enabled programs

=head1 DESCRIPTION

This module makes serving up HTTP requests a breeze in POE.

The hardest thing to understand in this module is the HANDLERS. That's it!

The standard way to use this module is to do this:

	use POE;
	use POE::Component::Server::SimpleHTTP;

	POE::Component::Server::SimpleHTTP->new( ... );

	POE::Session->create( ... );

	POE::Kernel->run();

=head2 Starting SimpleHTTP

To start SimpleHTTP, just call it's new method:

	POE::Component::Server::SimpleHTTP->new(
		'ALIAS'		=>	'HTTPD',
		'ADDRESS'	=>	'192.168.1.1',
		'PORT'		=>	11111,
		'HOSTNAME'	=>	'MySite.com',
		'HEADERS'	=>	{},
		'HANDLERS'	=>	[ ],
	);

This method will die on error or return success.

This constructor accepts only 7 options.

=over 4

=item C<ALIAS>

This will set the alias SimpleHTTP uses in the POE Kernel.
This will default to "SimpleHTTP"

=item C<ADDRESS>

This value will be passed to POE::Component::Server::TCP to bind to.

=item C<PORT>

This value will be passed to POE::Component::Server::TCP to bind to.

=item C<HOSTNAME>

This value is for the HTTP::Request's URI to point to.
If this is not supplied, SimpleHTTP will use Sys::Hostname to find it.

=item C<HEADERS>

This should be a hashref, that will become the default headers on all HTTP::Response objects.
You can override this in individual requests by setting it via $request->header( ... )

For more information, consult the L<HTTP::Headers> module.

=item C<HANDLERS>

This is the hardest part of SimpleHTTP :)

You supply an array, with each element being a hash. All the hashes should contain those 3 keys:

DIR	->	The regexp that will be used, more later.

SESSION	->	The session to send the input

EVENT	->	The event to trigger

The DIR key should be a valid regexp. This will be matched against the current request path.
Pseudocode is: if ( $path =~ /$DIR/ )

NOTE: The path is UNIX style, not MSWIN style ( /blah/foo not \blah\foo )

Now, if you supply 100 handlers, how will SimpleHTTP know what to do? Simple! By passing in an array in the first place,
you have already told SimpleHTTP the order of your handlers. They will be tried in order, and if a match is not found,
SimpleHTTP will DIE!

This allows some cool things like specifying 3 handlers with DIR of:
'^/foo/.*', '^/$', '.*'

Now, if the request is not in /foo or not root, your 3rd handler will catch it, becoming the "404 not found" handler!

NOTE: You might get weird Session/Events, make sure your handlers are in order, for example: '^/', '^/foo/.*'
The 2nd handler will NEVER get any requests, as the first one will match ( no $ in the regex )

Now, here's what a handler receives:

ARG0 -> HTTP::Request object

ARG1 -> POE::Component::Server::SimpleHTTP::Response object

ARG2 -> The exact DIR that matched, so you can see what triggered what

NOTE: If ARG0 is undef, that means POE::Filter::HTTPD encountered an error parsing the client request, simply modify the HTTP::Response
object and send some sort of generic error. SimpleHTTP will set the path used in matching the DIR regexes to an empty string, so if there
is a "catch-all" DIR regex like '.*', it will catch the errors, and only that one.

NOTE: The only way SimpleHTTP will leak memory ( hopefully heh ) is if you discard the SimpleHTTP::Response object without sending it
back to SimpleHTTP via the DONE/CLOSE events, so never do that!

=item C<SSLKEYCERT>

This should be an arrayref of only 2 elements - the public key and certificate location. Now, this is still in the experimental stage, and testing
is greatly welcome!

Again, this will automatically turn every incoming connection into a SSL socket. Once enough testing has been done, this option will be augmented with more SSL stuff!

=back

=head2 Events

SimpleHTTP is so simple, there are only 7 events available.

=over 4

=item C<DONE>

	This event accepts only one argument: the HTTP::Response object we sent to the handler.

	Calling this event implies that this particular request is done, and will proceed to close the socket.

	NOTE: This method automatically sets those 3 headers if they are not already set:
		Date		->	Current date stringified via HTTP::Date->time2str
		Content-Type	->	text/html
		Content-Length	->	length( $response->content )

	To get greater throughput and response time, do not post() to the DONE event, call() it!
	However, this will force your program to block while servicing web requests...

=item C<CLOSE>

	This event accepts only one argument: the HTTP::Response object we sent to the handler.

	Calling this event will close the socket, not sending any output

=item C<GETHANDLERS>

	This event accepts 2 arguments: The session + event to send the response to

	This event will send back the current HANDLERS array ( deep-cloned via Storable::dclone )

	The resulting array can be played around to your tastes, then once you are done...

=item C<SETHANDLERS>

	This event accepts only one argument: pointer to HANDLERS array

	BEWARE: if there is an error in the HANDLERS, SimpleHTTP will die!

=item C<STARTLISTEN>

	Starts the listening socket, if it was shut down

=item C<STOPLISTEN>

	Simply a wrapper for SHUTDOWN GRACEFUL, but will not shutdown SimpleHTTP if there is no more requests

=item C<SHUTDOWN>

	Without arguments, SimpleHTTP does this:
		Close the listening socket
		Kills all pending requests by closing their sockets
		Removes it's alias

	With an argument of 'GRACEFUL', SimpleHTTP does this:
		Close the listening socket
		Waits for all pending requests to come in via DONE/CLOSE, then removes it's alias

=back

=head2 SimpleHTTP Notes

This module is very picky about capitalization!

All of the options are uppercase, to avoid confusion.

You can enable debugging mode by doing this:

	sub POE::Component::Server::SimpleHTTP::DEBUG () { 1 }
	use POE::Component::Server::SimpleHTTP;

Also, this module will try to keep the Listening socket alive.
if it dies, it will open it again for a max of 5 retries.

You can override this behavior by doing this:

	sub POE::Component::Server::SimpleHTTP::MAX_RETRIES () { 10 }
	use POE::Component::Server::SimpleHTTP;

For those who are pondering about basic-authentication, here's a tiny snippet to put in the Event handler

	# Contributed by Rocco Caputo
	sub Got_Request {
		# ARG0 = HTTP::Request, ARG1 = HTTP::Response
		my( $request, $response ) = @_[ ARG0, ARG1 ];

		# Get the login
		my ( $login, $password ) = $request->authorization_basic();

		# Decide what to do
		if ( ! defined $login or ! defined $password ) {
			# Set the authorization
			$response->header( 'WWW-Authenticate' => 'Basic realm="MyRealm"' );
			$response->code( 401 );
			$response->content( 'FORBIDDEN.' );

			# Send it off!
			$_[KERNEL]->post( 'SimpleHTTP', 'DONE', $response );
		} else {
			# Authenticate the user and move on
		}
	}

=head2 EXPORT

Nothing.

=head1 SEE ALSO

	L<POE>

	L<POE::Filter::HTTPD>

	L<HTTP::Request>

	L<HTTP::Response>

	L<POE::Component::Server::SimpleHTTP::Connection>

	L<POE::Component::Server::SimpleHTTP::Response>

	L<POE::Component::Server::SimpleHTTP::PreFork>

	L<POE::Component::SSLify>

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
