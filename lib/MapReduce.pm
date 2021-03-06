package MapReduce;
use Moo;
use Storable qw(nfreeze thaw);
use Data::Dump::Streamer qw(Dump);
use Time::HiRes qw(time);
use Carp qw(croak);
use List::MoreUtils qw(all);
use Exporter qw(import);
use MapReduce::Mapper;
use MapReduce::Reducer;

our @EXPORT_OK = qw(pmap);

# Do not change these. Rather, to enable logging,
# change the $LOGGING value to one of these variables.
our $DEBUG = 2;
our $INFO  = 1;
our $NONE  = 0;

# Enable / disable logging.
our $LOGGING = $ENV{MAPREDUCE_LOGGING} // $NONE;

sub debug { shift->log('DEBUG', @_) if $LOGGING >= $DEBUG }
sub info  { shift->log('INFO',  @_) if $LOGGING >= $INFO  }

sub log {
    my ($class, $level, $format, @args) = @_;

    $format //= '';
    
    printf STDERR $level.': '.$format."\n", map { defined $_ ? $_ : 'undef' } @args;
}

has [ qw( name mapper ) ] => (
    is       => 'ro',
    required => 1,
);

has reducer => (
    is      => 'ro',
    default => sub { sub { $_[1] } },
);

has id => (
    is => 'lazy',
);

has mapper_worker => (
    is => 'lazy',
);

has reducer_worker => (
    is => 'lazy',
);

with 'MapReduce::Role::Redis';

sub _build_id {
    my ($self) = @_;
    
    my $id = 'mr-'.$self->name . '-' . int(time) . '-' . $$ . '-' . int(rand(2**31));
    
    MapReduce->debug( "ID is '%s'", $id );
    
    return $id;
}

sub _build_mapper_worker {
    my ($self) = @_;
    
    return MapReduce::Mapper->new();
}

sub _build_reducer_worker {
    my ($self) = @_;
    
    return MapReduce::Reducer->new();
}

sub BUILD {
    my ($self) = @_;
    
    my $mapper  = ref $self->mapper  ? Dump( $self->mapper  )->Declare(1)->Out() : $self->mapper;
    my $reducer = ref $self->reducer ? Dump( $self->reducer )->Declare(1)->Out() : $self->reducer;
    my $redis   = $self->redis;
    
    MapReduce->debug( "Mapper is '%s'",  $mapper );
    MapReduce->debug( "Reducer is '%s'", $reducer );
   
    $SIG{INT} = sub { exit 1 }
        if !$SIG{INT};
        
    $SIG{TERM} = sub { exit 1 }
        if !$SIG{TERM};
    
    $redis->setex( $self->id . '-mapper',  60*60*24, $mapper );
}

sub inputs {
    my ($self, $inputs) = @_;
    
    my $redis = $self->redis;
    my $id    = $self->id;
    
    $redis->setex( $id.'-input-count', 60*60*24, scalar(@$inputs) );
    
    for my $input (@$inputs) {
        $input->{_id} = $id;
        
        $redis->lpush( 'mr-inputs', nfreeze($input) );
    }
    
    MapReduce->debug( "Pushed %d inputs.", scalar(@$inputs) );
    
    return $self;
}

sub done {
    my ($self) = @_;
    
    return $self->redis->get( $self->id.'-done' );
}

sub next_result {
    my ($self) = @_;
    
    my $redis = $self->redis;
    my $id    = $self->id;
    
    while (1) {
        my $reduced = $redis->rpop( $self->id.'-mapped');
        
        if (!defined $reduced) {
            return undef if $self->done;

            $self->mapper_worker->run();
            
            next;
        }

        my $value = thaw($reduced);
        
        croak 'Reduced result is undefined?'
            if !defined $value;
        
        return $value;
    }
}

sub all_results {
    my ($self) = @_;
    
    my @results;
    
    while (1) {
        my $result = $self->next_result;
        
        if (!defined $result) {
            last if $self->done;
            next;
        }
        
        push @results, $result;
    }
    
    return \@results;
}

sub each_result {
    my ($self, $callback) = @_;
    
    die 'callback required'
        if !$callback;
        
    while (1) {
        my $result = $self->next_result;
        
        if (!defined $result) {
            last if $self->done;
            next;
        }
        
        $callback->($result);
    }
}

sub pmap (&@) {
    my ($mapper, $inputs) = @_;
    
    my $mapper_count = $ENV{MAPREDUCE_PMAP_MAPPERS} // 4;
    
    my @mappers = map { MapReduce::Mapper->new(daemon => 1) } 1 .. $mapper_count;
    
    my $map_reduce = MapReduce->new(
        name => 'pmap-'.time.$$.int(rand(2**31)),
        
        mapper => sub {
            my ($self, $input) = @_;
            
            local $_ = $input->{value};
            
            my $output = $mapper->(); 
            
            return {
                key    => $input->{key},
                output => $output,
            };
        },
    );
    
    my $key = 1;
    
    @$inputs = map { { key => $key++, value => $_ } } @$inputs;

    $map_reduce->inputs($inputs);

    my $results = $map_reduce->all_results;

    my @outputs = map { $_->{output} } sort { $a->{key} <=> $b->{key} } @$results;
    
    return \@outputs;
}

1;

