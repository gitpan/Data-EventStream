use Test::Most;
use Test::FailWarnings;

use Data::EventStream::TimeWindow;
use Data::EventStream::TimedEvent;

{

    package Summator;
    sub new { return bless { count => 0 }, shift }
    sub accumulate { my $self = shift; $self->{count} += $_->data for @_; }
    sub compensate { my $self = shift; $self->{count} -= $_->data for @_; }
    sub count { $_[0]{count} }
}

{

    package Counter;
    sub new { return bless { count => 0 }, shift }
    sub accumulate { $_[0]{count}++ }
    sub compensate { 1 }
    sub count      { $_[0]{count} }
}

my $sum   = Summator->new;
my $cnt   = Counter->new;
my $clock = Data::EventStream::MonotonicClock->new( time => 100 );

my $sw = Data::EventStream::TimeWindow->new(
    size       => 100,
    clock      => $clock,
    processors => [$sum],
);
$sw->add_processor($cnt);

my @data = (
    { time  => 110, sum => 0,  cnt => 0, },
    { event => 1,   sum => 1,  cnt => 1, },
    { event => 2,   sum => 3,  cnt => 2, },
    { time  => 150, sum => 3,  cnt => 2, },
    { event => 3,   sum => 6,  cnt => 3, },
    { time  => 200, sum => 6,  cnt => 3, },
    { event => 4,   sum => 10, cnt => 4, },
    { time  => 240, sum => 7,  cnt => 4, },
    { event => 3,   sum => 10, cnt => 5, },
    { time  => 245, sum => 10, cnt => 5, },
    { event => 2,   sum => 12, cnt => 6, },
    { time  => 290, sum => 9,  cnt => 6, },
    { event => 1,   sum => 10, cnt => 7, },
    { time  => 380, sum => 1,  cnt => 7, },
    { time  => 390, sum => 0,  cnt => 7, },
);

for (@data) {
    if ( $_->{time} ) {
        $clock->set_time( $_->{time} );
        pass "Set time to $_->{time}";
    }
    if ( $_->{event} ) {
        my $event = Data::EventStream::TimedEvent->new(
            time => $clock->get_time,
            data => $_->{event},
        );
        $sw->enqueue($event);
        pass "Enqueued event $_->{event}";
    }
    is $sum->count, $_->{sum}, "Expected value of sum";
    is $cnt->count, $_->{cnt}, "Expected count of events";
}

done_testing;
