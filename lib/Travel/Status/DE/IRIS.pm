package Travel::Status::DE::IRIS;

use strict;
use warnings;
use 5.014;

no if $] >= 5.018, warnings => 'experimental::smartmatch';

our $VERSION = '1.03';

use Carp qw(confess cluck);
use DateTime;
use Encode qw(encode decode);
use List::Util qw(first);
use LWP::UserAgent;
use Travel::Status::DE::IRIS::Result;
use XML::LibXML;

sub new {
	my ( $class, %opt ) = @_;

	my %lwp_options = %{ $opt{lwp_options} // { timeout => 10 } };

	my $ua = LWP::UserAgent->new(%lwp_options);

	if ( not $opt{station} ) {
		confess('station flag must be passed');
	}

	my $self = {
		datetime => $opt{datetime}
		  // DateTime->now( time_zone => 'Europe/Berlin' ),
		developer_mode => $opt{developer_mode},
		iris_base      => $opt{iris_base}
		  // 'http://iris.noncd.db.de/iris-tts/timetable',
		lookahead => $opt{lookahead} // ( 4 * 60 ),
		serializable => $opt{serializable},
		station      => $opt{station},
		user_agent   => $ua,
	};

	bless( $self, $class );

	$ua->env_proxy;

	my ($station_code, $station_name, @related) = $self->get_station(
		name => $opt{station},
	);

	if ($self->{errstr}) {
		return $self;
	}

	$self->{station_code} = $station_code;
	$self->{station_name} = $station_name;

	my $dt_req = $self->{datetime}->clone;
	for ( 1 .. 3 ) {
		$self->get_timetable( $self->{station_code}, $dt_req );
		$dt_req->add( hours => 1 );
	}

	$self->get_realtime;

	# tra (transfer?) indicates a train changing its ID, so there are two
	# results for the same train. Remove the departure-only trains from the
	# result set and merge them with their arrival-only counterpart.
	# This way, in case the arrival is available but the departure isn't,
	# nothing gets lost.
	my @merge_candidates
	  = grep { $_->transfer and $_->departure } @{ $self->{results} };
	@{ $self->{results} }
	  = grep { not( $_->transfer and $_->departure ) } @{ $self->{results} };

	for my $transfer (@merge_candidates) {
		my $result
		  = first { $_->transfer and $_->transfer eq $transfer->train_id }
		@{ $self->{results} };
		if ($result) {
			$result->merge_with_departure($transfer);
		}
	}

	@{ $self->{results} } = grep {
		my $d
		  = ( $_->departure // $_->arrival )
		  ->subtract_datetime( $self->{datetime} );
		not $d->is_negative and $d->in_units('minutes') < $self->{lookahead}
	} @{ $self->{results} };

	@{ $self->{results} }
	  = sort { $a->{datetime} <=> $b->{datetime} } @{ $self->{results} };

	# wings (different departures which are coupled as one train) contain
	# references to each other. therefore, they must be processed last.
	$self->create_wing_refs;

	# same goes for replacement refs (the <ref> tag in the fchg document)
	$self->create_replacement_refs;

	return $self;
}

sub get_station {
	my ($self, %opt) = @_;

	my $ua = $self->{user_agent};
	my $res_st = $ua->get( $self->{iris_base} . '/station/' . $opt{name} );

	if ( $res_st->is_error ) {
		$self->{errstr}
		  = 'Failed to fetch station data: ' . $res_st->status_line;
		return $self;
	}

	my $xml_st = XML::LibXML->load_xml( string => $res_st->decoded_content );

	my $station_node = ( $xml_st->findnodes('//station') )[0];

	# TODO parse 'meta' and maybe 'p' flags
	# They're optional pointers to related platforms. For instance
	# Berlin Hbf/BL -> Berlin HBf (tief), Berlin Hbf (S), ...

	if ( not $station_node ) {
		$self->{errstr}
		  = "The station '$opt{name}' has no associated timetable";
		return;
	}

	return ($station_node->getAttribute('eva'), $station_node->getAttribute('name'));
}

sub add_result {
	my ( $self, $station, $s ) = @_;

	my $id   = $s->getAttribute('id');
	my $e_tl = ( $s->findnodes('./tl') )[0];
	my $e_ar = ( $s->findnodes('./ar') )[0];
	my $e_dp = ( $s->findnodes('./dp') )[0];

	if ( not $e_tl ) {
		return;
	}

	my %data = (
		raw_id    => $id,
		classes   => $e_tl->getAttribute('f'),    # D N S F
		unknown_t => $e_tl->getAttribute('t'),    # p
		train_no  => $e_tl->getAttribute('n'),    # dep number
		type      => $e_tl->getAttribute('c'),    # S/ICE/ERB/...
		line_no   => $e_tl->getAttribute('l'),    # 1 -> S1, ...
		station   => $station,
		unknown_o => $e_tl->getAttribute('o'),    # owner: 03/80/R2/...
	);

	if ($e_ar) {
		$data{arrival_ts}  = $e_ar->getAttribute('pt');
		$data{platform}    = $e_ar->getAttribute('pp');    # string, not number!
		$data{route_pre}   = $e_ar->getAttribute('ppth');
		$data{route_start} = $e_ar->getAttribute('pde');
		$data{transfer}    = $e_ar->getAttribute('tra');
		$data{arrival_wing_ids} = $e_ar->getAttribute('wings');
		$data{unk_ar_hi}        = $e_ar->getAttribute('hi');
	}

	if ($e_dp) {
		$data{departure_ts} = $e_dp->getAttribute('pt');
		$data{platform}     = $e_dp->getAttribute('pp');   # string, not number!
		$data{route_post}   = $e_dp->getAttribute('ppth');
		$data{route_end}    = $e_dp->getAttribute('pde');
		$data{transfer}     = $e_dp->getAttribute('tra');
		$data{departure_wing_ids} = $e_dp->getAttribute('wings');
		$data{unk_dp_hi}          = $e_dp->getAttribute('hi');
	}

	if ( $data{arrival_wing_ids} ) {
		$data{arrival_wing_ids} = [ split( /\|/, $data{arrival_wing_ids} ) ];
	}
	if ( $data{departure_wing_ids} ) {
		$data{departure_wing_ids}
		  = [ split( /\|/, $data{departure_wing_ids} ) ];
	}

	my $result = Travel::Status::DE::IRIS::Result->new(%data);

	# if scheduled departure and current departure are not within the
	# same hour, trains are reported twice. Don't add duplicates in
	# that case.
	if ( not first { $_->raw_id eq $id } @{ $self->{results} } ) {
		push( @{ $self->{results} }, $result, );
	}

	return $result;
}

sub get_timetable {
	my ( $self, $eva, $dt ) = @_;
	my $ua = $self->{user_agent};

	my $res = $ua->get(
		$dt->strftime( $self->{iris_base} . "/plan/${eva}/%y%m%d/%H" ) );

	if ( $self->{developer_mode} ) {
		say 'GET '
		  . $dt->strftime( $self->{iris_base} . "/plan/${eva}/%y%m%d/%H" );
	}

	if ( $res->is_error ) {
		$self->{warnstr}
		  = 'Failed to fetch a schedule part: ' . $res->status_line;
		return $self;
	}

	my $xml = XML::LibXML->load_xml( string => $res->decoded_content );

	my $station = ( $xml->findnodes('/timetable') )[0]->getAttribute('station');

	for my $s ( $xml->findnodes('/timetable/s') ) {

		$self->add_result( $station, $s );
	}

	return $self;
}

sub get_realtime {
	my ($self) = @_;

	my $eva = $self->{station_code};
	my $res = $self->{user_agent}->get( $self->{iris_base} . "/fchg/${eva}" );

	if ( $self->{developer_mode} ) {
		say 'GET ' . $self->{iris_base} . "/fchg/${eva}";
	}

	if ( $res->is_error ) {
		$self->{warnstr}
		  = 'Failed to fetch realtime data: ' . $res->status_line;
		return $self;
	}

	my $xml = XML::LibXML->load_xml( string => $res->decoded_content );

	my $station = ( $xml->findnodes('/timetable') )[0]->getAttribute('station');

	for my $s ( $xml->findnodes('/timetable/s') ) {
		my $id     = $s->getAttribute('id');
		my $e_ar   = ( $s->findnodes('./ar') )[0];
		my $e_dp   = ( $s->findnodes('./dp') )[0];
		my @e_refs = $s->findnodes('./ref/tl');
		my @e_ms   = $s->findnodes('.//m');

		my %messages;

		my $result = first { $_->raw_id eq $id } $self->results;

		if ( not $result ) {
			$result = $self->add_result( $station, $s );
			if ($result) {
				$result->set_unscheduled(1);
			}
		}
		if ( not $result ) {
			next;
		}

		if ( not $self->{serializable} ) {
			$result->set_realtime($s);
		}

		for my $e_m (@e_ms) {
			my $type  = $e_m->getAttribute('t');
			my $value = $e_m->getAttribute('c');
			my $msgid = $e_m->getAttribute('id');
			my $ts    = $e_m->getAttribute('ts');

			# 0 and 1 (with key "f") are related to canceled trains and
			# do not appear to hold information
			if ( defined $value and $value > 1 ) {
				$messages{$msgid} = [ $ts, $type, $value ];
			}
		}

		$result->set_messages(%messages);

		# note: A departure may also have a ./tl attribute. However, we do
		# not need to process it because it only matters for departures which
		# are not planned (or not in the plans we requested). However, in
		# those cases we already called add_result earlier, which reads ./tl
		# by itself.
		for my $e_ref (@e_refs) {
			$result->add_raw_ref(
				class     => $e_ref->getAttribute('f'),    # D N S F
				unknown_t => $e_ref->getAttribute('t'),    # p
				train_no  => $e_ref->getAttribute('n'),    # dep number
				type      => $e_ref->getAttribute('c'),    # S/ICE/ERB/...
				line_no   => $e_ref->getAttribute('l'),    # 1 -> S1, ...
				unknown_o => $e_ref->getAttribute('o'),    # owner: 03/80/R2/...
				     # TODO ps='a' -> rerouted and normally unscheduled train?
			);
		}
		if ($e_ar) {
			$result->set_ar(
				arrival_ts      => $e_ar->getAttribute('ct'),
				plan_arrival_ts => $e_ar->getAttribute('pt'),
				platform        => $e_ar->getAttribute('cp'),
				route_pre       => $e_ar->getAttribute('cpth'),
				sched_route_pre => $e_ar->getAttribute('ppth'),
				status          => $e_ar->getAttribute('cs'),
				status_since    => $e_ar->getAttribute('clt'),

				# TODO ps='a' -> rerouted and normally unscheduled train?
			);
		}
		if ($e_dp) {
			$result->set_dp(
				departure_ts      => $e_dp->getAttribute('ct'),
				plan_departure_ts => $e_dp->getAttribute('pt'),
				platform          => $e_dp->getAttribute('cp'),
				route_post        => $e_dp->getAttribute('cpth'),
				sched_route_post  => $e_dp->getAttribute('ppth'),
				status            => $e_dp->getAttribute('cs'),
			);
		}

	}

	return $self;
}

sub get_result_by_id {
	my ( $self, $id ) = @_;

	my $res = first { $_->wing_id eq $id } @{ $self->{results} };
	return $res;
}

sub get_result_by_train {
	my ( $self, $type, $train_no ) = @_;

	my $res = first { $_->type eq $type and $_->train_no eq $train_no }
	@{ $self->{results} };
	return $res;
}

sub create_wing_refs {
	my ($self) = @_;

	for my $r ( $self->results ) {
		if ( $r->{departure_wing_ids} ) {
			for my $wing_id ( @{ $r->{departure_wing_ids} } ) {
				my $wingref = $self->get_result_by_id($wing_id);
				if ($wingref) {
					$r->add_departure_wingref($wingref);
				}
			}
		}
		if ( $r->{arrival_wing_ids} ) {
			for my $wing_id ( @{ $r->{arrival_wing_ids} } ) {
				my $wingref = $self->get_result_by_id($wing_id);
				if ($wingref) {
					$r->add_arrival_wingref($wingref);
				}
			}
		}
	}

}

sub create_replacement_refs {
	my ($self) = @_;

	for my $r ( $self->results ) {
		for my $ref_hash ( @{ $r->{refs} // [] } ) {
			my $ref = $self->get_result_by_train( $ref_hash->{type},
				$ref_hash->{train_no} );
			if ($ref) {
				$r->add_reference($ref);
			}
		}
	}
}

sub station_code {
	my ($self) = @_;

	return $self->{station_code};
}

sub errstr {
	my ($self) = @_;

	return $self->{errstr};
}

sub results {
	my ($self) = @_;

	return @{ $self->{results} // [] };
}

sub warnstr {
	my ($self) = @_;

	return $self->{warnstr};
}

1;

__END__

=head1 NAME

Travel::Status::DE::IRIS - Interface to IRIS based web departure monitors.

=head1 SYNOPSIS

    use Travel::Status::DE::IRIS;
    use Travel::Status::DE::IRIS::Stations;

    # Get station code for "Essen Hbf" (-> "EE")
    my $station = (Travel::Status::DE::IRIS::Stations::get_station_by_name(
        'Essen Hbf'))[0][0];
    
    my $status = Travel::Status::DE::IRIS->new(station => $station);
    for my $r ($status->results) {
        printf(
            "%s %s +%-3d %10s -> %s\n",
            $r->date, $r->time, $r->delay || 0, $r->line, $r->destination
        );
    }

=head1 VERSION

version 1.03

=head1 DESCRIPTION

Travel::Status::DE::IRIS is an unofficial interface to IRIS based web
departure monitors such as
L<https://iris.noncd.db.de/wbt/js/index.html?typ=ab&style=qrab&bhf=EE&SecLang=&Zeilen=20&footer=0&disrupt=0>.

=head1 METHODS

=over

=item my $status = Travel::Status::DE::IRIS->new(I<%opt>)

Requests schedule and realtime data for a specific station at a specific
point in time. Returns a new Travel::Status::DE::IRIS object.

Arguments:

=over

=item B<datetime> => I<datetime-obj>

A DateTime(3pm) object specifying the point in time. Optional, defaults to the
current date and time.

=item B<iris_base> => I<url>

IRIS base url, defaults to C<< http://iris.noncd.db.de/iris-tts/timetable >>.

=item B<lookahead> => I<int>

Compute only those results which are less than I<int> minutes in the future.
Default: 240 (4 hours).

Note that the DeutscheBahn IRIS backend only provides schedules up to four
to five hours into the future, and this module only requests data for up to
three hours. So in most cases, setting this to a value above 180 minutes will
have no effect. However, as the IRIS occasionally contains unscheduled
departures or qos messages known far in advance (e.g. 12 hours from now), any
non-negative integer is accepted.

=item B<lwp_options> => I<\%hashref>

Passed on to C<< LWP::UserAgent->new >>. Defaults to C<< { timeout => 10 } >>,
you can use an empty hashref to unset the default.

=item B<station> => I<stationcode>

Mandatory: Which station to return departures for. Note that this is not a
station name, but a station code, such as "EE" (for Essen Hbf) or "KA"
(for Aachen Hbf). See Travel::Status::DE::IRIS::Stations(3pm) for a
name to code mapping.

=back

=item $status->errstr

In case of a fatal HTTP request or IRIS error, returns a string describing it.
Returns undef otherwise.

=item $status->results

Returns a list of Travel::Status::DE::IRIS(3pm) objects, each one describing
one arrival and/or departure.

=item $status->warnstr

In case of a (probably) non-fatal HTTP request or IRIS error, returns a string
describing it.  Returns undef otherwise.

=back

=head1 DIAGNOSTICS

None.

=head1 DEPENDENCIES

=over

=item * DateTime(3pm)

=item * List::Util(3pm)

=item * LWP::UserAgent(3pm)

=item * XML::LibXML(3pm)

=back

=head1 BUGS AND LIMITATIONS

Many backend features are not yet exposed.

=head1 SEE ALSO

db-iris(1), Travel::Status::DE::IRIS::Result(3pm),
Travel::Status::DE::IRIS::Stations(3pm)

=head1 REPOSITORY

L<https://github.com/derf/Travel-Status-DE-IRIS>

=head1 AUTHOR

Copyright (C) 2013-2015 by Daniel Friesel E<lt>derf@finalrewind.orgE<gt>

=head1 LICENSE

This module is licensed under the same terms as Perl itself.
