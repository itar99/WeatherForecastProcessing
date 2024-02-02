#! /usr/bin/perl

# forecast.pl
# Gordon Rhea 2-1-2024
# Get the weather information from various sources as defined in the settings file.
# I used a settings file simply because it was easy.  This data could come from a database or a call from a web front end or wherever we want
# Currently this supports the following formats/sources
# US National Weather Service - flat file and API call
# NOAA National Digital Forecast Database (NDFD) - file only.  API calls could be added later
# delimited flat file

# TODO: Better error handling.  We should be able to have an error with reading a file or an API call and still process the rest of the requested data but it needs to be more robust

use Data::Dumper;
use JSON;
use LWP::UserAgent;
use LWP::Protocol::https;
use XML::Hash;

# get the settings and data sources from a file.  
my $settings = load_settings();

my %forecast = ();
foreach my $source (@{$settings->{"source"}})
{
    $forecast{$source->{'name'}} = process_source($source);
    
}

# output the forecast structure we created.  We can return this to a calling function or send it back to an API call or whatever we want.  Just output for now
logit("forecast: \n" . Dumper(%forecast));


sub read_file {
    my ($filename) = @_;

    my $text = "";
    open(my $file, "<", $filename) or logit("ERROR: Cannot open file $filename: $!\n");
    while (my $line = readline($file)) {
        chomp $line;
        $text .= $line;
    }
    close($file);

    return $text;
}

sub load_settings {
    my $settings_file = read_file("settings.json");
    my $settings = decode_json($settings_file);

    return $settings;
}

sub logit {
    my ($msg, $logfile) = @_;
    $logfile = "STDOUT" if !$logfile;
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

    $mon++;
    $year += 1900;
    if($logfile ne "STDOUT") {
        open $logfile, ">>$logfile";
        print $logfile, "$mon-$mday-$year $hour:$min:$sec - \n";
        $logfile ? '' : close LOGFILE;
    } else {
        print "$mon-$mday-$year $hour:$min:$sec - $msg\n";
    }

}

sub process_source {
       my ($source) = @_;
logit("porcess_source: " . Dumper($source));
    return undef if(!defined $source);

    my $forecast = {};
    my $data = {};
    my $file_contents = "";
    if($source->{'type'} eq 'file') {
        # load the file
        my $source_file = $source->{"source_directory"} ? $source->{"source_directory"} . "/" . $source->{"file_name"} : $settings->{"source_directory"} . "/" . $source->{"file_name"};
        if($source->{'mapping'} ne 'DEL') {
            $file_contents = read_file($source_file);
        }
    } elsif($source->{'type'} eq 'api'){
        my $ua = LWP::UserAgent->new;
        my $raw_data = $ua->get($source->{"url"});
        $file_contents = $raw_data->{'_content'};
    }

    if($source->{'format'} eq 'xml') {
        my $xml_converter = XML::Hash->new();
        $data = $xml_converter->fromXMLStringtoHash($file_contents);

    } elsif ($source->{'format'} eq 'json') {
        $data = $file_contents ? decode_json($file_contents) : {};
    }

    # call the processing function
    if($source->{'mapping'} eq 'DEL') {
        my $source_file = $source->{"source_directory"} ? $source->{"source_directory"} . "/" . $source->{"file_name"} : $settings->{"source_directory"} . "/" . $source->{"file_name"};
        $forecast = process_delimited($source_file, $source);
    } else {
        my $func = 'process_' . $source->{'mapping'};
        $forecast = $func->($data, $source);
    }

    return $forecast;
}

# process data in the US National Weather Service (NWS) format regardless of if we get the data from an API call or a file.
# eg call: process_NWS(<data hashref>, <source record hashref>)
sub process_NWS {
    my ($data, $source) = @_;

    return undef if(!defined $data || !$data); # sanity check
    my %forecast = ();
    # National Weather Serivce provides a forecast on a grid system that doesn't match to latitude/longitude directly.  
    # You have to use latitude/longitude to look up the grid for the call.  
    # What we get back from NWS has a GIS Polygon defined that contains the grid you looked up and not the latitude/longitude so get the precise lat/long from the source record.

    $forecast{'latitude'} = $source->{'latitude'}; 
    $forecast{'longitude'} = $source->{'longitude'};
    $forecast{'time'} = $data->{'properties'}{'updated'};

    foreach my $day (@{$data->{"properties"}{"periods"}}){
        $forecast{"daily_forecast"}{$day->{'number'}}{"temperature"} = $day->{'temperature'} . $day->{'temperatureUnit'};
        $forecast{"daily_forecast"}{$day->{'number'} - 1}{"wind_speed"} = $day->{'windSpeed'};
        $forecast{"daily_forecast"}{$day->{'number'} - 1}{"wind_direction"} = $day->{'windDirection'};
        # NWS sometimes sends undefined value for precipitation value.  Just leave it as undef for now so we know they didn't provide anything
        $forecast{"daily_forecast"}{$day->{'number'} - 1}{"precipitation_chance"} = $day->{'probabilityOfPrecipitation'}{'value'}; 
    }

    return \%forecast;
}

# process the data from the NOAA National Digital Forecast Database (NDFD)
# eg call: process_NDFD(<data hashref>, <source record hashref>)
sub process_NDFD {
    my ($data, $source) = @_;
    return undef if(!defined $data || !$data); # sanity check

    my %forecast = ();

    $forecast{'latitude'} = $data->{'location'}{'point'}{'latitude'};
    $forecast{'longitude'} = $data->{'location'}{'point'}{'longitude'};
    $forecast{'time'} = $data->{'time-layout'}[0]{'start-valid-time'}[0]{'text'};
    foreach my $day (0 .. $source->{'days'} - 1){
        
        # NDFD data has an array for each parameter that contains an array for each day provided
        $forecast{"daily_forecast"}{$day}{"temperature"} = $data->{'parameters'}{'temperature'}[0]{'value'}[$day]{'text'}; # array location 0 is max temperature which is what we want for the forecast
        $forecast{"daily_forecast"}{$day}{"wind_speed"} = $data->{'parameters'}{'wind-speed'}[0]{'value'}[$day]{'text'};
        $forecast{"daily_forecast"}{$day}{"wind_direction"} = $data->{'parameters'}{'direction'}{'value'}[$day]{'text'}; # this is 'degrees true' whatever that means.  TODO: Write a translator to North South East West format
        
        foreach my $rec (@{$data->{'parameters'}{'weather'}{'weather-conditions'}}) {
            # NDFD just provides us an array of weather conditions with no obvious way to tell what is for what day so just find a rain record for now and if we do more research how the heck this is organized
            next if(!$rec || $rec->{'value'}{'weather-type'} ne 'rain');

            $forecast{"daily_forecast"}{$day}{"precipitation_chance"} = $rec->{'value'}->{'coverage'};

            last; # just end after we found one for now
        }
    }

    return \%forecast;
}

# process a delimited flat file that may or may not have a header row (specified in the source record)
sub process_delimited {
    my ($filename, $source) = @_;

    my %forecast = ();

    open(my $file, "<", $filename) or logit("ERROR: Cannot open file $filename: $!\n");
    
    my @fields = @{$source->{'col_mapping'}};
    my $count = 1;
    # assume each line is one day
    while (my $line = readline($file)) {
        chomp $line;

        my @data = split($source->{'seperator'}, $line);

        if($count== 1 && $source->{'header'} eq 'y') {
            # it's the header line.  See if we have a column mapping specified and if we don't then use the header as our fields mapping
            # note: If we say there's a header but there's not AND we don't specify a column mapping this could return some funky looking data
            if(!defined($source->{'col_mapping'})) {
                @fields = @data;
            }
        } else {
            for (my $i = 0; $i <= $#fields; $i++) {
                $forecast{'daily_forecast'}{$count}{$fields[$i]} = $data[$i];
                # there's got to be a less kludgy way to do this
                if(lc($fields[$i]) eq 'latitude') { $forecast{'latitude'} = $data[$i]; }
                if(lc($fields[$i]) eq 'longitude') { $forecast{'longitude'} = $data[$i]; }
            }
        }
        $count++;
    }

    close($file);
    return \%forecast;
}