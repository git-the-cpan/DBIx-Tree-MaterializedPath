
use strict;
use warnings;

use Test::More tests => 29;

use DBIx::Tree::MaterializedPath;

BEGIN
{
    chdir 't' if -d 't';
    use File::Spec;
    my $testlib = File::Spec->catfile('testlib', 'testutils.pm');
    require $testlib;
}

my $msg;

SKIP:
{
    my $dbh;
    eval { $dbh = test_get_dbh() };
    skip($@, 29) if $@ && chomp $@;

    my ($tree, $childhash) = test_create_test_tree($dbh);

    my $descendants;
    my $children;
    my $child;

    sub count_descendants
    {
        my ($listref) = @_;
        my $count = scalar @$listref;
        foreach my $child (@$listref)
        {
            $count += count_descendants($child->{children});
        }
        return $count;
    }

    #####

    $msg = 'get_descendants() returns correct number of children for root node';
    $descendants = $tree->get_descendants();
    is(@$descendants, 3, $msg);

    $msg =
      'get_descendants() returns correct number of descendants for root node';
    is(count_descendants($descendants), 6, $msg);

    $msg = 'Object returned by get_descendants()';
    isa_ok($descendants->[0]->{node},
           'DBIx::Tree::MaterializedPath::Node', $msg);
    isa_ok($descendants->[1]->{node},
           'DBIx::Tree::MaterializedPath::Node', $msg);
    isa_ok($descendants->[2]->{node},
           'DBIx::Tree::MaterializedPath::Node', $msg);
    $msg = 'get_descendants() returns expected descendants for root node';
    is($descendants->[0]->{node}->data->{name}, 'a', $msg);
    is($descendants->[1]->{node}->data->{name}, 'b', $msg);
    is($descendants->[2]->{node}->data->{name}, 'c', $msg);

    $children = $descendants->[2]->{children};

    $msg = 'Object returned by get_descendants()';
    isa_ok($children->[0]->{node}, 'DBIx::Tree::MaterializedPath::Node', $msg);
    isa_ok($children->[1]->{node}, 'DBIx::Tree::MaterializedPath::Node', $msg);
    $msg = 'get_descendants() returns expected descendants for root node';
    is($children->[0]->{node}->data->{name}, 'd', $msg);
    is($children->[1]->{node}->data->{name}, 'e', $msg);

    $children = $children->[0]->{children};

    $msg = 'Object returned by get_descendants()';
    isa_ok($children->[0]->{node}, 'DBIx::Tree::MaterializedPath::Node', $msg);
    $msg = 'get_descendants() returns expected descendants for root node';
    is($children->[0]->{node}->data->{name}, 'f', $msg);

    #####

    $child = $descendants->[2]->{node};

    $msg =
      'get_descendants() returns correct number of children for child node';
    $descendants = $child->get_descendants();
    is(@$descendants, 2, $msg);

    $msg =
      'get_descendants() returns correct number of descendants for child node';
    is(count_descendants($descendants), 3, $msg);

    $msg = 'Object returned by get_descendants()';
    isa_ok($descendants->[0]->{node},
           'DBIx::Tree::MaterializedPath::Node', $msg);
    isa_ok($descendants->[1]->{node},
           'DBIx::Tree::MaterializedPath::Node', $msg);
    $msg = 'get_descendants() returns expected descendants for child node';
    is($descendants->[0]->{node}->data->{name}, 'd', $msg);
    is($descendants->[1]->{node}->data->{name}, 'e', $msg);

    $children = $descendants->[0]->{children};

    $msg = 'Object returned by get_descendants()';
    isa_ok($children->[0]->{node}, 'DBIx::Tree::MaterializedPath::Node', $msg);
    $msg = 'get_descendants() returns expected descendants for child node';
    is($children->[0]->{node}->data->{name}, 'f', $msg);

    #####

    $child = $descendants->[1]->{node};

    $msg         = 'get_descendants() returns no children for leaf node';
    $descendants = $child->get_descendants();
    is(@$descendants, 0, $msg);

    #####

    $msg = 'get_descendants() returns no data yet using delay_load';
    $descendants = $tree->get_descendants({delay_load => 1});
    ok(!exists $descendants->[0]->{node}->{_data}, $msg);
    ok(!exists $descendants->[1]->{node}->{_data}, $msg);
    ok(!exists $descendants->[2]->{node}->{_data}, $msg);

    $msg = 'data now loaded using delay_load';
    is($descendants->[0]->{node}->data->{name}, 'a', $msg);
    is($descendants->[1]->{node}->data->{name}, 'b', $msg);
    is($descendants->[2]->{node}->data->{name}, 'c', $msg);
}

