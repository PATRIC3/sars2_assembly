#
# Run a chunk of jobs on a bebop node.
#
# We expect to be run as an array job with a stepsize of 1.
# We run entries-per-job SRA entries in each job. This will be spread
# across the 36 cores of the node. 
#
# Former:
# We look up the data based on the SLURM_ARRAY_TASK_ID
# and SLURM_ARRAY_TASK_STEP values; that is, we will
# compute on items task_id thru (task_id + task_step - 1)
# in parallel, with a thread count for each of int(36 / task_step).
#
# For each item, we use p3-sra to download the data to /scratch/item.$n
# We split the output directory based on last two digits of SRA number $L2
# 
# Then we run sars2-onecodex $dir/*fastq $job_output/$L2 $sra_number
#
# bebop-run-chunk sra-def-file output-dir
#

use strict;
use Data::Dumper;
use File::Path 'make_path';
use Proc::ParallelLoop;
use Time::HiRes 'gettimeofday';
use IPC::Run 'run';

@ARGV == 4 or die "Usage: $0 job-offset entries-per-job sra-def-file output-dir\n";

my $job_offset = shift;
my $entries_per_job = shift;
my $sra_defs = shift;
my $output = shift;

my $scratch = $ENV{SCRATCH_DIR} // "/scratch";

$job_offset =~ /^\d+$/ or die "Invalid job offset '$job_offset'\n";
-d $output or die "Output directory $output does not exist\n";

my $start = $job_offset + ($ENV{SLURM_ARRAY_TASK_ID} - 1) * $entries_per_job + 1;;
my $end = $start + $entries_per_job - 1;

my $workers = 9;
my $threads = 4;

print STDERR "Run from $start to $end\n";

open(S, "<", $sra_defs) or die "Cannot open SRA defs file $sra_defs: $!";

my @to_run;
while (<S>)
{
    chomp;
    if ($. >= $start && $. <= $end)
    {
	my($id) = split(/\t/);
	push(@to_run, [$., $id]);
    }
}
close(S);

print STDERR "Run " . Dumper(\@to_run);
    
print STDERR "Start downloads\n";

pareach \@to_run, sub {
    my($ent) = @_;
    my($id, $sra) = @$ent;

    eval {
	dl_one($id, $sra);
    };
    if ($@)
    {
	warn "Error downloading $id $sra: $@";
    }
    
}, { Max_Workers => 2 };

print STDERR "Start runs\n";

pareach \@to_run, sub {
    my($ent) = @_;
    my($id, $sra) = @$ent;

    eval {
	run_one($id, $sra);
    };
    if ($@)
    {
	warn "Error running $id $sra: $@";
    }
    
}, { Max_Workers => $threads };


sub dl_one
{
    my($id, $sra) = @_;
    $ENV{TMPDIR} = $scratch;
    print STDERR "Running $id: $sra\n";
    my $tmp = "$scratch/task-$id";
    make_path($tmp);

    my $l2 = substr($sra, 0, 7);
    my $out = "$output/$l2/$sra";
    make_path($out);

    my $ok = run(["p3-sra", "--id", $sra, "--out", $tmp],
		 ">", "$out/download.stdout",
		 "2>", "$out/download.sterr");
    $ok or die "p3_sra failed with $? for $sra\n";
}

sub run_one
{
    my($id, $sra) = @_;
    my $start = gettimeofday;
    $ENV{TMPDIR} = $scratch;
    print STDERR "Running $id: $sra\n";
    my $tmp = "$scratch/task-$id";
    make_path($tmp);

    my $l2 = substr($sra, 0, 7);
    my $out = "$output/$l2/$sra";
    make_path($out);

    my @fastq = glob("$tmp/*.fastq");
    print STDERR "Run on @fastq\n";
    if (@fastq != 1 && @fastq != 2)
    {
	die "Invalid fastq count @fastq\n";
    }
    my @cmd = ("sars2-onecodex", @fastq, $sra, $out, "--threads", $threads);
    print STDERR "Run in pid $$ for id $id $sra: @cmd\n";
    my $ok = run(\@cmd,
	      ">", "$out/assemble.stdout",
	      "2>", "$out/assemble.sterr");
    $ok or warn "Assemble failed with $?\n";
    my $end = gettimeofday;
    my $elap = $end - $start;
    if (open(F, ">", "$out/RUNTIME"))
    {
	print F "$start\t$end\t$elap\n";
	close(F);
    }
}
