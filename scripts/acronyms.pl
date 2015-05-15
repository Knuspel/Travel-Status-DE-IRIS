#!/usr/bin/env perl

use strict;
use warnings;
use 5.010;
use Encode qw(decode encode);
use List::Util qw(max sum);
use List::MoreUtils qw(true);

say <<'EOF';
package Travel::Status::DE::IRIS::Stations;

use strict;
use warnings;
use 5.014;
use utf8;

use List::MoreUtils qw(firstval);

our $VERSION = '1.00';

my @stations = (
EOF

my @buf;

sub process_block {
	my @histogram;
	my @borders = (0);
	my $run = 0;

	my $length = max (map { length($_) } @buf);

	for my $i (0 .. $length) {
		$histogram[$i] = true { length($_) < $i or substr($_, $i, 1) eq q{ } } @buf;

		if ($histogram[$i] == @buf) {
			if (not $run) {
				push(@borders, $i);
				$run = 1;
			}
		}
		else {
			$run = 0;
		}
	}
	for my $i (0 .. $#borders / 2) {
		for my $line (@buf) {
			my $station_offset = $borders[2 * $i];
			my $name_offset = $borders[2 * $i + 1];
			my $station_length = $name_offset - $station_offset;
			my $name_length = $borders[2 * $i + 2] ? ($borders[2 * $i + 2] - $name_offset) : undef;

			if (length($line) < $station_offset) {
				next;
			}

			my $station = substr($line, $station_offset, $station_length);
			my $name = $name_length ? substr($line, $name_offset, $name_length) : substr($line, $name_offset);

			$station =~ s{^\s+}{};
			$station =~ s{\s+$}{};
			$station =~ s{\s+}{ }g;
			$name =~ s{!}{ }g;
			$name =~ s{^\s+}{};
			$name =~ s{\s+$}{};
			$name =~ s{\s+}{ }g;
			$name =~ s{'}{\\'}g;

			if (length($station) == 0) {
				next;
			}

			printf("\t['%s','%s'],\n", encode('UTF-8', $station), encode('UTF-8', $name));
		}
	}
}

while (my $line = <STDIN>) {
	chomp $line;
	$line = decode('UTF-8', $line);

	if (length($line) == 0 and @buf) {
		process_block();
		@buf = ();
	}

	if ($line !~ m{ ^ [A-Z]{2} }x and $line !~ m{ \s [A-Z]{2,5} \s }x) {
		next;
	}

	$line =~ s{RB-Gr km}{RB-Gr!km}g;
	$line =~ s{RB-Gr!km\s++}{RB-Gr!km!}g;
	$line =~ s{Bad }{Bad!}g;

	push(@buf, $line);
}
if (@buf) {
	process_block();
}

say <<'EOF';
);

sub get_stations {
	return @stations;
}

sub normalize {
	my ($val) = @_;

	$val =~ s{Ä}{Ae}g;
	$val =~ s{Ö}{Oe}g;
	$val =~ s{Ü}{Ue}g;
	$val =~ s{ä}{ae}g;
	$val =~ s{ö}{oe}g;
	$val =~ s{ß}{sz}g;
	$val =~ s{ü}{ue}g;

	return $val;
}

sub get_station {
	my ( $name ) = @_;

	my $ds100_match = firstval { $name eq $_->[0] } @stations;

	if ($ds100_match) {
		return ($ds100_match);
	}

	return get_station_by_name($name);
}

sub get_station_by_name {
	my ( $name ) = @_;

	my $nname = lc($name);
	my $actual_match = firstval { $nname eq lc($_->[1]) } @stations;

	if ($actual_match) {
		return ($actual_match);
	}

	$nname = normalize($nname);
	$actual_match = firstval { $nname eq normalize(lc($_->[1])) } @stations;
	if ($actual_match) {
		return ($actual_match);
	}

	return ( grep { $_->[1] =~ m{$name}i } @stations );
}

1;

__END__

=head1 NAME

Travel::Status::DE::IRIS::Stations - Station name to station code mapping

=head1 SYNOPSIS

    use Travel::Status::DE::IRIS::Stations;

    my $name = 'Essen Hbf';
    my @stations = Travel::Status::DE::IRIS::Stations::get_station_by_name(
      $name);

    if (@stations < 1) {
      # no matching stations
    }
    elsif (@stations > 1) {
      # too many matches
    }
    else {
      printf("Input '%s' matched station code %s (as '%s')\n",
        $name, @{$stations[0]});
    }

=head1 VERSION

version 0.00

=head1 DESCRIPTION

This module contains a mapping of DeutscheBahn station names to station codes.
A station name is a (perhaps slightly abbreviated) string naming a particular
station; a station code is a two to five character denoting a station for the
IRIS web service.

Example station names (code in parentheses) are:
"Essen HBf" (EE), "Aachen Schanz" (KASZ), "Do UniversitE<auml>t" (EDUV).

B<Note:> Station codes may contain whitespace.

=head1 METHODS

=over

=item Travel::Status::DE::IRIS::get_stations

Returns a list of [station code, station name] listrefs lexically sorted by
station name.

=item Travel::Status::DE::IRIS::get_station(I<$in>)

Returns a list of [station code, station name] listrefs matching I<$in>.

If a I<$in> is a valid station code, only one element ([I<$in>, related name])
is returned. Otherwise, it is passed to get_station_by_name(I<$in>) (see
below).

Note that station codes matching is case sensitive and must be exact.

=item Travel::Status::DE::IRIS::get_station_by_name(I<$name>)

Returns a list of [station code, station name] listrefs where the station
name matches I<$name>.

Matching happens in two steps: If a case-insensitive exact match exists, only
this one is returned. Otherwise, all stations whose name contains I<$name> as
a substring (also case-insensitive) are returned.

This two-step behaviour makes sure that not prefix-free stations can still be
matched directly. For instance, both "Essen-Steele" and "Essen-Steele Ost"
are valid station names, but "essen-steele" will only return "Essen-Steele".

=back

=head1 DIAGNOSTICS

None.

=head1 DEPENDENCIES

=over

=item * List::MoreUtils(3pm)

=back

=head1 BUGS AND LIMITATIONS

There is no support for intelligent whitespaces (to also match "-" and similar)
yet.

=head1 SEE ALSO

Travel::Status::DE::IRIS(3pm).

=head1 AUTHOR

Copyright (C) 2014-2015 by Daniel Friesel E<lt>derf@finalrewind.orgE<gt>

=head1 LICENSE

This module is licensed under the same terms as Perl itself.

EOF
