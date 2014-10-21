use Test::Most;
use Test::FailWarnings;

use Data::EventStream;

{

    package TimeAverager;
    use Moose;
    with 'Data::EventStream::Aggregator';

    has time_value_sub => (
        is      => 'ro',
        default => sub {
            sub { ( $_[0]->{time}, $_[0]->{val} ) }
        },
    );

    has _sum => (
        is      => 'rw',
        traits  => ['Number'],
        default => 0,
        handles => {
            _sum_add => 'add',
            _sum_sub => 'sub',
        },
    );

    has _start_event => ( is => 'rw', );

    has _last_event => ( is => 'rw', );

    sub _duration {
        my $self = shift;
        return $self->_start_event ? $self->_last_event->[0] - $self->_start_event->[0] : 0;
    }

    sub value {
        my $self = shift;
        return
            $self->_duration ? 0 + sprintf( "%.6g", $self->_sum / $self->_duration )
          : $self->_start_event ? $self->_start_event->[1]
          :                       'NaN';
    }

    sub enter {
        my ( $self, $event, $window ) = @_;

        my ( $time, $value ) = $self->time_value_sub->($event);
        if ( $self->_start_event ) {
            my $prev_last = $self->_last_event;
            $self->_last_event( [ $time, $value ] );
            $self->_sum_add( ( $time - $prev_last->[0] ) * $prev_last->[1] );
        }
        else {
            # this is first observed event
            $self->_start_event( [ $time, $value ] );
            $self->_last_event( [ $time, $value ] );
        }
    }

    sub reset {
        my ( $self, $window ) = @_;
        my $last = $self->_last_event;
        if ($last) {
            my $start_time = $window->start_time;
            $self->_start_event( [ $start_time, $last->[1] ] );
            $self->_last_event( [ $start_time, $last->[1] ] );
        }
        $self->_sum(0);
    }

    sub leave {
        my ( $self, $event, $window ) = @_;
        my ( $time, $value ) = $self->time_value_sub->($event);
        my $start_ev = $self->_start_event;
        $self->_sum_sub( ( $time - $start_ev->[0] ) * $start_ev->[1] );
        my $start_time = $window->start_time;
        $self->_sum_sub( ( $start_time - $time ) * $value );
        $self->_start_event( [ $start_time, $value ] );
        $self->window_update($window);
    }

    sub window_update {
        my ( $self, $window ) = @_;
        my $last = $self->_last_event;
        if ($last) {
            $self->_last_event( [ $window->end_time, $last->[1] ] );
            $self->_sum_add( ( $window->end_time - $last->[0] ) * $last->[1] );
        }
        my $start = $self->_start_event;
        if ( $start and $start->[0] < $window->start_time ) {
            $self->_start_event( [ $window->start_time, $start->[1] ] );
            $self->_sum_sub( ( $window->start_time - $start->[0] ) * $start->[1] );
        }
    }
}

my $es = Data::EventStream->new(
    time     => 8,
    time_sub => sub { $_[0]->{time} },
);

my %params = (
    t3 => { duration => '3', },
    t5 => { duration => '5', },
    b4 => { duration => '4', batch => 1, },
    b3 => { duration => '3.5', batch => 1, start_time => 9.5, },
);

my %average;
my %ins;
my %outs;
my %resets;

sub store_observed_value {
    my ( $hr, $key, $value ) = @_;
    if ( defined $hr->{$key} ) {
        if ( ref $hr->{$key} eq 'ARRAY' ) {
            push @{ $hr->{$key} }, $value;
        }
        else {
            $hr->{$key} = [ $hr->{$key}, $value, ];
        }
    }
    else {
        $hr->{$key} = $value;
    }
}

for my $as ( keys %params ) {
    $average{$as} = TimeAverager->new;
    $es->add_aggregator(
        $average{$as},
        %{ $params{$as} },
        on_enter => sub {
            store_observed_value( \%ins, $as, $_[0]->value );
        },
        on_leave => sub {
            store_observed_value( \%outs, $as, $_[0]->value );
        },
        on_reset => sub {
            store_observed_value( \%resets, $as, $_[0]->value );
        },
    );
}

is $es->time_length, 5, "correct time_length for feed stream";

my @events = (
    {
        time => 11.3,
        val  => 1,
        ins  => { t3 => 1, t5 => 1, b4 => 1, b3 => 1, },
    },
    {
        time   => 12,
        resets => { b4 => 1, },
        vals   => { t3 => 1, t5 => 1, b4 => 1, b3 => 1, },
    },
    {
        time => 12.7,
        val  => 3,
        ins  => { t3 => 1, t5 => 1, b4 => 1, b3 => 1, },
    },
    {
        time   => 13,
        resets => { b3 => 1.35294, },
        vals   => { t3 => 1.35294, t5 => 1.35294, b4 => 1.6, b3 => 3, },
    },
    {
        time => 13.2,
        val  => 4,
        ins  => { t3 => 1.52632, t5 => 1.52632, b4 => 1.83333, b3 => 3, },
    },
    {
        time => 15,
        outs => { t3 => 2.72973, },
        vals => { t3 => 3.13333, t5 => 2.72973, b4 => 3.13333, b3 => 3.9, },
    },
    {
        time   => 16,
        resets => { b4 => 3.35, },
        outs   => { t3 => 3.84848, },
        vals   => { t3 => 3.93333, t5 => 3, b4 => 4, b3 => 3.93333, },
    },
    {
        time   => 17.1,
        val    => 8,
        resets => { b3 => 3.94286, },
        outs   => { t3 => 4, t5 => 3.18966, },
        ins    => { t3 => 4, t5 => 3.54, b4 => 4, b3 => 4, },
    },
    {
        time => 19.2,
        val  => 5,
        outs => { t5 => [ 5.21538, 5.4, ], },
        ins  => { t3 => 6.8, t5 => 5.68, b4 => 6.625, b3 => 7.11111, },
    },
    {
        time   => 20,
        resets => { b4 => 6.3, b3 => 6.62857, },
        vals   => { t3 => 7.06667, t5 => 5.84, b4 => 5, b3 => 5, },
    },
    {
        time => 20.8,
        val  => 2,
        outs => { t3 => 6.7027, },
        ins  => { t3 => 6.4, t5 => 6, b4 => 5, b3 => 5, },
    },
    {
        time => 23,
        outs => { t3 => 3.26316, t5 => 4.94915, },
        vals => { t3 => 2.8, t5 => 4.4, b4 => 2.8, b3 => 2.8, },
    },
    {
        time   => 30,
        val    => 4,
        resets => { b4 => [ 2.6, 2, ], b3 => [ 2.68571, 2, ], },
        outs => { t3 => 2, t5 => [ 2.44444, 2 ], },
        ins => { t3 => 2, t5 => 2, b4 => 2, b3 => 2, },
    },
    {
        time   => 33,
        val    => 1,
        resets => { b4 => 3, b3 => 2.28571, },
        outs => { t3 => 4, },
        ins  => { t3 => 4, t5 => 3.2, b4 => 4, b3 => 4, },
    },
    {
        time => 33.5,
        val  => 7,
        ins  => { t3 => 3.5, t5 => 3.1, b4 => 3, b3 => 3.5, },
    },
    {
        time   => 35.2,
        val    => 9,
        resets => { b3 => 4, },
        outs   => { t5 => 4.69231, },
        ins    => { t3 => 5.2, t5 => 4.72, b4 => 5.125, b3 => 7, },
    },
    {
        time   => 36,
        resets => { b4 => 5.9, },
        outs   => { t3 => 6.53333, },
        vals   => { t3 => 6.53333, t5 => 5.52, b4 => 9, b3 => 7.8, },
    },
    {
        time   => 45,
        resets => { b4 => [ 9, 9, ], b3 => [ 8.31429, 9, 9, ], },
        outs   => { t3 => [ 8.70435, 9 ], t5 => [ 8.38333, 8.70435, 9 ], },
        vals => { t3 => 9, t5 => 9, b4 => 9, },
    },
);

my $i = 1;
for my $ev (@events) {
    subtest "event $i: time=$ev->{time}" . ( $ev->{val} ? " val=$ev->{val}" : "" ) => sub {
        $es->set_time( $ev->{time} ) unless $ev->{val};
        $es->add_event( { time => $ev->{time}, val => $ev->{val} } ) if $ev->{val};
        eq_or_diff \%ins, $ev->{ins} // {}, "got expected ins";
        %ins = ();
        eq_or_diff \%outs, $ev->{outs} // {}, "got expected outs";
        %outs = ();
        eq_or_diff \%resets, $ev->{resets} // {}, "got expected resets";
        %resets = ();

        if ( $ev->{vals} ) {
            my %vals;
            for ( keys %{ $ev->{vals} } ) {
                $vals{$_} = $average{$_}->value;
            }
            eq_or_diff \%vals, $ev->{vals}, "aggregators have expected values";
        }
    };
    $i++;
    last if $ev->{stop};
}

done_testing;
