=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2022] EMBL-European Bioinformatics Institute

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

 mutfunc

=head1 SYNOPSIS

 mv mutfunc.pm ~/.vep/Plugins
 ./vep -i variations.vcf --plugin mutfunc,motif=1,db=/FULL_PATH_TO/mutfunc_human_data.db
 ./vep -i variations.vcf --plugin mutfunc,all=1,file=/FULL_PATH_TO/mutfunc_tfbs.tab.gz,db=/FULL_PATH_TO/mutfunc_human_data.db
 ./vep -i variations.vcf --plugin mutfunc,all=1,extended=1,file=/FULL_PATH_TO/mutfunc_tfbs.tab.gz,db=/FULL_PATH_TO/mutfunc_human_data.db

=head1 DESCRIPTION

 A VEP plugin that retrieves data from mutfunc db predicting destabilization of protein structure, interaction. regulatory region etc.
 
 Please cite the IntAct publication alongside the VEP if you use this resource:
 https://www.embopress.org/doi/full/10.15252/msb.20188430
 
 Pre-requisites:
 
 1) The data file. mutfunc SQLite db can be downloaded from - 
 http://ftp.ensembl.org/pub/current_variation/variation/mutfunc/
 
 Options are passed to the plugin as key=value pairs:

 file		  : Path to tabix-indexed tfbs data file. Mandatory if 'tfbs' or 'all' is selected
 db			  : Path to SQLite database containing data for other analysis. Mandatory 'motif', 'int', 'mod', 'exp' or 'all' is selected
 motif    : Select this option to have mutfunc motif analysis in the output
 int      : Select this option to have mutfunc protein interection analysis in the output
 mod      : Select this option to have mutfunc protein structure analysis in the output
 exp      : Select this option to have mutfunc protein structure (experimental) analysis in the output
 all      : Select this option to have all of the above analysis in the output
 extended : By default mutfunc outputs the most significant field for any analysis. Select this option to get more verbose output.

=cut

package mutfunc;

use strict;
use warnings;
use DBI;
use Compress::Zlib;
use Digest::MD5 qw(md5_hex);
use List::MoreUtils qw(first_index);

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Variation::Utils::Sequence qw(get_matched_variant_alleles);
use Bio::EnsEMBL::Variation::Utils::BaseVepPlugin;

use base qw(Bio::EnsEMBL::Variation::Utils::BaseVepPlugin);

my @ALL_AAS = qw(A C D E F G H I K L M N P Q R S T V W Y);

my $field_order = {
  motif => ["elm", "lost"],
  int   => ["evidence", "dG_wt", "dG_mt", "ddG", "dG_wt_sd", "dG_mt_sd", "ddG_sd"],
  mod   => ["dG_wt", "dG_mt", "ddG", "dG_wt_sd", "dG_mt_sd", "ddG_sd"],
  exp   => ["dG_wt", "dG_mt", "ddG", "dG_wt_sd", "dG_mt_sd", "ddG_sd"]
};

sub new {
  my $class = shift;
  
  my $self = $class->SUPER::new(@_);
  
  my $param_hash = $self->params_to_hash();

  $self->{motif} = 1 if $param_hash->{motif} || $param_hash->{all};
  $self->{int} = 1 if $param_hash->{int} || $param_hash->{all};
  $self->{mod} = 1 if $param_hash->{mod} || $param_hash->{all};
  $self->{exp} = 1 if $param_hash->{exp} || $param_hash->{all};

  die "ERROR: db is not specified but some of the options enabled require it\n" if ( 
    ( (defined $self->{motif}) || 
      (defined $self->{int}) || 
      (defined $self->{mod}) || 
      (defined $self->{exp}) 
    ) && 
    !(defined $param_hash->{db}) 
  );
  $self->{db} = $param_hash->{db};

  $self->{extended} = 1 if $param_hash->{extended};

  if( ($self->{config}->{output_format} eq "json") || $self->{config}->{rest}){
    $self->{output_json} = 1;
  }

  $self->{initial_pid} = $$;

  return $self;
}

sub feature_types {
  return ['Transcript'];
}

sub get_header_info {
  my ($self) = shift;
  
  my %header;

  if (defined $self->{motif}){
    $header{mutfunc_motif} = "Nonsynonymous mutations impact on linear motif from mutfunc db. Output field(s) include: ";
    if (defined $self->{extended}){
      $header{mutfunc_motif} .= $self->{config}->{output_format} eq "vcf" ? "(fields are separated by '&') " : "(fields are separated by ',') ";
    }
    $header{mutfunc_motif} .= "elm - ELM accession of the linear motif, " if defined $self->{extended};
    $header{mutfunc_motif} .= "lost - '1' if the mutation causes the motif to be lost and '0' otherwise";
  }

  foreach (qw(int mod exp)){
    if (defined $self->{$_}) {
      my $key = "mutfunc_" . $_;
      $header{$key} = "Interaction interfaces destabilization analysis from mutfunc db. Output field(s) include: ";
      if (defined $self->{extended}){
        $header{$key} .= $self->{config}->{output_format} eq "vcf" ? "(fields are separated by '&') " : "(fields are separated by ',') ";
      }
      $header{$key} .= "evidence - 'EXP' for experimental model and 'MDL' for homology models and 'MDD' for domain-domain homology models, " if ($_ eq "int" && (defined $self->{extended}));
      $header{$key} .= "dG_wt - reference interface energy (kcal/mol), " if defined $self->{extended};
      $header{$key} .= "dG_mt - mutated interface energy (kcal/mol), " if defined $self->{extended};
      $header{$key} .= "ddG - change in interface stability between mutated and reference structure (kcal/mol) mutations where ddG >= 2 kcal/mol can be considered deleterious, ";
      $header{$key} .= "dG_wt_sd - dG_wt standard deviation (kcal/mol), " if defined $self->{extended};
      $header{$key} .= "dG_mt_sd - dG_mt standard deviation (kcal/mol), " if defined $self->{extended};
      $header{$key} .= "ddG_sd - ddG standard deviation (kcal/mol), " if defined $self->{extended};
    }
  }

  return \%header;
}

sub expand_matrix {
  my ($matrix) = @_;
  my $expanded_matrix = Compress::Zlib::memGunzip($matrix) or 
    throw("Failed to gunzip: $gzerrno");

  return $expanded_matrix;
}

sub retrieve_item_value {
  my ($matrix, $pos, $aa, $tot_packed_len) = @_;

  my $item_value = (substr $matrix, $pos * $tot_packed_len * 20 + $aa * $tot_packed_len, $tot_packed_len );

  return $item_value;
}

sub parse_motif {
  my ($item_value) = @_;

  my ($elm, $lost) = unpack "A24v", $item_value;

  $elm = undef if $elm eq "undefined";
  $lost = undef if $lost == 0xFFFF;

  return $elm, $lost;
}

sub parse_destabilizers {
  my ($item_value, $item) = @_;
  my @evidence_lval = qw(EXP MDD MDL);
  my $evidence_val;

  # only int item type have evidence
  if ($item eq "int"){
    my $evidence = unpack "v", $item_value;

    # now omit the evidence part from item value
    $item_value = substr $item_value, 2; 

    # get the value of the evidence
    $evidence = undef if $evidence == 0xFFFF;
    $evidence_val = defined $evidence ? $evidence_lval[$evidence] : undef;
  }
  
  # get the rest
  my ($dG_wt, $ddG, $dG_wt_sd, $dG_mt_sd, $ddG_sd) = unpack "A8A8A8A8A8", $item_value;

  $dG_wt = undef if $dG_wt eq "10000000";
  $ddG = undef if $ddG eq "10000000";
  $dG_wt_sd = undef if $dG_wt_sd eq "10000000";
  $dG_mt_sd = undef if $dG_mt_sd eq "10000000";
  $ddG_sd = undef if $ddG_sd eq "10000000";

  return $evidence_val, $dG_wt, $ddG, $dG_wt_sd, $dG_mt_sd, $ddG_sd if $item eq "int";
  return $dG_wt, $ddG, $dG_wt_sd, $dG_mt_sd, $ddG_sd;
}

sub format_output{
  my ($self, $data, $item) = @_;

  my $result = {};

  if ($self->{output_json}){
    my %hash;
    if( $self->{extended}){
      %hash = map { $_ => $data->{$_} } @{ $field_order->{$item} };
    }
    else{
      %hash = map { $_ => $data->{$_} } keys %$data;
    }
    $result->{$item} = \%hash;
  }
  else{
    my $key = "mutfunc_" . $item;
    if( $self->{extended}){
      $result->{$key} = join(",", map { $data->{$_} } @{ $field_order->{$item} });
    }
    else {
      $result->{$key} = join(",", map { $data->{$_} } keys %$data );
    }
  }

  return $result;
}

sub process_from_db {
  my ($self, $tva) = @_;

  # get the trascript related to the variant
  my $tr = $tva->transcript;

  # get the translation
  my $translation = $tr->translate;
  return {} unless $translation;

  # get the md5 hash of the peptide sequence
  my $md5 = md5_hex($translation->seq);

  # forked, reconnect to DB
  if($$ != $self->{initial_pid}) {
    $self->{dbh} = DBI->connect("dbi:SQLite:dbname=".$self->{db},"","");
    $self->{get_sth} = $self->{dbh}->prepare("SELECT md5, item, matrix FROM consequences WHERE md5 = ?");

    # set this so only do once per fork
    $self->{initial_pid} = $$;
  }
  $self->{get_sth}->execute($md5);

  my $result_from_db = {};
  while (my $arrayref = $self->{get_sth}->fetchrow_arrayref) {
    my $item = $arrayref->[1];
    my $matrix = $arrayref->[2];

    # expand the compressed matrix
    my $expanded_matrix = expand_matrix($matrix);

    # position and peptide to retrieve value from matrix
    my $pos = $tva->transcript_variation->translation_start;
    my $peptide = $tva->peptide;

    # in matrix position is 0 indexed
    $pos--;

    # we need position of peptide in the ALL_AAS array
    my $peptide_number = (first_index { $_ eq $peptide } @ALL_AAS);

    # get matrix for each item value and parse them
    # motif
    if ($item eq "motif" && $self->{motif}) {
      # get the item value for specific pos and amino acid from matrix
      my $tot_packed_len = 26;
      my $item_value = retrieve_item_value($expanded_matrix, $pos, $peptide_number, $tot_packed_len);

      if ($item_value){
        # parse the item value from matrix
        my ($elm, $lost) = parse_motif($item_value);

        # format the output
        if(defined $elm || defined $lost){
          my $data = $self->{extended} ? {
            elm   => $elm,
            lost  => $lost
          } : {
            lost  => $lost
          };

          my $formatted_output = $self->format_output($data, $item);
          @$result_from_db{ keys %$formatted_output } = values %$formatted_output;
        }
      }
    }
    # int and mod and exp
    elsif ($item eq "int" || $item eq "mod" || $item eq "exp") {
      if ($self->{$item}){
        # get the item value for specific pos and amino acid from matrix
        my $tot_packed_len = ($item eq "int") ? 42 : 40;
        my $item_value = retrieve_item_value($expanded_matrix, $pos, $peptide_number, $tot_packed_len);

        if ($item_value){
          # parse the item value from matrix
          my ($evidence, $dG_wt, $ddG, $dG_wt_sd, $dG_mt_sd, $ddG_sd);
          if ($item eq "int"){
            ($evidence, $dG_wt, $ddG, $dG_wt_sd, $dG_mt_sd, $ddG_sd) = parse_destabilizers($item_value, $item);
          }
          else{
            ($dG_wt, $ddG, $dG_wt_sd, $dG_mt_sd, $ddG_sd) = parse_destabilizers($item_value, $item);
          }

          # dG_mt can be calculated from dG_wt and ddG
          my $dG_mt = (defined $dG_wt && defined $ddG) ? $dG_wt + $ddG : undef;

          # format the output
          if(defined $evidence || defined $dG_wt || defined $ddG || defined $dG_wt_sd || defined $dG_mt_sd || defined $ddG_sd){
            my $data = $self->{extended} ? {
              dG_wt   => $dG_wt,
              dG_mt  => $dG_mt,
              ddG   => $ddG,
              dG_wt_sd  => $dG_wt_sd,
              dG_mt_sd   => $dG_mt_sd,
              ddG_sd  => $ddG_sd
            } : {
              ddG   => $ddG
            };
            
            $data->{evidence} = $evidence if (defined $evidence && $item eq "int" && $self->{extended});  
            
            my $formatted_output = $self->format_output($data, $item);
            @$result_from_db{ keys %$formatted_output } = values %$formatted_output;
          }
        }
      }
    }
  }

  return $result_from_db;
}

sub run {
  my ($self, $tva) = @_;
  
  my $result = {};

  my $hash_from_db = $self->process_from_db($tva);
  @$result{ keys %$hash_from_db } = values %$hash_from_db;

  return {} unless %$result;
  return $self->{output_json} ? {"mutfunc" => $result} : $result;
}

1;
