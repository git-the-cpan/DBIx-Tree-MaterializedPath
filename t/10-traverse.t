
use strict;
use warnings;

use Test::More tests => 38;

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
    skip($@, 38) if $@ && chomp $@;

    my ($tree, $childhash) = test_create_test_tree($dbh);

    my $child;
    my $descendants;
    my $count;
    my $text;
    my $coderef;

    $descendants = $tree->get_descendants();

    $msg = 'traverse() should catch missing coderef';
    eval { $descendants->traverse() };
    like($@, qr/\bmissing\b .* \bcoderef\b/ix, $msg);

    $msg = 'traverse() should catch invalid coderef';
    eval { $descendants->traverse('I am not an CODEREF') };
    like($@, qr/\binvalid\b .* \bcoderef\b/ix, $msg);

    $msg     = 'Object in traverse()';
    $coderef = sub {
        my ($node, $parent) = @_;
        isa_ok($node, 'DBIx::Tree::MaterializedPath::Node', 'Traversed node');
        isa_ok($parent,
               'DBIx::Tree::MaterializedPath::Node',
               'Traversed parent');
        ok($parent->is_same_node_as($node->get_parent),
            'Node and parent are consistent');
    };

    $descendants->traverse($coderef);

    #####

    # This is *not* how you'd normally do it, just testing some
    # constructor error handling...

    my $foo = bless {}, 'Foo';

    $msg = 'TreeRepresentation->new() should catch missing node';
    eval {
        $descendants = DBIx::Tree::MaterializedPath::TreeRepresentation->new();
    };
    like($@, qr/\bmissing\b .* \bnode\b/ix, $msg);

    $msg = 'TreeRepresentation->new() should catch invalid node';
    eval {
        $descendants =
          DBIx::Tree::MaterializedPath::TreeRepresentation->new($foo);
    };
    like($@, qr/\binvalid\b .* \bnode\b/ix, $msg);

    $msg = 'TreeRepresentation->new() should catch missing rows';
    eval {
        $descendants =
          DBIx::Tree::MaterializedPath::TreeRepresentation->new($tree);
    };
    like($@, qr/\bmissing\b .* \brows\b/ix, $msg);

    $msg = 'TreeRepresentation->new() should catch invalid rows';
    eval {
        $descendants =
          DBIx::Tree::MaterializedPath::TreeRepresentation->new($tree,
                                                          'I AM NOT A LISTREF');
    };
    like($@, qr/\binvalid\b .* \brows\b/ix, $msg);

    my $pm = DBIx::Tree::MaterializedPath::PathMapper->new();

    $descendants =
      DBIx::Tree::MaterializedPath::TreeRepresentation->new(
                               $tree,
                               [
                                {id => 2, path => $pm->map('1.1'), name => "a"},
                                {id => 3, path => $pm->map('1.2'), name => "b"},
                                {id => 4, path => $pm->map('1.3'), name => "c"},
                               ]
      );

    $descendants->traverse($coderef);

    # ok, done mucking around...

    #####

    $descendants = $tree->get_descendants();

    $coderef = sub {
        my ($node, $parent) = @_;
        $count++;
        $text .= $node->data->{name};
    };

    $count = 0;
    $text  = '';
    $descendants->traverse($coderef);

    $msg = 'traverse() returns correct number of children for root node';
    is($count, 6, $msg);

    $msg = 'traverse() follows correct order for root node';
    is($text, 'abcdfe', $msg);

    $child       = $childhash->{'1.3'};
    $descendants = $child->get_descendants();
    $count       = 0;
    $text        = '';
    $descendants->traverse($coderef);

    $msg = 'traverse() returns correct number of children for deeper node';
    is($count, 3, $msg);

    $msg = 'traverse() follows correct order for deeper node';
    is($text, 'dfe', $msg);

    $child       = $childhash->{'1.3.1.1'};
    $descendants = $child->get_descendants();
    $count       = 0;
    $text        = '';
    $descendants->traverse($coderef);

    $msg = 'traverse() operates on no children for leaf node';
    is($count, 0, $msg);
}

