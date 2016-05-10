#!/usr/bin/perl -w

use strict;
use warnings FATAL => 'all';
use Getopt::Std;
use Getopt::Long;
use Cwd;
use FindBin;
use lib "$FindBin::Bin";
use IO::File;


######################### process input parameters #########################
my @usage;
push @usage, "\nUsage:  run-combat.pl -t tissueType [other options]\n\n";
push @usage, "Options:\n";
push @usage, "  -h, --help         Displays this information\n";
push @usage, "  -t, --tissue       Input tissue type\n";
push @usage, "  -c, --tissue-conf  Input tissue configuration file (default: path of script file)\n";
push @usage, "  -r, --run-combat   Run combat to correct batch biases\n";
push @usage, "  -q, --quan-tool    Expression quantification tool: RSEM (default) | FeatureCounts\n";
push @usage, "  -u, --quan-unit    Unit to measure gene expression: TPM | Count | FPKM (default)\n\n";


my ($help, $tissue, $tissue_conf, $quan_tool, $quan_unit);
my $run_combat = 0;

GetOptions
(
 'h|help|?'         => \$help,
 't|tissue=s'       => \$tissue,
 'c|tissue-conf=s'  => \$tissue_conf,
 'r|run-combat'     => \$run_combat,
 'q|quan-tool=s'    => \$quan_tool,
 'u|quan-unit=s'    => \$quan_unit,
);

if (!defined $tissue) {
    print "ERROR: please provide tissue type\n";
    print @usage;
    die;
}

(defined $tissue_conf) or $tissue_conf = "$FindBin::Bin/tissue-conf.txt";
if (!-e $tissue_conf){
    print "ERROR: Cannot find tissue configuration file\n";
    print @usage;
    die;
}

if (!defined $quan_tool) {
    $quan_tool = 'rsem';
}else{
    $quan_tool = lc($quan_tool);
    if ($quan_tool ne 'rsem' and $quan_tool ne 'featurecounts'){
        print "ERROR: Unknown tool. Please specify either RSEM or FeatureCounts using -q\n";
        print @usage;
        die;
    }
}

if (!defined $quan_unit) {
    $quan_unit = 'fpkm';
}else{
    $quan_unit = lc($quan_unit);
    if ($quan_unit ne 'tpm' and $quan_unit ne 'count' and $quan_unit ne 'fpkm'){
        print "ERROR: Please specify one of TPM | Count | FPKM using -u\n";
        print @usage;
        die;
    }
}

if ($help) {
   print @usage;
   exit(0);
}

######################### Read configuration file #################################

# Read configuration file
my $config_file = "$FindBin::Bin/config.txt";
( -e $config_file ) or die "ERROR: The configuration file $config_file does not exist\n";
my %config;
map{ chomp; /^\s*([^=\s]+)\s*=\s*(.*)$/; $config{$1} = $2 if (defined $1 && defined $2) } `egrep -v \"^#\" $config_file`;
# Use configuration file to initialize variables
my ($gtex_path, $tcga_path, $ubu_dir, $gtex_sample_attr, $ensg_2_hugo_file);
$gtex_path        =  $config{ gtex_path };
$tcga_path        =  $config{ tcga_path };
$ubu_dir          =  $config{ ubu_dir } if ( exists $config{ ubu_dir } );
$gtex_sample_attr =  $config{ gtex_sample_attr };
$ensg_2_hugo_file =  $config{ ENSG_UCSC_common_genes };


# Read tissue configuration file
my @lines = `grep $tissue $tissue_conf`;
(scalar @lines > 0) or die "ERROR: $tissue_conf is empty\n";

my $cluster = -1;
foreach my $line (@lines){
    my @data = split(/\t/, $line);
    next if ($data[1] ne $tissue and $data[3] ne $tissue);
    
    if ($cluster == -1){
        $cluster = $data[0];
    }elsif ($cluster != $data[0]){
        die "ERROR: $tissue does not have a unique cluster #: $cluster,$data[0]\n";
    }
}

@lines = ();
my $flag = 0;
my $prefix;
foreach my $line (`grep -v ^# $tissue_conf`){
    chomp $line;
    my @data = split(/\t/, $line);
    next if ($data[0] != $cluster);
    
    (-e "$gtex_path/sra/$data[1]" or -e "$tcga_path/$data[3]" or -e "$tcga_path/$data[3]-t") or die "ERROR: Nonexistent paths for $data[1]/$data[3]\n";
    
    if (-e "$gtex_path/sra/$data[1]/SraRunTable.txt" and -e "$tcga_path/$data[3]/summary.tsv"){
        $flag = 1;
        $prefix = "$data[1]-$data[3]-$quan_tool-$quan_unit";
    }
    push @lines, $line;
}

($flag == 1) or die "ERROR: There should be >=1 tissue with both GTEx and TCGA normals\n";


######################### Create data matrix #################################

my $work_dir = getcwd;
my (@samples, %expr, %gene, $data_matrix_fh);

my (%ens2hugo, %hugo2entrez);
map{chomp; my @f=split(/\t/); $ens2hugo{$f[0]}=$f[1]; $hugo2entrez{$f[1]}=$f[2]}`cat $ensg_2_hugo_file`;

my $batch_str = '';
my %col_ranges;

#if (!-e "$prefix.txt" or ($quan_unit ne "count" and !-s "$prefix.adjusted.txt")){
$data_matrix_fh = IO::File->new( "$prefix.txt", ">" ) or die "ERROR: Couldn't create file $prefix.txt\n";
# Print header line
# $data_matrix_fh->print("Gene\tDescription");
$data_matrix_fh->print("Gene");

my %finished_tissues;
foreach my $line (@lines){
    my @data = split(/\t/, $line);
    
    if (-e "$gtex_path/sra/$data[1]"){
        if ( defined $finished_tissues{ "$gtex_path/sra/$data[1]" } ){
            next;
        }else{
            $finished_tissues{ "$gtex_path/sra/$data[1]" } = 1;
        }
        chdir "$gtex_path/sra";
        # Read GTEx normal samples
        my $n1 = scalar @samples;
        &ReadSampleExpression($data[1]);
        my $n2 = scalar @samples;
        $col_ranges {"$data[1]-$quan_tool-$quan_unit-gtex.txt"} = ($n1+2).'-'.($n2+1);
        
        $n2 -= $n1;
        map{ $batch_str .= "normal\t$data[2]\n" }(1..$n2);
    }
    
    if (-e "$tcga_path/$data[3]"){
        if ( defined $finished_tissues{ "$tcga_path/$data[3]" } ){
            next;
        }else{
            $finished_tissues{ "$tcga_path/$data[3]" } = 1;
        }
        chdir $tcga_path;
        # Read TCGA normal samples
        my $n1 = scalar @samples;
        &ReadSampleExpression($data[3]);
        my $n2 = scalar @samples;
        $col_ranges {"$data[3]-$quan_tool-$quan_unit-tcga.txt"} = ($n1+2).'-'.($n2+1);
        
        $n2 -= $n1;
        map{ $batch_str .= "normal\t$data[4]\n" }(1..$n2);
    }
    
    if (-e "$tcga_path/$data[3]-t"){
        if ( defined $finished_tissues{ "$tcga_path/$data[3]-t" } ){
            next;
        }else{
            $finished_tissues{ "$tcga_path/$data[3]-t" } = 1;
        }
        chdir $tcga_path;
        # Read TCGA tumor samples
        my $n1 = scalar @samples;
        &ReadSampleExpression("$data[3]-t");
        my $n2 = scalar @samples;
        $col_ranges {"$data[3]-$quan_tool-$quan_unit-tcga-t.txt"} = ($n1+2).'-'.($n2+1);
        
        $n2 -= $n1;
        map{ $batch_str .= "tumor\t$data[4]\n" }(1..$n2);
    }
}

# Finish printing header line
$data_matrix_fh->print("\n");

# Write data matrix
foreach my $g (keys %gene){
    next if(! exists $ens2hugo{$g});
    #$data_matrix_fh->print( $g );
    $data_matrix_fh->print( $ens2hugo{$g} );
    map{ $data_matrix_fh->print("\t" . $expr{$_}{$g}) if(defined $_) }@samples;
    $data_matrix_fh->print("\n");
}
$data_matrix_fh->close();


######################### Correct batch effect #################################

chdir $work_dir;

my $batch_fh = IO::File->new( $prefix.'-combat-batch.txt', ">" ) or die "ERROR: Couldn't create file combat-batch.txt\n";
$batch_fh->print( $batch_str. "\n");
$batch_fh->close();

my $Rscript = "$FindBin::Bin/run-combat.R";

if ($run_combat){
    (-s "$prefix.adjusted.txt") or `Rscript $Rscript $prefix.txt $prefix.adjusted`;
    (-s "$prefix.adjusted.txt") or die "ERROR: Failed to run $Rscript\n";
}

#(!-e $prefix.'-combat-batch.txt') or `rm $prefix-combat-batch.txt`;
#}

######################### Split output files #################################

print "Splitting file\n";

foreach my $outfile (keys %col_ranges){
    if ($run_combat){
        &SplitFile( "$prefix.adjusted.txt", $outfile,  $col_ranges{ $outfile } );
    }else{
        &SplitFile( "$prefix.txt", $outfile,  $col_ranges{ $outfile } );
    }
}


sub SplitFile() {
    my $in_file_name    = shift;
    my $out_file_name   = shift;
    my $cols            = shift;
    
    #my @idx = split(/-/, $cols);
    #my $header_str = join( "\t", @samples[ ($idx[0]-2)..($idx[1]-2) ] );
    my $head_str = `head -1 $in_file_name | cut -f $cols`;
    chomp $head_str;
    
    #my @fields = split(/-/, $out_file_name);
    #my $tissue_name = $fields[0];
    #$tissue_name =~ s/-/\./g;
    #$head_str = join(/\t/, map{ s/.$tissue_name.//g; }split(/\t/, $head_str));
    
    my $file_handle = IO::File->new( $out_file_name, ">" ) or die "ERROR: Couldn't create file $out_file_name\n";
    $file_handle->print( "Hugo_Symbol\tEntrez_Gene_Id\t$head_str\n");
    
    #`tail -n +2 $in_file_name | cut -f $cols >> $out_file_name`;
    foreach(`tail -n +2 $in_file_name | cut -f 1,$cols`){
        chomp;
        my @F=split(/\t/);
        $F[0] .= "\t".((defined $hugo2entrez{$F[0]}) ? $hugo2entrez{$F[0]} : 0);
        $file_handle->print(join("\t",@F)."\n");
    }
    $file_handle->close();
}

sub CreateDataMatrix() {
    my $tissue = shift;

    my %barcode_hash = ();
    my ($idx, $barcode_idx, $run_idx) = (0, -1, -1);
    if(-e "$tissue/SraRunTable.txt"){
        map{$idx++; $run_idx = $idx if($_ eq "Run_s"); $barcode_idx = $idx if($_ eq "Sample_Name_s")}split(/\t/, `head $tissue/SraRunTable.txt | grep ^Assay_Type_s`);
        ($barcode_idx != -1 and $run_idx != -1) or die "ERROR: Unknown file format: SraRunTable.txt\n";
        map{chomp;my @f=split(/\t/,$_);$barcode_hash{$f[0]}=$f[1]}`grep -v ^Assay_Type_s $tissue/SraRunTable.txt | cut -f $run_idx,$barcode_idx`;
    }elsif(-e "$tissue/summary.tsv") {
        map{$idx++; $barcode_idx = $idx if($_ eq "barcode"); $run_idx = $idx if($_ eq "analysis_id")}split(/\t/, `head $tissue/summary.tsv | grep ^study`);
        ($barcode_idx != -1 and $run_idx != -1) or die "ERROR: Unknown file format: summary.tsv\n";
        map{chomp;my @f=split(/\t/,$_);$barcode_hash{$f[1]}=$f[0]}`grep -v ^study $tissue/summary.tsv | cut -f $barcode_idx,$run_idx`;
    }else{
        $data_matrix_fh->close();
        `rm -f "$prefix.txt"`;
        die "ERROR: File SraRunTable.txt or summary.tsv do not exist\n";
    }

    my $column = -1;
    #foreach(`find $tissue -name Quant.genes.results`){
    foreach my $line (`cut -f 1 $tissue/QC/filtered_samples.txt`){
        chomp;
        if(!-s "$tissue/$line/fcounts.fpkm" or !-s "$tissue/$line/Quant.genes.results") {
            print "Warning: Skip $line\n";
            next;
        }
        
        my $quan_file;
        if($quan_unit eq "fpkm"){
            if($quan_tool eq "rsem"){
                $quan_file = "$tissue/$line/ubu-quan/rsem.genes.normalized_results";
            }else{
                $quan_file = "$tissue/$line/ubu-quan/fcounts.fpkm.normalized_results";
            }
        }else{
            if($quan_tool eq "rsem"){
                $quan_file = "$tissue/$line/Quant.genes.results";
            }else{
                $quan_file = "$tissue/$line/fcounts.".$quan_unit;
            }
        }

        my @fields  = split(/\//, $quan_file);
        my $barcode = $barcode_hash{$fields[1]};
        
        my @id = split(/\//, $quan_file);
        push @samples, $id[1];
        $data_matrix_fh->print("\t$barcode($id[0])");
        
        my $n=0;
        if($quan_tool eq "rsem" and $quan_unit ne "fpkm"){
            if ($column == -1){
                my $idx = 0;
                my $col_name = "TPM";
                $col_name = "expected_count" if ($quan_unit eq "count");
                map{ $idx++; $column = $idx if($quan_file eq $col_name) }split(/\t/, `head $quan_file | grep ^gene_id`);
                ($column != -1) or die "Unknown file format: $quan_file\n";
            }
            map{chomp; my @e=split(/\t/); $gene{$e[0]}=1; $expr{$id[1]}{$e[0]}=$e[1];$n++}`cut -f 1,$column $quan_file | tail -n +2`;
        }else{
            map{chomp; my @e=split(/\t/); $gene{$e[0]}=1; $expr{$id[1]}{$e[0]}=$e[1];$n++}`cat $quan_file`;
        }

        
        print "$fields[1]\t$barcode($id[0])\t$n\n";
    }
}

sub ReadSampleExpression() {
    my $tissue = shift;
    
    my %barcode_hash = ();
    my ($idx, $barcode_idx, $run_idx) = (0, -1, -1);
    if(-e "$tissue/SraRunTable.txt"){
        map{$idx++; $run_idx = $idx if($_ eq "Run_s"); $barcode_idx = $idx if($_ eq "Sample_Name_s")}split(/\t/, `head $tissue/SraRunTable.txt | grep ^Assay_Type_s`);
        ($barcode_idx != -1 and $run_idx != -1) or die "ERROR: Unknown file format: SraRunTable.txt\n";
        map{chomp;my @f=split(/\t/,$_);$barcode_hash{$f[0]}=$f[1]}`grep -v ^Assay_Type_s $tissue/SraRunTable.txt | cut -f $run_idx,$barcode_idx`;
    }elsif(-e "$tissue/summary.tsv") {
        map{$idx++; $barcode_idx = $idx if($_ eq "barcode"); $run_idx = $idx if($_ eq "analysis_id")}split(/\t/, `head $tissue/summary.tsv | grep ^study`);
        ($barcode_idx != -1 and $run_idx != -1) or die "ERROR: Unknown file format: summary.tsv\n";
        map{chomp;my @f=split(/\t/,$_);$barcode_hash{$f[1]}=$f[0]}`grep -v ^study $tissue/summary.tsv | cut -f $barcode_idx,$run_idx`;
    }else{
        $data_matrix_fh->close();
        `rm -f "$prefix.txt"`;
        die "ERROR: File SraRunTable.txt or summary.tsv do not exist\n";
    }
    
    #foreach(`find $tissue -name Quant.genes.results`){
    foreach my $line (`cut -f 1 $tissue/QC/filtered_samples.txt`){
        chomp $line;
        if(!-s "$tissue/$line/fcounts.fpkm" or !-s "$tissue/$line/Quant.genes.results") {
            print "Warning: Skip $line\n";
            next;
        }

        my $quan_file;
        if($quan_tool eq "rsem"){
            $quan_file = "$tissue/$line/Quant.genes.results";
        }else{
            $quan_file = "$tissue/$line/fcounts.".$quan_unit;
        }

        if($quan_unit eq 'fpkm'){
            if($quan_tool eq "rsem"){
                my $column = -1;
                my $idx = 0;
                map{ $idx++; $column = $idx if($_ eq "FPKM") }split(/\t/, `head $quan_file | grep ^gene_id`);
                ($column != -1) or die "Unknown file format: $quan_file\n";
                `grep -v gene_id $quan_file | cut -f 1,$column > $tissue/$line/ubu-quan/temp0.txt`;
                $quan_file = "$tissue/$line/ubu-quan/temp0.txt";
            }
            my $tmp_header = IO::File->new( "$tissue/$line/ubu-quan/temp1.txt", ">" ) or die "ERROR: Couldn't create file $tissue/$line/ubu-quan/temp1.txt\n";
            foreach(`cat $quan_file`){
                my @e=split(/\t/, $_);
                next if(! exists $ens2hugo{$e[0]});
                $tmp_header->print($_);
            }
            $tmp_header->close;
            $quan_file = "$tissue/$line/ubu-quan/temp1.txt";
            `perl $ubu_dir/perl/quartile_norm.pl -c 2 -q 75 -t 1000 -o $tissue/$line/ubu-quan/temp2.txt $quan_file`;
            $quan_file = "$tissue/$line/ubu-quan/temp2.txt";
        }
        
        my $barcode = $barcode_hash{$line};
        push @samples, $line;
        #$data_matrix_fh->print("\t$barcode($tissue)");
        $data_matrix_fh->print("\t$barcode");
        
        my $n=0;
        if($quan_tool eq "rsem" and $quan_unit ne "fpkm"){
            my $column = -1;
            my $idx = 0;
            my $col_name = "TPM";
            $col_name = "expected_count" if ($quan_unit eq "count");
            map{ $idx++; $column = $idx if($_ eq $col_name) }split(/\t/, `head $quan_file | grep ^gene_id`);
            ($column != -1) or die "Unknown file format: $quan_file\n";
            map{chomp; my @e=split(/\t/); $gene{$e[0]}=1; $expr{$line}{$e[0]}=$e[1];$n++}`cut -f 1,$column $quan_file | tail -n +2`;
        }else{
            map{chomp; my @e=split(/\t/); $gene{$e[0]}=1; $expr{$line}{$e[0]}=$e[1];$n++}`cat $quan_file`;
            `rm $tissue/$line/ubu-quan/temp*.txt`;
        }
        print "$line\t$barcode($tissue)\t$n\n";
    }
}

