
use strict;
use warnings;

use Test::More tests => 5;

use DBIx::Tree::MaterializedPath;

BEGIN
{
    chdir 't' if -d 't';
    use File::Spec;
    my $testlib = File::Spec->catfile('testlib', 'testutils.pm');
    require $testlib;
}

my $tree;
my $msg;

SKIP:
{
    my $dbh;
    eval { $dbh = test_get_dbh() };
    skip($@, 5) if $@ && chomp $@;

    my ($tree, $childhash) = test_create_test_tree($dbh);

    my $child;
    my $parent;

    my $descendants = $tree->get_descendants();

    $msg = 'get_parent() returns undef for root';
    is($tree->get_parent(), undef, $msg);

    $child  = $descendants->[2]->{node};
    $parent = $child->get_parent();

    $msg = 'Object returned by get_parent() for depth-1 child';
    isa_ok($parent, 'DBIx::Tree::MaterializedPath::Node', $msg);

    $msg = 'get_parent() returns root for depth-1 child';
    is($parent->data->{name}, $tree->data->{name}, $msg);

    $child  = $descendants->[2]->{children}->[1]->{node};
    $parent = $child->get_parent();

    $msg = 'Object returned by get_parent() for deeper child';
    isa_ok($parent, 'DBIx::Tree::MaterializedPath::Node', $msg);

    $msg = 'get_parent() returns correct node for deeper child';
    is($parent->data->{name}, 'c', $msg);
}

