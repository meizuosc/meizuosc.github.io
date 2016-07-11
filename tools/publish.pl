#!/usr/bin/perl
# Usage: perl ./publish.pl /path/to/post
# Author: Pingbo Wen <pingbo.wen@linaro.org>
#
use utf8;
use File::Copy;
use POSIX qw(strftime);

my $ifilename = $ARGV[0];
die "Error: $!" unless(-e $ifilename);

my $ofilename = $ifilename;
my $now_str = strftime "%F-%H-%M-%S-", localtime;
my $month = strftime "%m", localtime;

$ofilename =~ s/\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-/$now_str/o;

open(FILEIN, "<:encoding(UTF-8)", $ifilename) or die "Error: $!";
open(FILEOUT, ">:encoding(UTF-8)", $ofilename) or die "Error: $!";

my $is_pre = 0;
my $is_meta = 0;
while(<FILEIN>) {
	my $line = $_;
	my $pos = tell FILEIN;
	my $next = <FILEIN>;
	seek FILEIN, $pos, 0;

	# check if we need to update image path
	if ($line =~ s#(\.?/)((images/posts/\d{4}/)(\d{2})(.+))\)#$1$3$month$5\)#gi) {
		my $new_path = $3 . $month . $5;
		if ($2 ne $new_path) {
			move($2, $new_path) or die "Error: mv $2 $new_path, $!\n";
		}
	}

	# insert space between printable ascii and printable non-ascii
	$line =~ s/([!-~])(\p{Han})/$1 $2/g;
	$line =~ s/(\p{Han})([!-~])/$1 $2/g;

	# right trim
	$line =~ s/\s+$/\n/;

	if ($line =~ /```/) {
		$is_pre = $is_pre ? 0 : 1;
	}

	if ($line =~ /---/) {
		$is_meta = $is_meta ? 0 : 1;
	}

	# insert space after every heading chars
	if (not $is_pre) {
		$line =~ s/(^###*)([^ #].*)/$1 $2/;
	}

	if ($line =~ /^\s*$/ && $next =~ /^\s*$/) {
		print "INFO: ignore redundant empty line $.\n";
	} else {
		print FILEOUT $line;

		# insert blank line after every headings, block, paragragh, etc
		if ((not $is_pre) && (not $is_meta) &&
			false == ($line =~ /^\s*$/) &&
			false == ($next =~ /^\s*$/) &&
			false == ($line =~ /^\s*([*\-+>]|([0-9]\.))\s/)) {
			print FILEOUT "\n";
		}
	}
}

# add blank line at the end of file
print FILEOUT "\n";

close(FILEIN);
close(FILEOUT);

unlink($ifilename);

