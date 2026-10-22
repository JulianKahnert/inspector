#!/usr/bin/env bash
# PROTOTYPE 07: filter an Xcode-MCP hierarchy.txt to interactive elements as JSON.
# Usage: targets.sh <hierarchy.txt>
perl -ne '
  next unless /^\s*(Button|Cell|TextField|SecureTextField|Switch|Slider|SegmentedControl|Toggle|Link|TabBar|Tab|SearchField|Stepper|Picker|Image)\b/;
  my $type=$1; my ($id)=/identifier: \x27([^\x27]*)\x27/; my ($label)=/label: \x27([^\x27]*)\x27/; my ($v)=/value: \x27([^\x27]*)\x27/;
  my ($x,$y)=/hitPoint: \{([\d.\-]+), ([\d.\-]+)\}/;
  next unless defined $x;
  next if $type eq "Image" && !defined $label;
  for ($id,$label,$v){ s/\\/\\\\/g; s/"/\\"/g if defined }
  push @out, sprintf("{\"type\":\"%s\"%s%s%s,\"hitPoint\":[%s,%s]}", $type, defined $id?",\"identifier\":\"$id\"":"", defined $label?",\"label\":\"$label\"":"", defined $v?",\"value\":\"$v\"":"", $x,$y);
  END { print "[".join(",",@out)."]\n" }'  "$1"
