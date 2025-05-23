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

 Conservation

=head1 SYNOPSIS

 mv Conservation.pm ~/.vep/Plugins
 
 ./vep -i variations.vcf --plugin Conservation,mammals
 ./vep -i variations.vcf --plugin Conservation,/path/to/bigwigfile.bw
 ./vep -i variations.vcf --plugin Conservation,/path/to/bigwigfile.bw,MAX
 ./vep -i variations.vcf --plugin Conservation,database,GERP_CONSERVATION_SCORE,mammals
 ./vep -i variations.vcf --plugin Conservation,database,GERP_CONSERVATION_SCORE,mammals,MAX

=head1 DESCRIPTION

 This is a plugin for the Ensembl Variant Effect Predictor (VEP) that
 retrieves a conservation score from the Ensembl Compara databases
 for variant positions. You can specify the method link type and
 species sets as command line options, the default is to fetch GERP
 scores from the EPO 35 way mammalian alignment (please refer to the
 Compara documentation for more details of available analyses). 

 If a variant affects multiple nucleotides the average score for the
 position will be returned, and for insertions the average score of
 the 2 flanking bases will be returned. If the MAX parameter is
 used, the maximum score of any of the affected bases will be reported
 instead.

 The plugin uses the ensembl-compara API module (optional, see
 http://www.ensembl.org/info/docs/api/index.html) or obtains data
 directly from BigWig files (optional, see
 https://ftp.ensembl.org/pub/current_compara/conservation_scores/)

=cut
package Conservation;

use strict;
use warnings;

use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::Slice;
use Bio::EnsEMBL::IO::Parser::BigWig;
use Bio::EnsEMBL::Variation::Utils::BaseVepPlugin;
use Net::FTP;

use base qw(Bio::EnsEMBL::Variation::Utils::BaseVepPlugin);

sub new {
    my $class = shift;

    my $self = $class->SUPER::new(@_);
    
    if(scalar(@{$self->params}) == 0){
      warn('No input parameters found for Conservation plugin');
      return $self;
    }
    # Check for MAX, otherwise default to AVERAGE
    for(@{$self->params}) {
        if ($_ eq 'MAX') {
            $self->{method} = 'MAX';
        }
        else {
            $self->{method} = 'AVERAGE';
        }
    }
    
    $self->{use_database} = $self->params->[0] eq 'database';

    if($self->{use_database}){
      shift(@{$self->params});
      my $params = $self->params;

      # REST API passes 1 as first param
      shift @$params if $params->[0] && $params->[0] eq '1';

      $self->{method_link_type} = $params->[0] || 'GERP_CONSERVATION_SCORE';
      $self->{species_set}  = $params->[1] || 'mammals';

      my $config = $self->{config};
      my $reg = 'Bio::EnsEMBL::Registry';

      # reconnect to DB without species param
      if($config->{host}) {
          $reg->load_registry_from_db(
              -host       => $config->{host},
              -user       => $config->{user},
              -pass       => $config->{password},
              -port       => $config->{port},
              -db_version => $config->{db_version},
              -no_cache   => $config->{no_slice_cache},
          );
      }

      my $mlss_adap = $config->{mlssa} ||= $reg->get_adaptor('Multi', 'compara', 'MethodLinkSpeciesSet')
          or die "Failed to connect to compara database\n";

      $self->{mlss} = $mlss_adap->fetch_by_method_link_type_species_set_name($self->{method_link_type}, $self->{species_set})
          or die "Failed to fetch MLSS for ".$self->{method_link_type}." and ".$self->{species_set}."\n";

      $self->{cs_adap} = $config->{cosa} ||= $reg->get_adaptor('Multi', 'compara', 'ConservationScore')
          or die "Failed to fetch conservation adaptor\n";
    }
    return $self;
}
sub version {
    return '3.0';
}

sub feature_types {
    return ['Feature','Intergenic'];
}

sub get_header_info {

    my $self = shift;
    my $method_str = $self->{method} eq 'MAX' ? "maximum" : "average";
    return {
        Conservation => "The $method_str conservation score for this site"
    };
}

sub run {
  my ($self, $tva) = @_;
  
  #We don't want to remove any old functionality, so we allow users to directly access the database if they so choose

  return db_run($self, $tva) if $self->{use_database};
  my $filename;
  return {} if (scalar(@{$self->params}) eq 0);
  
  #if it doesn't look like the user has given an FTP link or a file, try and find the correct data
  if(@{$self->params}[0] !~ /ftp.ensembl.org/ && not -f @{$self->params}[0])
  {
    my $FTP_URL = "http://ftp.ensembl.org/pub/current_compara/conservation_scores/";
    my $FTP_USER = 'anonymous';  
    $FTP_URL =~ m/(http:\/\/)?(.+?)\/(.+)/;  
    
    my $ftp = Net::FTP->new($2, Passive => 1) or die "ERROR: Could not connect to FTP host $FTP_URL\n$@\n";
    $ftp->login($FTP_USER) or die "ERROR: Could not login as $FTP_USER\n$@\n";
    $ftp->binary();
    foreach my $sub(split /\//, $3) {
      $ftp->cwd($sub) or die "ERROR: Could not change directory to $sub\n$@\n";
    }
    
    my @files = $ftp->ls;
    my @dir_to_enter = grep(/@{$self->params}[0]/, @files);
    if(scalar(@dir_to_enter) != 1)
    {
      warn('Unable to find matching data on FTP site');
      return {};
    }
  
    my $species = $self->config->{species};
    my $group = shift(@dir_to_enter);
    $ftp->cwd($group);
    @files = $ftp->ls;
  
    my $assembly = $self->{config}->{assembly};
    @dir_to_enter = grep(/$assembly/, grep(/$species/, @files));
    if(scalar(@dir_to_enter) != 1)
    {
      warn('Unable to find matching data on FTP site');
      return {};
    }
    $filename = $FTP_URL . $group . '/' . shift(@dir_to_enter);
  }
  else{
    $filename = @{$self->params}[0] if scalar(@{$self->params});
  }
  #Parse and strip out the expected info from the BigWig file
  my $parser = Bio::EnsEMBL::IO::Parser::BigWig->open($filename);
  my $vf = $tva->variation_feature;
  unless($parser){
    warn ("No BigWig file found for plugin Conservation \n"); 
    return {};
  }

  my $chr = $vf->{chr};
  $chr =~ s/^chr//i;

  #Check if insertion and adjust to capture flanking bases
  if ($vf->{start} - 1 == $vf->{end}){
    $parser->seek($chr, $vf->{start} - 2, $vf->{end} + 1);
  }
  else{
    $parser->seek($chr, $vf->{start} - 1, $vf->{end});
  }
  
  return {} unless $parser->{waiting_block};

  # Grab the score
  my @values = ();
  my $length = $parser->{waiting_block}[2] - $parser->{waiting_block}[1];
  my $divide = 0;

  while($length >= 2) {
    push @values, $parser->{waiting_block}[3];
    $divide++;
    $length--;
  }
  
  # If multiple bases affected, grab those scores as well from the oparser object
  foreach (@{ $parser->{cache}->{features} }) {
    my $length = @{$_}[2] - @{$_}[1];
    # If the interval of the feature is >2 it means multiple positions have the same score
    # Below code will capture if single or multiple scores are in the interval.
    while($length >= 2) {
        push @values, @{$_}[3];
        $divide++;
        $length--;
    }
  }
  $parser->next;

  # Output - if multiple scores do average or max, if single score just output that.
  if (scalar(@values) > 1 ) {
    if ($self->{method} eq 'MAX') {
        my @sorted = sort(@values);
        return { Conservation => sprintf("%.3f", $sorted[-1])};
    }
    else {
        my $total = 0;
        $total += $_ for @values;
        my $average = $total / $divide;
        return { Conservation => sprintf("%.3f", $average)};
    }
  }
  else {
    return { Conservation => sprintf("%.3f", $values[0])};
  }
}

sub db_run {
    my ($self, $bvfoa) = @_;
    my $bvf = $bvfoa->base_variation_feature;

    # we cache the score on the BaseVariationFeature so we don't have to
    # fetch it multiple times if this variant overlaps multiple Features
    unless (exists $bvf->{_conservation_score}) {
        my $slice;
        my $true_snp = 0;
        if ($bvf->{end} >= $bvf->{start}) {
            if ($bvf->{start} == $bvf->{end}) {

                # work around a bug in the compara API that means you can't fetch 
                # conservation scores for 1bp slices by creating a 2bp slice for
                # SNPs and then ignoring the score returned for the second position
                my $s = $bvf->slice;
                $slice = Bio::EnsEMBL::Slice->new(
                    -seq_region_name   => $s->seq_region_name,
                    -seq_region_length => $s->seq_region_length,
                    -coord_system      => $s->coord_system,
                    -start             => $bvf->{start},
                    -end               => $bvf->{end} + 1,
                    -strand            => $bvf->{strand},
                    -adaptor           => $s->adaptor
                );               
                $true_snp = 1;
            }
            else {
                # otherwise, just get a slice that covers our variant feature
                $slice = $bvf->feature_Slice;
            }
        }
        else {
            # this is an insertion, we return the average score of the flanking 
            # bases, so we create a 2bp slice around the insertion site
            my $s = $bvf->slice;
            $slice = Bio::EnsEMBL::Slice->new(
                -seq_region_name   => $s->seq_region_name,
                -seq_region_length => $s->seq_region_length,
                -coord_system      => $s->coord_system,
                -start             => $bvf->{end},
                -end               => $bvf->{start},
                -strand            => $bvf->{strand},
                -adaptor           => $s->adaptor
            );
        }

        my $scores = $self->{cs_adap}->fetch_all_by_MethodLinkSpeciesSet_Slice(
            $self->{mlss},                      # our MLSS for the conservation metric and the set of species
            $slice,                             # our slice
            ($slice->end - $slice->start + 1),  # the number of scores we want back (one for each base)
        );

        if (@$scores > 0) {
            # we use the simple average of the diff_scores as the overall score         
            pop @$scores if $true_snp; # get rid of our spurious second score for SNPs
            my @values;
            
            for (@$scores) {
                push @values, $_->diff_score;
            }

            if (@$scores > 0) {
                if ($self->{method} eq 'AVERAGE') {
                    my $tot_score = 0;
                    $tot_score += $_ for @values;
                    $tot_score /= @values;
                    $bvf->{_conservation_score} = sprintf "%.3f", $tot_score;
                }
                elsif ($self->{method} eq 'MAX') {
                    my @sorted = sort(@values);
                    $bvf->{_conservation_score} = sprintf "%.3f", $sorted[-1];
                }
            }
            else {
                $bvf->{_conservation_score} = undef;
            }
        }
        else {
            $bvf->{_conservation_score} = undef;
        }
    }

    if (defined $bvf->{_conservation_score}) {
        return {
            Conservation => $bvf->{_conservation_score}
        };
    }
    else {
        return {};
    }
}
1;