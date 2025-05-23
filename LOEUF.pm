=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2025] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 CONTACT

 Ensembl <http://www.ensembl.org/info/about/contact/index.html>

=cut

=head1 NAME

 LOEUF

=head1 SYNOPSIS

 mv LOEUF.pm ~/.vep/Plugins
 ./vep -i variations.vcf --plugin LOEUF,file=/path/to/loeuf/data.tsv.gz,match_by=gene
 ./vep -i variations.vcf --plugin LOEUF,file=/path/to/loeuf/data.tsv.gz,match_by=transcript

=head1 DESCRIPTION

 This is a plugin for the Ensembl Variant Effect Predictor (VEP) that
 adds the LOEUF scores to VEP output. LOEUF stands for the "loss-of-function 
 observed/expected upper bound fraction." 

 The score can be added matching by either transcript or gene.
 When matched by gene: 
 If multiple transcripts are available for a gene, the most severe score is reported.

 NB: The plugin currently does not add the score for downstream_gene_variant and upstream_gene_variant 

 Please cite the LOEUF publication alongside the VEP if you use this resource:
 https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7334197/


 LOEUF scores can be downloaded from
 GRCh37: https://gnomad.broadinstitute.org/downloads#v2-constraint (pLoF Metrics by Gene TSV)
 GRCh38: https://gnomad.broadinstitute.org/downloads#v4-constraint (Constraint metrics TSV)

 For GRCh37:
 These files can be tabix-processed by:
 zcat gnomad.v2.1.1.lof_metrics.by_gene.txt.bgz | (head -n 1 && tail -n +2  | sort -t$'\t' -k 76,76 -k 77,77n ) > loeuf_temp.tsv
 sed '1s/.*/#&/' loeuf_temp.tsv > loeuf_dataset.tsv
 bgzip loeuf_dataset.tsv
 tabix -f -s 76 -b 77 -e 78 loeuf_dataset.tsv.gz

 For GRCh38:
 The GRCh38 file does not have gene co-ordinates information. First you need to add the gene co-ordiates information.
 You can use the Ensembl Perl API to create a script and perform that - https://www.ensembl.org/info/docs/api/core/index.html.
 After adding the start and end position of the genes at the last 2 columns you can process the file as follows:
 cat gnomad.v4.1.constraint_metrics_with_coordinates.tsv | (head -n 1 && tail -n +2  | sort -t$'\t' -k 53,53 -k 56,56n ) > loeuf_grch38_temp.tsv
 sed '1s/.*/#&/' loeuf_grch38_temp.tsv > loeuf_dataset_grch38.tsv
 bgzip loeuf_dataset_grch38.tsv
 tabix -f -s 53 -b 56 -e 57 loeuf_dataset_grch38.tsv.gz


 The tabix utility must be installed in your path to use this plugin.

=cut

package LOEUF;

use strict;
use warnings;

use Bio::EnsEMBL::Variation::Utils::BaseVepTabixPlugin;

use base qw(Bio::EnsEMBL::Variation::Utils::BaseVepTabixPlugin);

use Scalar::Util qw(looks_like_number);

# gnomAD v2 and v4 data have different headers
my $valid_headers = {
  "v2" => {
    "index" => [1, 30, 64],
    "header" => ["transcript", "oe_lof_upper", "gene_id"]
  },
  "v4" => {
    "index" => [2, 22, 1],
    "header" => ["transcript", "lof.oe_ci.upper", "gene_id"]
  }
};

sub new {
  my $class = shift;

  my $self = $class->SUPER::new(@_);

  $self->expand_left(0);
  $self->expand_right(0);

  my $param_hash = $self->params_to_hash();
  
  # Test tabix
  die "ERROR: tabix does not seem to be in your path\n" unless `which tabix 2>&1` =~ /tabix$/;

  # Get file
  die "ERROR: LOEUF file not provided or not found!\n" unless defined($param_hash->{file}) && -e $param_hash->{file};
  $self->add_file($param_hash->{file});

  # Get headers from file
  my $headers;
  open HEAD,"tabix -H $param_hash->{file} 2>&1 | ";
  while(<HEAD>) {
    chomp;
    $_ =~ s/^\#//;
    $headers = [split];
  }
  close HEAD;

  # Compare indexes of expected and observed columns
  die "ERROR: Could not read headers from $param_hash->{file}\n" unless defined($headers) && scalar @{$headers};

  my @missing_columns;
  foreach my $version (keys %{ $valid_headers }){
    my $i = 0;
    @missing_columns = ();
    foreach my $index ( @{ $valid_headers->{$version}->{"index"} }){
      my $exp_column = $valid_headers->{$version}->{"header"}->[$i];
      my $obs_column = $headers->[$index] ? $headers->[$index] : "";

      push @missing_columns, $exp_column if $exp_column ne $obs_column;
      $i++;
    }

    unless (@missing_columns) {
      $self->{data_version} = $version;
      last;
    }
  }
  my $missing_columns_str =  join(", ", @missing_columns) if scalar @missing_columns;
  die "ERROR: Missing columns: $missing_columns_str\n" if defined($missing_columns_str);

  # Check match_by argument and store on self
  if(defined($param_hash->{match_by})) {
    my $match_by = $param_hash->{match_by};
    $self->{match_by} = $match_by;
  }

  else{
    die "ERROR: Argument 'match_by' is undefined\n" ;
  }

  return $self;
}

sub feature_types {
  return ['Transcript'];
}

sub get_header_info {
  return { LOEUF => 'Loss-of-function observed/expected upper bound fraction'};
}

sub run {
  my ($self, $tva) = @_;

  return {} if grep {$_->SO_term eq 'downstream_gene_variant' || $_->SO_term eq 'upstream_gene_variant'} @{$tva->get_all_OverlapConsequences};
  
  my $vf = $tva->variation_feature;
  my $transcript = $tva->transcript;
  my $end = $vf->{end};
  my $start = $vf->{start};
  ($start, $end) = ($end, $start) if $start > $end;
  
  if ($self->{match_by} eq 'transcript'){
    my ($res) = grep {
    $_->{transcript_id}  eq $transcript->stable_id;
    } @{$self->get_data($vf->{chr}, $start, $end)};
    return $res ? $res->{result} : {};
  }

  elsif ($self->{match_by} eq 'gene'){
    my @data = grep {
    $_->{gene_id} eq $transcript->{_gene_stable_id}
    } @{$self->get_data($vf->{chr}, $start, $end)};
    # Get min loeuf value for the gene
    my $min_loeuf_score;
    my $first_entry_flag = 0;
    foreach (@data){
      if (looks_like_number($_->{result}->{LOEUF})){
        if (!$first_entry_flag){
          $min_loeuf_score = $_->{result}->{LOEUF};
          $first_entry_flag = 1 ;
          next;
        }

        if ($_->{result}->{LOEUF} < $min_loeuf_score){
          $min_loeuf_score = $_->{result}->{LOEUF};
        }
      }
    }
    return $min_loeuf_score ? {LOEUF => $min_loeuf_score} : {};
  }

  else{
    return {};
  }

}

sub parse_data {
  my ($self, $line) = @_;
  my @values = split /\t/, $line;

  my ($transcript_id, $oe_lof_upper, $gene_id) = $self->{data_version} ? 
    @values[ @{ $valid_headers->{$self->{data_version}}->{"index"} } ] : @values[1,30,64];
  return {
    gene_id => $gene_id,
    transcript_id => $transcript_id,
    result => {
      LOEUF   => $oe_lof_upper,
    }
  };
}

sub get_start {
  return $_[1]->{start};
}

sub get_end {
  return $_[1]->{end};
}

1;
