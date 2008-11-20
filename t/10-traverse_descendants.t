
use strict;
use warnings;

use Test::More tests => 9;

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
    skip($@, 9) if $@ && chomp $@;

    my ($tree, $childhash) = test_create_test_tree($dbh);

    my $child;
    my $descendants;
    my $count;
    my $text;
    my $coderef;

    $msg = 'traverse_descendants() should catch missing descendants';
    eval { $tree->traverse_descendants() };
    like($@, qr/\bmissing\b .* \bdescendants\b/ix, $msg);

    $msg = 'traverse_descendants() should catch invalid descendants';
    eval { $tree->traverse_descendants('I am not an ARRAYREF') };
    like($@, qr/\binvalid\b .* \bdescendants\b/ix, $msg);

    $descendants = $tree->get_descendants();

    $msg = 'traverse_descendants() should catch missing coderef';
    eval { $tree->traverse_descendants($descendants) };
    like($@, qr/\bmissing\b .* \bcoderef\b/ix, $msg);

    $msg = 'traverse_descendants() should catch invalid coderef';
    eval { $tree->traverse_descendants($descendants, 'I am not an CODEREF') };
    like($@, qr/\binvalid\b .* \bcoderef\b/ix, $msg);

    $coderef = sub {
        my ($node, $parent) = @_;
        $count++;
        $text .= $node->data->{name};
    };

    $count = 0;
    $text  = '';
    $tree->traverse_descendants($descendants, $coderef);

    $msg =
      'traverse_descendants() returns correct number of children for root node';
    is($count, 6, $msg);

    $msg = 'traverse_descendants() follows correct order for root node';
    is($text, 'abcdfe', $msg);

    $child       = $childhash->{'1.3'};
    $descendants = $child->get_descendants();
    $count       = 0;
    $text        = '';
    $child->traverse_descendants($descendants, $coderef);

    $msg =
      'traverse_descendants() returns correct number of children for deeper node';
    is($count, 3, $msg);

    $msg = 'traverse_descendants() follows correct order for deeper node';
    is($text, 'dfe', $msg);

    $child       = $childhash->{'1.3.1.1'};
    $descendants = $child->get_descendants();
    $count       = 0;
    $text        = '';
    $child->traverse_descendants($descendants, $coderef);

    $msg = 'traverse_descendants() operates on no children for leaf node';
    is($count, 0, $msg);
}

