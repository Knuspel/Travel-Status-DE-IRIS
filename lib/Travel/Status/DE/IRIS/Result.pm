package Travel::Status::DE::IRIS::Result;

use strict;
use warnings;
use 5.010;
use utf8;

no if $] >= 5.018, warnings => "experimental::smartmatch";

use parent 'Class::Accessor';
use Carp qw(cluck);
use DateTime;
use DateTime::Format::Strptime;
use List::MoreUtils qw(uniq);

our $VERSION = '0.00';

Travel::Status::DE::IRIS::Result->mk_ro_accessors(
	qw(arrival date datetime delay departure is_cancelled line_no platform raw_id
	  realtime_xml route_start route_end
	  sched_arrival sched_departure
	  start stop_no time train_id train_no type unknown_t unknown_o)
);

sub new {
	my ( $obj, %opt ) = @_;

	my $ref = \%opt;

	my $strp = DateTime::Format::Strptime->new(
		pattern   => '%y%m%d%H%M',
		time_zone => 'Europe/Berlin',
	);

	my ( $train_id, $start_ts, $stop_no ) = split( /.\K-/, $opt{raw_id} );

	$ref->{start} = $strp->parse_datetime($start_ts);

	$ref->{train_id} = $train_id;
	$ref->{stop_no}  = $stop_no;

	my $ar = $ref->{arrival} = $ref->{sched_arrival}
	  = $strp->parse_datetime( $opt{arrival_ts} );
	my $dp = $ref->{departure} = $ref->{sched_departure}
	  = $strp->parse_datetime( $opt{departure_ts} );

	if ( not( $ar or $dp ) ) {
		cluck(
			sprintf(
				"Neither arrival '%s' nor departure '%s' are valid "
				  . "timestamps - can't handle this train",
				$opt{arrival_ts}, $opt{departure_ts}
			)
		);
	}

	my $dt = $ref->{datetime} = $dp // $ar;

	$ref->{date} = $dt->strftime('%d.%m.%Y');
	$ref->{time} = $dt->strftime('%H:%M');

	$ref->{route_pre} = $ref->{sched_route_pre}
	  = [ split( qr{\|}, $ref->{route_pre} // q{} ) ];
	$ref->{route_post} = $ref->{sched_route_post}
	  = [ split( qr{\|}, $ref->{route_post} // q{} ) ];

	$ref->{route_pre_incomplete}  = $ref->{route_end}  ? 1 : 0;
	$ref->{route_post_incomplete} = $ref->{route_post} ? 1 : 0;

	$ref->{route_end}
	  = $ref->{sched_route_end}
	  = $ref->{route_end}
	  || $ref->{route_post}[-1]
	  || $ref->{station};
	$ref->{route_start}
	  = $ref->{sched_route_start}
	  = $ref->{route_start}
	  || $ref->{route_pre}[0]
	  || $ref->{station};

	$ref->{is_cancelled} = 0;

	return bless( $ref, $obj );
}

sub add_ar {
	my ( $self, %attrib ) = @_;

	my $strp = DateTime::Format::Strptime->new(
		pattern   => '%y%m%d%H%M',
		time_zone => 'Europe/Berlin',
	);

	if ( $attrib{arrival_ts} ) {
		$self->{arrival} = $strp->parse_datetime( $attrib{arrival_ts} );
		$self->{delay}
		  = $self->arrival->subtract_datetime( $self->sched_arrival )
		  ->in_units('minutes');
	}

	if ( $attrib{status} and $attrib{status} eq 'c' ) {
		$self->{is_cancelled} = 1;
	}
}

sub add_dp {
	my ( $self, %attrib ) = @_;

	my $strp = DateTime::Format::Strptime->new(
		pattern   => '%y%m%d%H%M',
		time_zone => 'Europe/Berlin',
	);

	if ( $attrib{departure_ts} ) {
		$self->{departure} = $strp->parse_datetime( $attrib{departure_ts} );
		$self->{delay}
		  = $self->departure->subtract_datetime( $self->sched_departure )
		  ->in_units('minutes');
	}

	if ( $attrib{status} and $attrib{status} eq 'c' ) {
		$self->{is_cancelled} = 1;
	}
}

sub add_messages {
	my ( $self, %messages ) = @_;

	$self->{messages} = \%messages;
}

sub add_realtime {
	my ( $self, $xmlobj ) = @_;

	$self->{realtime_xml} = $xmlobj;
}

sub add_tl {
	my ( $self, %attrib ) = @_;

	# TODO

	return $self;
}

sub origin {
	my ($self) = @_;

	return $self->route_start;
}

sub destination {
	my ($self) = @_;

	return $self->route_end;
}

sub info {
	my ($self) = @_;

	my @messages = sort keys %{ $self->{messages} };
	my @ids = uniq( map { $self->{messages}{$_}->[2] } @messages );

	my @info = map { $self->translate_msg($_) } @ids;

	return @info;
}

sub line {
	my ($self) = @_;

	return
	  sprintf( '%s %s', $self->{type}, $self->{line_no} // $self->{train_no} );
}

sub route_pre {
	my ($self) = @_;

	return @{ $self->{route_pre} };
}

sub route_post {
	my ($self) = @_;

	return @{ $self->{route_post} };
}

sub route {
	my ($self) = @_;

	return ( $self->route_pre, $self->{station}, $self->route_post );
}

sub train {
	my ($self) = @_;

	return $self->line;
}

sub route_interesting {
	my ( $self, $max_parts ) = @_;

	my @via = $self->route_post;
	my ( @via_main, @via_show, $last_stop );
	$max_parts //= 3;

	for my $stop (@via) {
		if ( $stop =~ m{ ?Hbf}o ) {
			push( @via_main, $stop );
		}
	}
	$last_stop
	  = $self->{route_post_incomplete} ? $self->{route_end} : pop(@via);

	if ( @via_main and $via_main[-1] eq $last_stop ) {
		pop(@via_main);
	}

	if ( @via_main and @via and $via[0] eq $via_main[0] ) {
		shift(@via_main);
	}

	if ( @via < $max_parts ) {
		@via_show = @via;
	}
	else {
		if ( @via_main >= $max_parts ) {
			@via_show = ( $via[0] );
		}
		else {
			@via_show = splice( @via, 0, $max_parts - @via_main );
		}

		while ( @via_show < $max_parts and @via_main ) {
			my $stop = shift(@via_main);
			if ( $stop ~~ \@via_show or $stop eq $last_stop ) {
				next;
			}
			push( @via_show, $stop );
		}
	}

	for (@via_show) {
		s{ ?Hbf}{};
	}

	return @via_show;

}

sub translate_msg {
	my ( $self, $msg ) = @_;

	my %translation = (
		2  => 'Polizeiliche Ermittlung',
		3  => 'Feuerwehreinsatz neben der Strecke',
		5  => 'Ärztliche Versorgung eines Fahrgastes',
		7  => 'Personen im Gleis',
		8  => 'Notarzteinsatz am Gleis',
		10 => 'Ausgebrochene Tiere im Gleis',
		11 => 'Unwetter',
		15 => 'Beeinträchtigung durch Vandalismus',
		16 => 'Entschärfung einer Fliegerbombe',
		17 => 'Beschädigung einer Brücke',
		18 => 'Umgestürzter Baum im Gleis',
		19 => 'Unfall an einem Bahnübergang',
		20 => 'Tiere im Gleis',
		21 => 'Warten auf weitere Reisende',
		22 => 'Witterungsbedingte Störung',
		23 => 'Feuerwehreinsatz auf Bahngelände',
		24 => 'Verspätung aus dem Ausland',
		25 => 'Warten auf verspätete Zugteile',
		28 => 'Gegenstände im Gleis',
		31 => 'Bauarbeiten',
		32 => 'Verzögerung beim Ein-/Ausstieg',
		33 => 'Oberleitungsstörung',
		34 => 'Signalstörung',
		35 => 'Streckensperrung',
		36 => 'Technische Störung am Zug',
		38 => 'Technische Störung an der Strecke',
		39 => 'Anhängen von zusätzlichen Wagen',
		40 => 'Stellwerksstörung/-ausfall',
		41 => 'Störung an einem Bahnübergang',
		42 => 'Außerplanmäßige Geschwindigkeitsbeschränkung',
		43 => 'Verspätung eines vorausfahrenden Zuges',
		44 => 'Warten auf einen entgegenkommenden Zug',
		45 => 'Überholung durch anderen Zug',
		46 => 'Warten auf freie Einfahrt',
		47 => 'Verspätete Bereitstellung',
		48 => 'Verspätung aus vorheriger Fahrt',
		80 => 'Abweichende Wagenreihung',
		83 => 'Fehlender Zugteil',
		86 => 'Keine Reservierungsanzeige',
		90 => 'Kein Bordrestaurant/Bordbistro',
		91 => 'Keine Fahrradmitnahme',
		92 => 'Rollstuhlgerechtes WC in einem Wagen ausgefallen',
		93 => 'Kein rollstuhlgerechtes WC',
		98 => 'Kein rollstuhlgerechter Wagen',
		99 => 'Verzögerungen im Betriebsablauf',
	);

	return $translation{$msg} // "?($msg)";
}

sub TO_JSON {
	my ($self) = @_;

	return { %{$self} };
}

1;

__END__

=head1 NAME

Travel::Status::DE::IRIS::Result - Information about a single
arrival/departure received by Travel::Status::DE::IRIS

=head1 SYNOPSIS

	for my $departure ($status->results) {
		printf(
			"At %s: %s to %s from platform %s\n",
			$departure->time,
			$departure->line,
			$departure->destination,
			$departure->platform,
		);
	}

	# or (depending on module setup)
	for my $arrival ($status->results) {
		printf(
			"At %s: %s from %s on platform %s\n",
			$arrival->time,
			$arrival->line,
			$arrival->origin,
			$arrival->platform,
		);
	}

=head1 VERSION

version 1.02

=head1 DESCRIPTION

Travel::Status::DE::IRIs::Result describes a single arrival/departure
as obtained by Travel::Status::DE::IRIS.  It contains information about
the platform, time, route and more.

=head1 METHODS

=head2 ACCESSORS

=over

=item $result->arrival

DateTime(3pm) object for the arrival date and time. undef if the
train starts here. Contains realtime data if available.

=item $result->date

Scheduled departure date if available, arrival date otherwise (e.g. if the
train ends here). String in dd.mm.YYYY format. Does not contain realtime data.

=item $result->datetime

DateTime(3pm) object for departure if available, arrival otherwise. Does not
contain realtime data.

=item $result->delay

Estimated delay in minutes (integer number). undef when no realtime data is
available, negative if a train ends at the specified station and arrives /
arrived early.

=item $result->departure

DateTime(3pm) object for the departure date and time. undef if the train ends
here. Contains realtime data if available.

=item $result->destination

Aleas for route_end.

=item $result->info

List of information strings. Contains both reasons for delays (which may or
may not be up-to-date) and generic information such as missing carriages or
broken toilets.

=item $result->is_cancelled

True if the train was cancelled, false otherwise. Note that this does not
contain information about replacement trains or route diversions.

=item $result->line

Train type with line (such as C<< S 1 >>) if available, type with number
(suc as C<< RE 10126 >>) otherwise.

=item $result->line_no

Number of the line, undef if unknown. Seems to be set only for S-Bahn and
similar trains. Regional and long-distance trains such as C<< RE 10126 >>
usually do not have this field set, even if they have a common line number
(C<< RE 1 >> in this case).

Example: For the line C<< S 1 >>, line_no will return C<< 1 >>.

=item $result->origin

Alias for route_start.

=item $result->platform

Arrivel/departure platform as string, undef if unknown. Note that this is
not neccessarily a number, platform sections may be included (e.g.
C<< 3a/b >>).

=item $result->raw_id

Raw ID of the departure, e.g. C<< -4642102742373784975-1401031322-6 >>.
The first part appears to be this train's UUID (can be tracked across
multiple stations), the second the YYmmddHHMM departure timestamp at its
start station, and the third the count of this station in the train's schedule
(in this case, it's the sixth from thestart station).

About half of all departure IDs do not contain the leading minus (C<< - >>)
seen in this example. The reason for this is unknown.

This is a developer option. It may be removed without prior warning.

=item $result->realtime_xml

XML::LibXML::Node(3pm) object containing all realtime data. undef if none is
available.

This is a developer option. It may be removed without prior warning.

=item $result->route

List of all stations served by this train, according to its schedule. Does
not contain realtime data.

=item $result->route_end

Name of the last station served by this train according to its schedule.

=item $result->route_interesting

List of up to three "interesting" stations served by this train, subset of
route_post. Usually contains the next stop and one or two major stations after
that.

=item $result->route_pre

List of station names the train is scheduled to pass before this stop.

=item $result->route_post

List of station names the train is scheduled to pass after this stop.

=item $result->route_start

Name of the first station served by this train according to its schedule.

=item $result->sched_arrival

DateTime(3pm) object for the scheduled arrival date and time. undef if the
train starts here.

=item $result->sched_departure

DateTime(3pm) object for the scehduled departure date and time. undef if the
train ends here.

=item $result->start

DateTime(3pm) object for the scheduled start of the train on its route
(i.e. the departure time at its first station).

=item $result->stop_no

Number of this stop on the train's route. 1 if it's the start station, 2
for the stop after that, and so on.

=item $result->time

Scheduled departure time if available, arrival time otherwise (e.g. if the
train ends here). String in HH:MM format. Does not contain realtime data.

=item $result->train

Alias for line.

=item $result->train_id

Numeric ID of this train. Seems to be unique for a year and trackable across
stations.

=item $result->train_no

Number of this train, unique per day. E.g. C<< 2225 >> for C<< IC 2225 >>.

=item $result->type

Type of this train, e.g. C<< S >> for S-Bahn, C<< RE >> for Regional-Express,
C<< ICE >> for InterCity-Express.

=back

=head2 INTERNAL

=over

=item $result = Travel::Status::DE::IRIS::Result->new(I<%data>)

Returns a new Travel::Status::DE::IRIS::Result object.
You usually do not need to call this.

=back

=head1 MESSAGES

A dump of all messages entered for the result is available. Each message
consists of a timestamp (when it was entered), a type (d for delay reasons,
q for other train-related information) and a value (numeric ID).

At the time of this writing, the following messages are known:

=over

=item d  2 : "Polizeiliche Ermittlung"

=item d  3 : "Feuerwehreinsatz neben der Strecke"

=item d  5 : "E<Auml>rztliche Versorgung eines Fahrgastes"

=item d  7 : "Personen im Gleis"

=item d  8 : "Notarzteinsatz am Gleis"

=item d 10 : "Ausgebrochene Tiere im Gleis"

=item d 11 : "Unwetter"

=item d 15 : "BeeintrE<auml>chtigung durch Vandalismus"

=item d 16 : "EntschE<auml>rfung einer Fliegerbombe"

=item d 17 : "BeschE<auml>digung einer BrE<uuml>cke"

=item d 18 : "UmgestE<uuml>rzter Baum im Gleis"

=item d 19 : "Unfall an einem BahnE<uuml>bergang"

=item d 20 : "Tiere im Gleis"

=item d 21 : "Warten auf weitere Reisende"

=item d 22 : "Witterungsbedingte StE<ouml>rung"

=item d 23 : "Feuerwehreinsatz auf BahngelE<auml>nde"

=item d 24 : "VerspE<auml>tung aus dem Ausland"

=item d 25 : "Warten auf verspE<auml>tete Zugteile"

=item d 28 : "GegenstE<auml>nde im Gleis"

=item d 31 : "Bauarbeiten"

=item d 32 : "VerzE<ouml>gerung beim Ein-/Ausstieg"

=item d 33 : "OberleitungsstE<ouml>rung"

=item d 34 : "SignalstE<ouml>rung"

=item d 35 : "Streckensperrung"

=item d 36 : "Technische StE<ouml>rung am Zug"

=item d 38 : "Technische StE<ouml>rung an der Strecke"

=item d 39 : "AnhE<auml>ngen von zusE<auml>tzlichen Wagen"

=item d 40 : "StellwerksstE<ouml>rung/-ausfall"

=item d 41 : "StE<ouml>rung an einem BahnE<uuml>bergang"

=item d 42 : "AuE<szlig>erplanmE<auml>E<szlig>ige GeschwindigkeitsbeschrE<auml>nkung"

=item d 43 : "VerspE<auml>tung eines vorausfahrenden Zuges"

=item d 44 : "Warten auf einen entgegenkommenden Zug"

=item d 45 : "E<Uuml>berholung durch anderen Zug"

=item d 46 : "Warten auf freie Einfahrt"

=item d 47 : "VerspE<auml>tete Bereitstellung"

=item d 48 : "VerspE<auml>tung aus vorheriger Fahrt"

=item q 80 : "Abweichende Wagenreihung"

=item q 83 : "Fehlender Zugteil"

=item q 86 : "Keine Reservierungsanzeige"

=item q 90 : "Kein Bordrestaurant/Bordbistro"

=item q 91 : "Keine Fahrradmitnahme"

=item q 92 : "Rollstuhlgerechtes WC in einem Wagen ausgefallen"

=item q 93 : "Kein rollstuhlgerechtes WC"

=item q 98 : "Kein rollstuhlgerechter Wagen"

=item d 99 : "VerzE<ouml>gerungen im Betriebsablauf"

=back

=head1 DIAGNOSTICS

None.

=head1 DEPENDENCIES

=over

=item Class::Accessor(3pm)

=back

=head1 BUGS AND LIMITATIONS

None known.

=head1 SEE ALSO

Travel::Status::DE::IRIS(3pm).

=head1 AUTHOR

Copyright (C) 2013 by Daniel Friesel E<lt>derf@finalrewind.orgE<gt>

=head1 LICENSE

This module is licensed under the same terms as Perl itself.
