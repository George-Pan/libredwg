#!/usr/bin/perl -w
# Copyright (C) 2019-2020 Free Software Foundation, Inc., GPL3
#
# Generate src/dynapi.c and test/unit-testing/dynapi_test.c
# C structs/arrays for all dwg objects and its fields for a dynamic API.
#   -> name, type, size, offset, dxfgroup, memory-type
# Within each object linear search is good enough.
# This is needed for in_dxf, dwgfilter,
# a maintainable and shorter dwg_api and shorter language bindings.
# Written by: Reini Urban

#dwg.h:
# typedef struct _dwg_header_variables
# typedef struct _dwg_entity_(.*)
# typedef struct _dwg_object_(.*)
#subclasses, typically like
# typedef struct _dwg_TYPE_subclass
# typedef union _dwg_MLEADER_Content

use strict;
use warnings;
use vars qw(@entity_names @object_names @subclasses
            $max_entity_names $max_object_names);
use Convert::Binary::C;
#use Data::Dumper; # if DEBUG
#BEGIN { chdir 'src' if $0 =~ /src/; }

# add gcc/clang -print-search-dirs paths
my (@ccincdir, $srcdir, $topdir);
if ($0 =~ m{(^\.\./.*src)/gen}) {
  $srcdir = $1;
  $topdir = "$srcdir/..";
} elsif ($0 =~ m{^src/gen}) {
  $srcdir = "src";
  $topdir = ".";
} else {
  $srcdir = ".";
  $topdir = "..";
}
my $CC = `grep '^CC =' Makefile`;
if ($CC) {
  $CC =~ s/^CC =//;
  chomp $CC;
  $CC =~ s/^\s+//;
  if ($CC =~ /^afl-(gcc|clang)/) {
    $ENV{AFL_QUIET} = 1;
  }
  my $out = `$CC -print-search-dirs`;
  if ($out) {
    if ($out =~ /^install: (.+?)$/m) {
      my $d = $1;
      $d =~ s/\/$//;
      @ccincdir = ("$d/include") if -d "$d/include";
    } elsif ($out =~ /^libraries: =(.+?)$/m) {
      @ccincdir = grep { -d "$_/include" ? "$_/include" : undef }
                       split ':', $1;
    }
  }
}
#__WORDSIZE=64
# glibc quirks to include stdint.h and stddef.h directly with this old pre-C99
# Convert::Binary::C preprocessor
my @defines = ('__GNUC__=4', '__x86_64__', '__inline=inline',
               '__THROW=', '__attribute__(x)=');
if ($^O =~ /darwin|bsd/) {
  push @defines, ('__signed=signed', '__builtin_va_list=void*', '__extension__=');
}
if (@ccincdir and join(" ",@ccincdir) =~ /clang/) {
  push @defines, ('__has_feature(x)=0', '__has_include_next(x)=0',
                  '__INTPTR_TYPE__=long int', '__UINTPTR_TYPE__=unsigned long int',
                  '__INTMAX_TYPE__=long int', '__UINTMAX_TYPE__=unsigned long int',
                  '__gwchar_t=int', '____gwchar_t_defined',
    );
}

warn "using $CC with @ccincdir\n" if @ccincdir;
my $c = Convert::Binary::C->new
  ->Include('.', @ccincdir, '/usr/include')
  ->Define(@defines);
my $hdr = "$topdir/include/dwg.h";
$c->parse_file($hdr);

#print Data::Dumper->Dump([$c->struct('_dwg_MLINESTYLE_line')], ['_dwg_MLINESTYLE_line']);
#print Data::Dumper->Dump([$c->struct('_dwg_entity_TEXT')], ['_dwg_entity_TEXT']);
#print Data::Dumper->Dump([$c->struct('struct _dwg_header_variables')], ['Dwg_Header_Variables']);

my (%h, $n, %structs, %unions, %ENT, %DXF, %SIZE, %SUBCLASS, %DWG_TYPE);
local (@entity_names, @object_names, @subclasses, $max_entity_names, $max_object_names);
# todo: harmonize more subclasses
for (sort $c->struct_names) {
  if (/_dwg_entity_([A-Z0-9_]+)/) {
    my $n = $1;
    $structs{$n}++;
    push @entity_names, $n;
  } elsif (/_dwg_object_([A-Z0-9_]+)/) {
    next if $1 eq 'BACKGROUND';
    $structs{$1}++;
    push @object_names, $1;
  } elsif (/^_dwg_header_variables/) {
    ;
  } elsif (/^Dwg_([A-Z0-9]+)/) { # AuxHeader, Header, R2004_Header, SummaryInfo
    my $n = $1;
    $structs{$n}++;
  } elsif (/_dwg_([A-Z0-9_]+)/ && !/_dwg_ODA/) {
    $structs{$_}++;
    push @subclasses, $_;
  } else {
    warn "skip struct $_\n";
  }
}
for (sort $c->union_names) {
  if (/_dwg_([A-Z0-9_]+)/) {
    $structs{$_}++;
    $unions{$_}++;
    push @subclasses, $_;
  } else {
    warn "skip union $_\n";
  }
}
# typedefs as aliases:
push @entity_names, qw(XLINE);                    # RAY
push @entity_names, qw(VERTEX_MESH VERTEX_PFACE); # VERTEX_3D
push @entity_names, qw(REGION BODY);              # 3DSOLID
@entity_names = sort @entity_names;
# get BITCODE_ macro types for each struct field
open my $in, "<", $hdr or die "hdr: $!";
my $f;
while (<$in>) {
  if (!$n) {
    if (/^typedef struct (_dwg_.+) \{/) {
      $n = $1;
    } elsif (/^typedef struct (_dwg_\S+)$/) {
      $n = $1;
    } elsif (/^typedef union (_dwg_\S+)$/) {
      $n = $1;
    } elsif (/^#define (COMMON_\w+)\((\w+)\)/) { # COMMON_TABLE_CONTROL_FIELDS
      # BUG: Convert::Binary::C cannot separate H* from H, both are just Dwg_Object_Ref
      # So we need to parse the defines
      $n = $1;
      $f = $2;
      $h{$n}{reactors} = 'H*'; # has no ;
    } elsif (/^#define (COMMON_\w+)/) { # COMMON_ENTITY_POLYLINE
      $n = $1;
      $h{$n}{seqend}   = 'H' if $n eq 'COMMON_ENTITY_POLYLINE'; # has no ;
    }
  } elsif (/^\}/) { # close the struct
    $n = '';
  } elsif ($n and $_ =~ /^ +BITCODE_([\w\*]+)\s+(\w.*);/) {
    my $type = $1;
    my $v = $2;
    $v =~ s/^_3/3/;
    $type =~ s/\s+$//;
    if ($n eq 'COMMON_TABLE_CONTROL_FIELDS' && $v eq 'entries') {
      $h{$n}{$_} = 'H*'
        for qw(block_headers layers styles linetypes views ucs vports apps
               dimstyles vport_entity_headers);
    }
    $h{$n}{$v} = $type;
  }
}
#$h{Dwg_Bitcode_3BD} = '3BD';
#$h{Dwg_Bitcode_2BD} = '2BD';
#$h{Dwg_Bitcode_3RD} = '3RD';
#$h{Dwg_Bitcode_2RD} = '2RD';
#$ENT{LTYPE}->{strings_area} = 'TF';
close $in;
my @old;

sub embedded_struct {
  my ($pre, $subclass) = @_;
  if ($f =~ /^$pre\.(\w+)$/) {
    $f = $1;
    if ($n ne $subclass) {
      push @old, $n;
      warn "$n pushed";
      $n = $subclass;
    }
  } elsif ($n eq $subclass && $f !~ /\./) {
    $n = pop @old;
    warn "$n popped";
  }
}

# parse a spec for its objects, subclasses and dxf values
sub dxf_in {
  $in = shift;
  my $v = qr /[\w\.\[\]]+/;
  my $vx = qr /[\w\.\[\]>-]+/;
  my $outdef;
  while (<$in>) {
    $f = '';
    s/DXF \{ //;
    if (!$n) {
      if (/^DWG_(ENTITY|OBJECT)\s?\((\w+)\)/) {
        $n = $2;
        $n =~ s/^_3/3/;
        warn $n;
      } elsif (/^\s*SECTION\s?\(HEADER\)/) {
        $n = 'header_variables';
        warn $n;
      } elsif (/^int DWG_FUNC_N\s?\(ACTION,_HATCH(\w+)\)/) {
        $n = 'HATCH';
        warn $n;
      } elsif (/^\#define (COMMON_ENTITY_(?:POLYLINE|DIMENSION|))/) {
        $n = $1;
        warn $n;
      } elsif (/^\#define (\w+)_fields/) {
        $n = $1;
        warn "define $n";
      }
    } elsif (/^\#define (\w+)_fields/) {
      $n = $1;
      warn "define $n";
    # i.e. after #define
    } elsif (/^DWG_(ENTITY|OBJECT)\s?\((\w+)\)/) {
      $n = $2;
      $n =~ s/^_3/3/;
      warn $n;
    } elsif (/^DWG_(ENTITY|OBJECT)_END/) { # close
      $n = '';
      @old = ();
      $outdef = 0;
    } elsif (!$n) {
      ;
    #} elsif ($outdef) {
    #  ;
    #} elsif (/^\s*\#ifdef IS_JSON/) {
    #  $outdef++;
    #} elsif ($outdef && /^\s*\#endif/) {
    #  $outdef = 0;
    # single-line REPEAT
    } elsif (/^\s+REPEAT.*\($v,\s*$v,\s*(\w+)\)/) {
      my $tmp = $1; # subclass?
      if ($tmp =~ /^Dwg_(.*)/) {
        push @old, $n;
        $n = $1; # not _dwg_$1
        warn "$n pushed";
      } else {
        push @old, '';
      }
    } elsif (/^\s+_REPEAT_C?N\s*\($vx,\s*$v,\s*(\w+),/) {
      my $tmp = $1; # subclass?
      if ($tmp =~ /^Dwg_(.*)/) {
        push @old, $n;
        $n = $1;
        warn "$n pushed";
      } else {
        push @old, '';
      }
    # multiline REPEAT
    } elsif (/^\s+REPEAT.*\($v,\s*$v,$/) {
      $_ = <$in>;
      if (/^\s+(\w+)\)/) {
        my $tmp = $1; # subclass?
        if ($tmp =~ /^Dwg_(.*)/) {
          push @old, $n;
          $n = $1;
          warn "$n pushed";
        } else {
          push @old, '';
        }
      }
    # skip END_REPEAT(paths); return DWG_ERR_VALUEOUTOFBOUNDS;
    } elsif (/^\s+END_REPEAT\s*\(($vx)\);?$/) { # close
      my $tmp = pop @old;
      if ($tmp) {
        $n = $tmp;
        warn "$n popped";
      } elsif (!defined $tmp) {
        # mostly due to type being a primitive, not a subclass (like T)
        warn "missing REPEAT block in $n: $1";
      }
    } elsif (/^\s+FIELD_HANDLE\s*\((\w+),\s*\d+,\s*(\d+)\)/) {
      $f = $1;
      $DXF{$n}->{$f} = $2 if $2;
    } elsif (/^\s+VALUE_HANDLE\s*\(.+,\s*(\w+),\s*\d,\s*(\d+)\)/) {
      $f = $1;
      $DXF{$n}->{$f} = $2 if $2;
    } elsif (/^\s+FIELD_TF\s*\((\w+),\s*(\d*),\s*(\d+)\)/) {
      my $type = 'TF';
      $f = $1;
      $DXF{$n}->{$f} = $3 if $3;
      $SIZE{$n}->{$f} = $2;
      $ENT{$n}->{$f} = 'TF';
    } elsif (/^\s+FIELD_(.+?)\s*\(([\w\.]+),\s*(\d+)\)/) {
      my $type = $1;
      $f = $2;
      my $dxf = $3;
      # inlined unions
      $f =~ s/^(?:fmt|sty|name|value)\.//;
      # inlined struct: ctx.
      if ($f =~ /^ctx\.(\w+)$/) {
        $f = $1;
        $n = 'MLEADER_AnnotContext';
      } elsif ($n eq 'MLEADER_AnnotContext' && $f eq 'flags') {
        $n = 'MULTILEADER'; # pop back
      }
      embedded_struct ('body', 'ACTIONBODY');
      embedded_struct ('ldata', 'LinkedData');
      embedded_struct ('tdata', 'LinkedTableData');
      embedded_struct ('fdata', 'FormattedTableData');
      # (scale.x, 41) as is
      $DXF{$n}->{$f} = $dxf if $dxf;
      $ENT{$n}->{$f} = 'TF' if $type eq 'BINARY';
      $ENT{$n}->{$f} = $type if $type =~ /^T/;
      $ENT{$n}->{$f} = $type if $type =~ /^[23][RB]D_1/;
    } elsif (@old && /^\s+SUB_FIELD_HANDLE\s*\($v,\s*(\w+),\s*\d+,\s*(\d+)\)/) {
      my $type = $1;
      $f = $1;
      $DXF{$n}->{$f} = $2 if $2;
    } elsif (@old && /^\s+SUB_FIELD_(.+?)\s*\($v,\s*(\w+),\s*(\d+)\)/) {
      my $type = $1;
      $f = $2;
      $DXF{$n}->{$f} = $3 if $3;
    } elsif (/^\s+FIELD_(?:CMC|ENC)\s*\((\w+),\s*(\d+),\s*(\d+)\)/) {
      $f = $1;
      $DXF{$n}->{$f} = $2 if $2;
      if ($3) {
        $DXF{$n}->{"$f.index"} = $2;
        $DXF{$n}->{"$f.rbg"} = $3;
        $DXF{$n}->{"$f.book"} = $3 + 10;
        $DXF{$n}->{"$f.alpha"} = $3 + 20;
      }
    } elsif (/^\s+FIELD_(.+?)\s*\((\w+),.*,\s*(\d+)\)/) {
      my $type = $1;
      $f = $2;
      $DXF{$n}->{$f} = $3 if $3;
      $ENT{$n}->{$f} = 'TF' if $type eq 'BINARY';
      $ENT{$n}->{$f} = $type if $type =~ /^T/;
      $ENT{$n}->{$f} = $type if $type =~ /^[23][RB]D_1/;
    } elsif (@old && /^\s+SUB_FIELD_(.+?)\s*\(\w+,\s*(\w+),.*,\s*(\d+)\)/) {
      my $type = $1;
      $f = $2;
      $DXF{$n}->{$f} = $3 if $3;
      $ENT{$n}->{$f} = 'TF' if $type eq 'BINARY';
      $ENT{$n}->{$f} = $type if $type =~ /^T/;
      $ENT{$n}->{$f} = $type if $type =~ /^[23][RB]D_1/;
    } elsif (/^\s+HANDLE_VECTOR(?:_N)?\s*\((\w+),.*?,\s*(\d+)\)/) {
      $f = $1;
      $DXF{$n}->{$f} = $2 if $2;
    } elsif (/^\s+SUB_HANDLE_VECTOR\s*\([^,]+?, (\w+), .+?, (\d+)\)/) {
      $f = $1;
      $DXF{$n}->{$f} = $2 if $2;
    } elsif (/^\s+HEADER_.+\s*\((\w+),\s*(\d+)\)/) { # HEADER_RC
      $f = $1;
      $DXF{$n}->{$f} = $2 if $2;
    } elsif (/^\s+HEADER_.+\s*\((\w+),\s*(\d+),\s*\w+\)/) {
      $f = $1;
      $DXF{$n}->{$f} = $2 if $2;
    } elsif (/^\s+HEADER_.+\s*\((\w+),\s*\w+,\s*(\d+),\s*\D.+\)/) {
      $f = $1;
      #$f =~ s/^_3/3/;
      $DXF{$n}->{$f} = $2 if $2;
    } elsif (/^\s+HEADER_([23])D\s*\((\w+)\)/) {
      $f = $2;
      $DXF{$n}->{$f} = $1 eq '2' ? 20 : 30;
    } elsif (/^\s+VALUE_(.+)\s*\((\w.+),.*,\s*(\d+)\)/) {
      my $type = $1;
      $f = $2;
      $DXF{$n}->{$f} = $3 if $3;
      $ENT{$n}->{$f} = $type if $type =~ /^T/;
    }
    if ($f and $n and exists $DXF{$n}->{$f}) {
      warn "  $f $DXF{$n}->{$f}\n";
    }
  }
}

# get dxf group for each struct field
sub dxfin_spec {
  my $fn = shift;
  open my $in, "<", $fn  or die "$fn: $!";
  dxf_in ($in);
  close $in;
}
dxfin_spec "$srcdir/dwg.spec";
$DXF{'BLOCK'}->{'name'} = 2; # and 3
$DXF{'INSERT'}->{'block_header'} = 2;
$DXF{'MINSERT'}->{'block_header'} = 2;
$DXF{'HATCH'}->{'boundary_handles'} = 330; # special DXF logic
$DXF{'VISUALSTYLE'}->{'edge_hide_precision_flag'} = 290;
$DXF{'VISUALSTYLE'}->{'is_internal_use_only'} = 291;
$DXF{'DIMSTYLE_CONTROL'}->{'morehandles'} = 340;
# $DXF{'DIMSTYLE'}->{'DIMFIT'} = 287;   # <= r14 only
$DXF{'PROXY_ENTITY'}->{'version'} = 95; # or 91 <= r14
$DXF{'DIMASSOC'}->{'intsect_gsmarker'} = 92;
$DXF{'DIMSTYLE'}->{'flag'} = 70;
# $DXF{'DIMENSION_ORDINATE'}->{'def_pt'} = 10;
# $DXF{'DIMENSION_ORDINATE'}->{'feature_location_pt'} = 13;
# $DXF{'DIMENSION_ORDINATE'}->{'leader_endpt'} = 14;
# $DXF{'DIMENSION_ORDINATE'}->{'flag2'} = 70;
# $DXF{'DIMENSION_ORDINATE'}->{'dimstyle'} = 3;
# $DXF{'DIMENSION_ORDINATE'}->{'block'} = 2;
$DXF{$_}->{'class_version'} = 280 for qw(ATTRIB ATTDEF); #r2010 only
$DXF{$_}->{'has_attribs'} = 66 for qw(INSERT MINSERT);
#$DXF{$_}->{'has_vertex'} = 66 for qw (POLYLINE_2D POLYLINE_3D POLYLINE_PFACE);
$DXF{$_}->{'flag'} = 70 for qw(VERTEX_3D VERTEX_MESH VERTEX_PFACE_FACE POLYLINE_PFACE);
my @solids = qw(3DSOLID REGSION BODY
                EXTRUDEDSURFACE LOFTEDSURFACE REVOLVEDSURFACE SWEPTSURFACE PLANESURFACE);
$DXF{$_}->{'version'} = 70 for @solids;
$DXF{$_}->{'encr_sat_data'} = 1 for @solids;
$DXF{$_}->{'history_id'} = 350 for @solids;
my @annotscale = qw (TEXTOBJECTCONTEXTDATA MTEXTOBJECTCONTEXTDATA ALDIMOBJECTCONTEXTDATA
                     MTEXTATTRIBUTEOBJECTCONTEXTDATA MLEADEROBJECTCONTEXTDATA LEADEROBJECTCONTEXTDATA
                     BLKREFOBJECTCONTEXTDATA);
$DXF{$_}->{'class_version'} = 70 for @annotscale;
$DXF{$_}->{'is_default'} = 290 for @annotscale;
$DXF{$_}->{'scale'} = 340 for @annotscale;

dxfin_spec "$srcdir/header_variables_dxf.spec";
$DXF{header_variables}->{'_3DDWFPREC'} = 40;

$n = 'object_entity';
dxfin_spec "$srcdir/common_entity_data.spec";
dxfin_spec "$srcdir/common_entity_handle_data.spec";
$DXF{$n}->{'color'} = $DXF{$n}->{'color_r11'} = 62;
$DXF{$n}->{'color.rgb'} = 420; # handle 420?
$DXF{$n}->{'color.book'} = 430;
$DXF{$n}->{'color.alpha'} = 440;
$DXF{$n}->{'paper_r11'} = 67;
$DXF{$n}->{'plotstyle'} = 390;
$DXF{$n}->{'ownerhandle'} = 330;
$DXF{$n}->{'xdicobjhandle'} = 360;
$DXF{$n}->{'reactors'} = 330;
$DXF{$n}->{'preview_size'} = 160; # or 92

$n = 'object_object';
#dxfin_spec "$srcdir/common_object_handle_data.spec";
$DXF{$n}->{'ownerhandle'} = 330;
$DXF{$n}->{'xdicobjhandle'} = 360;
$DXF{$n}->{'reactors'} = 330;

$n = 'SummaryInfo';
dxfin_spec "$srcdir/summaryinfo.spec";

# dxfclassname for each of our classes and subclasses (not complete)
# Our NAME => 100
%SUBCLASS = (
  '3DSOLID' => "AcDbModelerGeometry",
  DIMENSION_ALIGNED => "AcDbAlignedDimension",
  DIMENSION_ORDINATE => "AcDbOrdinateDimension",
  DIMENSION_ORDINATE => "AcDb2LineAngularDimension",
  ARC_DIMENSION => "AcDbArcDimension",
  LWPOLYLINE => "AcDbPolyline",
  POLYLINE_3D => "AcDb3dPolyline",
  #VERTEX => "AcDbVertex",
  VERTEX_3D => "AcDb3dPolylineVertex",
  HATCH => "AcDbHatch",
  '3DFACE' => "AcDbFace",
  DICTIONARYVAR => "DictionaryVariables",

  "3DSOLID_silhouette" => "",
  "3DSOLID_wire" => "",
  "ACTIONBODY" => "AcDbAssocActionBody",
  # AcDbAssocParamBasedActionBody?
  # ASSOCDEPENDENCY AcDbAssocDependency
  # ASSOCGEOMDEPENDENCY AcDbAssocDependency
  # ASSOCGEOMDEPENDENCY AcDbAssocGeomDependency
  # ASSOCOSNAPPOINTREFACTIONPARAM => AcDbAssocActionParam,
  # ASSOCOSNAPPOINTREFACTIONPARAM => AcDbAssocCompoundActionParam,
  # ASSOCVERTEXACTIONPARAM => AcDbAssocActionParam,
  # ASSOCVERTEXACTIONPARAM => AcDbAssocSingleDependencyActionParam,
  # ASSOCVERTEXACTIONPARAM => AcDbAssocVertexActionParam,
  "CELLSTYLEMAP_Cell" => "",
  "DIMASSOC_Ref" => "",
  "DIMENSION_common" => "AcDbDimension",
  "EVAL_Node" => "",
  "FIELD_ChildValue" => "",
  "GEODATA_meshface" => "",
  "GEODATA_meshpt" => "",
  "HATCH_DefLine" => "",
  "HATCH_color" => "",
  "HATCH_control_point" => "",
  "HATCH_path" => "",
  "HATCH_pathseg" => "",
  "HATCH_polylinepath" => "",
  "LEADER_ArrowHead" => "",
  "LEADER_BlockLabel" => "",
  "LEADER_Break" => "",
  "LEADER_Line" => "",
  "LEADER_Node" => "",
  "LTYPE_dash" => "",
  "LWPOLYLINE_width" => "",
  "MLEADER_Content" => "",
  "MLEADER_AnnotContext" => "AcDbObjectContextData",
  "MLINESTYLE_line" => "",
  "MLINE_line" => "",
  "MLINE_vertex" => "",
  "SPLINE_control_point" => "",
  "SPLINE_point" => "",
  "SUNSTUDY_Dates" => "",
  "TABLEGEOMETRY_Cell" => "",
  "TABLESTYLE_Cell" => "",
  "TABLE_BreakHeight" => "",
  "TABLE_BreakRow" => "",
  "TABLE_CustomDataItem" => "",
  "TABLE_cell" => "",
  "TABLE_value" => "",

  # TABLECONTENT => AcDbLinkedData
  # TABLECONTENT => AcDbLinkedTableData
  # TABLECONTENT => AcDbFormattedTableData
  "TABLECONTENT" => "AcDbTableContent",
  "TABLEGEOMETRY" => "AcDbTableGeometry",
  "DATATABLE" => "ACDBDATATABLE",
  # VIEWSTYLE_ModelDoc => "AcDbModelDocViewStyle",
  DETAILVIEWSTYLE => "AcDbDetailViewStyle",
  SECTIONVIEWSTYLE => "AcDbSectionViewStyle",
  ASSOCGEOMDEPENDENCY => "AcDbAssocDependency",
  ASSOCOSNAPPOINTREFACTIONPARAM => "ACDBASSOCOSNAPPOINTREFACTIONPARAM",
  ASSOCALIGNEDDIMACTIONBODY => "ACDBASSOCALIGNEDDIMACTIONBODY",
  ASSOCOSNAPPOINTREFACTIONPARAM => "ACDBASSOCOSNAPPOINTREFACTIONPARAM",
  # ACSH_HISTORY_CLASS => AcDbShHistory
  # ACSH_HISTORY_CLASS_Node => AcDbShHistoryNode
  );

# 300 CONTEXT_DATA{
# unused
my %SUBGROUP = (
  MLEADER_AnnotContext => "CONTEXT_DATA{",
  LEADER  => "LEADER{",
  LEADER_Line => "LEADER_LINE{",
  );

# DXFNAME 0 => our name
my %DXFALIAS = # see also CLASS.dxfname
  (
  ACDBDETAILVIEWSTYLE => "DETAILVIEWSTYLE",
  ACDBSECTIONVIEWSTYLE => "SECTIONVIEWSTYLE",
  ACDBPLACEHOLDER => "PLACEHOLDER",
  ACDBASSOCACTION => "ASSOCACTION",
  ACDBASSOCALIGNEDDIMACTIONBODY => "ASSOCALIGNEDDIMACTIONBODY",
  ACDBASSOCGEOMDEPENDENCY => "ASSOCGEOMDEPENDENCY",
  ACDBASSOCOSNAPPOINTREFACTIONPARAM => "ASSOCOSNAPPOINTREFACTIONPARAM",
  ACDBASSOCALIGNEDDIMACTIONBODY => "ASSOCALIGNEDDIMACTIONBODY",
  ACDBDATATABLE => "DATATABLE",
  );

my $cfile = "$srcdir/dynapi.c";
chmod 0644, $cfile if -e $cfile;
open my $fh, ">", $cfile or die "$cfile: $!";

# generate docs (GH #127)
my $docfile = "$topdir/doc/dynapi.texi";
chmod 0644, $docfile if -e $docfile;
open my $doc, ">", $docfile or die "$docfile: $!";
print $doc <<'EOF';
@c This file is automatically generated by src/gen-dynapi.pl. Do not modify here.
@c It is intended to be included within the main document.

EOF

sub is_table {
  return shift =~ /^(?:BLOCK_HEADER|LAYER|STYLE|LTYPE|VIEW|UCS|
                     VPORT|APPID|DIMSTYLE|VPORT_ENTITY_HEADER)$/x;
}

sub is_table_control {
  return shift =~ /^(?:BLOCK|LAYER|STYLE|LTYPE|VIEW|UCS|
                     VPORT|APPID|DIMSTYLE|VPORT_ENTITY)_CONTROL$/x;
}

sub out_declarator {
  my ($d,$tmpl,$key,$prefix) = @_;
  my $n = "_dwg_$key" unless $key =~ /^_dwg_/;
  my $ns = $tmpl;
  $ns =~ s/^struct //;
  my $type = $d->{type};
  my $decl = $d->{declarators}->[0];
  my $name = $decl->{declarator};
  while ($name =~ /^\*/) {
    $name =~ s/^\*//;
    $type .= '*';
  }
  if ($prefix) { # optional, for unions only
    $name = $prefix . "." . $name;
  }
  # unexpand BITCODE_ macros: e.g. unsigned int -> BITCODE_BL
  my $bc = exists $h{$ns} ? $h{$ns}{$name} : undef;
  if (!$bc && $ns =~ /_CONTROL$/) {
    $bc = $h{COMMON_TABLE_CONTROL_FIELDS}{$name};
  } elsif (!$bc && $ns =~ /_entity_POLYLINE_/) {
    $bc = $h{COMMON_ENTITY_POLYLINE}{$name};
  }
  $type = $bc if $bc;
  if ($name eq 'encr_sat_data') {
    $type = 'char **'; $bc = '';
  }
  $type =~ s/\s+$//;
  my $size = $bc ? "sizeof (BITCODE_$type)" : "sizeof ($type)";
  $type =~ s/BITCODE_//;
  # TODO: DIMENSION_COMMON, _3DSOLID_FIELDS macros
  if ($type eq 'unsigned char') {
    $type = 'RC';
  } elsif ($type eq 'unsigned char*') {
    $type = 'RC*';
  } elsif ($type eq 'double') {
    $type = 'BD';
  } elsif ($type eq 'double*') {
    $type = 'BD*';
  } elsif ($type =~ /^Dwg_Bitcode_(\w+)/) {
    $type = $1;
  } elsif ($type eq 'char*') {
    $type = 'TV';
  } elsif ($type eq 'unsigned short int') {
    $type = 'BS';
  } elsif ($type eq 'uint16_t') {
    $type = 'BS';
  } elsif ($type eq 'unsigned int') {
    $type = 'BL';
  } elsif ($type eq 'unsigned int*') {
    $type = 'BL*';
  } elsif ($type eq 'uint32_t') {
    $type = 'BL';
  } elsif ($type eq 'uint32_t*') {
    $type = 'BL*';
  } elsif ($type eq 'Dwg_Object_Ref*') {
    $type = 'H';
  } elsif ($type eq 'Dwg_Object_Ref**') {
    $type = 'H*';
  } elsif ($type =~ /\b(unsigned|char|int|long|double)\b/) {
    warn "unexpanded $type $n.$name\n";
  } elsif ($type =~ /^struct/) {
    if ($type =~ /\*$/) {
      $size = "sizeof (void *)";
    } else {
      # e.g. MLEADER_Content.txt.
      warn "inline struct $key.$name\n";
      for (@{$c->struct($d->{type})->{declarations}}) {
        out_declarator ($_, $tmpl, $key, $name);
      }
      #next;
    }
  } elsif ($type =~ /^union/) {
    warn "inline union $key.$name\n";
    for (@{$c->union($d->{type})->{declarations}}) {
      out_declarator ($_, $tmpl, $key, $name);
    }
    #next;
  } elsif ($type =~ /^HASH\(/) { # inlined struct or union
    if ($type->{type} eq 'union' && $n !~ /^_dwg_object_/) {
      # take all declarators and add the "$name." prefix
      warn "note: union field $n.$name\n";
      for (@{$type->{declarations}}) {
        out_declarator ($_, $tmpl, $key, $name);
      }
      next;
    } else {
      warn "ignore inlined field $n.$name\n";
      next;
    }
  }
  if ($ENT{$key}->{$name}) {
    $type = $ENT{$key}->{$name};
  } else {
    $ENT{$key}->{$name} = $type;
  }
  my $is_malloc = ($type =~ /\*$/ or $type =~ /^(T$|T[UVF])/) ? 1 : 0;
  my $is_indirect = ($is_malloc or $type =~ /^(struct|[23T]|CMC|H$)/) ? 1 : 0;
  my $is_string = ($is_malloc and $type =~ /^T[UV]?$/) ? 1 : 0; # not TF or TFF
  my $sname = $name;
  if ($name =~ /\[(\d+)\]$/) {
    $is_malloc = 0;
    $size = "$1 * $size";
    $sname =~ s/\[(\d+)\]$//;
  }
  if ($type =~ /^TF/ && exists $SIZE{$key}->{$name}) {
    $size = $SIZE{$key}->{$name};
  }
  my $dxf = $DXF{$key}->{$name};
  if (!$dxf && $key =~ /DIMENSION/) {
    $dxf = $DXF{COMMON_ENTITY_DIMENSION}->{$name};
  }
  if (!$dxf && $key =~ /ASSOC/) {
    $dxf = $DXF{ASSOCACTION}->{$name};
  }
  $dxf = 0 unless $dxf;
  warn "no dxf for $key: $name 0\n" unless $dxf or
    ($name eq 'parent') or
    ($key eq 'header_variables' and $name eq lc($name));

  printf $fh "  { \"%s\",\t\"%s\", %s,  OFF (%s, %s),\n    %d,%d,%d, %d },\n",
    $name, $type, $size, $tmpl, $sname, $is_indirect, $is_malloc, $is_string, $dxf;

  print $doc "\@item $name\n$type", $dxf ? ",\tDXF $dxf" : "", "\n";
}

sub out_struct {
  my ($tmpl, $n) = @_;
  #print $fh " /* ", Data::Dumper->Dump([$s], [$n]), "*/\n";
  my $key = $n;
  $n = "_dwg_$n" unless $n =~ /^_dwg_/;
  my $sortedby = 'offset';
  my $s = $c->struct($tmpl);
  unless ($s) {
    $s = $c->union($tmpl);
  }
  unless ($s->{declarations}) {
    delete $ENT{$n};   # don't show up in dynapi_test.c
    return;
  }
  my @declarations = @{$s->{declarations}};
  if ($n =~ /^_dwg_(header_variables|object_object|object_entity|SummaryInfo)$/) {
    @declarations = sort {
      my $aname = $a->{declarators}->[0]->{declarator};
      my $bname = $b->{declarators}->[0]->{declarator};
      $aname =~ s/^\*//g;
      $bname =~ s/^\*//g;
      return $aname cmp $bname
    } @declarations;
    $sortedby = 'name';
  }
  if ($tmpl =~ /_dwg_object_/) {
    if (is_table($key)) {
      print $doc "\@cindex table, $key\n\n";
      print $doc "$key is a table object.\n\n";
    }
    elsif (is_table_control($key)) {
      print $doc "\@cindex table_control, $key\n\n";
      print $doc "$key is a table_control object.\n\n";
    }
  }
  print $doc "\@indentedblock\n";
  print $doc "\@vtable \@code\n\n";
  print $fh "/* from typedef $tmpl: (sorted by $sortedby) */\n",
    "static const Dwg_DYNAPI_field $n","_fields[] = {\n";
  for my $d (@declarations) {
    out_declarator($d, $tmpl, $key);
  }
  print $fh "  {NULL,\tNULL,\t0,\t0,\t0,0,0, 0},\n";
  print $fh "};\n";
  print $doc "\n\@end vtable\n";
  print $doc "\@end indentedblock\n\n";
}

sub maxlen {
  my $maxlen = 0;
  for (@_) {
    $maxlen = length($_) if $maxlen < length($_);
  }
  $maxlen
}
$max_entity_names = 1+maxlen(@entity_names);
$max_object_names = 1+maxlen(@object_names);

for (<DATA>) {
  # expand enum or struct
  if (/^(.*)\@\@(\w+ \w+)\@\@(.*)/) {
    my ($pre, $post) = ($1, $3);
    my $tmpl = $2;
    print $fh $pre;
    if ($tmpl =~ /^enum (\w+)/) {
      my $s = $c->enum($tmpl);
      #print $fh "\n/* ";
      #print $fh Data::Dumper->Dump([$s], [$1]);
      #print $fh "\n*/";
      my $i = 0;
      my @keys = map { s/^DWG_TYPE__3D/DWG_TYPE_3D/; $_ } keys %{$s->{enumerators}};
      for (sort @keys) {
        my ($k,$v) = ($_, $s->{enumerators}->{$_});
        if ($tmpl eq 'enum DWG_OBJECT_TYPE') {
          $k =~ s/^DWG_TYPE_//;
          # Let the type rather be symbolic: DWG_TYPE_SOLID, not int
          my $vs = $_;
          if (!$v && $k =~ /^3D/) {
            $v = $s->{enumerators}->{'DWG_TYPE__'.$k};
            $vs = 'DWG_TYPE__'.$k;
          }
          my $size = "sizeof (Dwg_$k)";
          if ($c->struct("_dwg_entity_$k")) {
            $size = "sizeof (struct _dwg_entity_$k)";
          } elsif ($c->struct("_dwg_object_$k")) {
            $size = "sizeof (struct _dwg_object_$k)";
          } else {
            $size = "0";
          }
          # see if the fields do exist:
          my $fields = exists $structs{$k} ? "_dwg_".$k."_fields" : "NULL";
          if ($k =~ /^(BODY|REGION)$/) {
            $fields = "_dwg_3DSOLID_fields";
            $size = "sizeof (struct _dwg_entity_3DSOLID)";
          } elsif ($k eq 'XLINE') {
            $fields = "_dwg_RAY_fields";
            $size = "sizeof (struct _dwg_entity_RAY)";
          } elsif ($k =~ /^VERTEX_(MESH|PFACE)$/) {
            $fields = "_dwg_VERTEX_3D_fields";
            $size = "sizeof (struct _dwg_entity_VERTEX_3D)";
          } elsif ($k =~ /^PROXY_LWPOLYLINE$/) {
            $size = "sizeof (struct _dwg_entity_PROXY_LWPOLYLINE)";
          }
          $DWG_TYPE{$k} = $vs;
          printf $fh "  { \"%s\", %s /*(%d)*/, %s, %s },\t/* %d */\n",
            $k, $vs, $v, $fields, $size, $i++;
        } else {
          printf $fh "  { \"%s\", %d },\t/* %d */\n",
            $k, $v, $i++;
        }
      }
    } elsif ($tmpl =~ /^list (\w+)/) {
      no strict 'refs';
      my $n = $1;
      my $i = 0;
      my $maxlen = 0;
      for (@{$n}) {
        $maxlen = length($_) if $maxlen < length($_);
      }
      if ($n eq 'subclasses') {
        for (sort @{$n}) {
          if (/^_dwg_(.*)/) {
            my $n = $1;
            # find class type for this subclass. DWG_TYPE_parent if unique, or -1
            my $type = 0;
            for my $o (keys %DWG_TYPE) {
              my $match = qr '^' . $o . '_\w+';
              if ($n =~ $match) {
                if ($type) {
                  $type = '-1'; # multiple
                } else {
                  $type = '(int)'.$DWG_TYPE{$o};
                }
              }
            }
            my $size = "sizeof (Dwg_$n)";
            if ($c->union("$_")) {
              $size = "sizeof (Dwg_$n)";
            }
            my $subclass = $SUBCLASS{$n};
            if ($subclass) {
              $subclass = '"' . $subclass . '"';
            } else {
              $subclass = "NULL";
            }
            printf $fh "  { \"%s\", %s, %s, %s, %s },\t/* %d */\n",
              $n, $type, $subclass, $_ . "_fields", $size, $i++;
          }
        }
      } else {
        for (@{$n}) {
          my $len = length($_);
          printf $fh "  \"%s\" \"%s\",\t/* %d */\n", $_, "\\0" x ($maxlen-$len), $i++;
        }
      }
    } elsif ($tmpl =~ /^scalar (\w+)/) {
      no strict 'refs';
      my $n = $1;
      printf $fh ${$n};
    } elsif ($tmpl =~ /^for dwg_entity_ENTITY/) {
      print $doc "\n\@node ENTITIES\n\@section ENTITIES\n\@cindex ENTITIES\n\n";
      print $doc "All graphical objects with its fields. \@xref{Common Entity fields}\n\n";
      for (@entity_names) {
        print $doc "\@strong{$_} \@anchor{$_}\n\@cindex entity, $_\n",
          "\@vindex $_\n\n" unless $_ eq 'DIMENSION_';
        out_struct("struct _dwg_entity_$_", $_);
      }
    } elsif ($tmpl =~ /^for dwg_object_OBJECT/) {
      print $doc "\n\@node OBJECTS\n\@section OBJECTS\n\@cindex OBJECTS\n\n";
      print $doc "All non-graphical objects with its fields. \@xref{Common Object fields}\n\n";
      for (@object_names) {
        print $doc "\@strong{$_} \@anchor{$_}\n\@cindex object, $_\n\@vindex $_\n\n";
        out_struct("struct _dwg_object_$_", $_);
      }
    } elsif ($tmpl =~ /^for dwg_subclasses/) {
      for (@subclasses) {
        my ($name) = $_ =~ /^_dwg_(.*)/;
        print $doc "\@strong{Dwg_$name} \@anchor{Dwg_$name}\n\@vindex Dwg_$name\n\n";
        if ($unions{$_}) {
          out_struct("union $_", $name);
        } else {
          out_struct("struct $_", $name);
        }
      }
    } elsif ($tmpl =~ /^struct _dwg_(\w+)/) {
      if ($1 eq 'header_variables') {
        print $doc "\n\@node HEADER\n\@section HEADER\n\@cindex HEADER\n\n";
        print $doc "All header variables.\n\n";
      } elsif ($1 eq 'object_object') {
        print $doc "\@strong{Common Object fields} \@anchor{Common Object fields}\n";
        print $doc "\@cindex Common Object fields\n\n";
      } elsif ($1 eq 'object_entity') {
        print $doc "\@strong{Common Entity fields} \@anchor{Common Entity fields}\n";
        print $doc "\@cindex Common Entity fields\n\n";
      #} elsif ($1 eq 'SummaryInfo') {
      #  print $doc "\n\@node SummaryInfo\n\@section SummaryInfo\n\@cindex SummaryInfo\n\n";
      #  print $doc "All Section SummaryInfo fields.\n\n";
      } else {
        print $doc "\@strong{$1}\n";
        print $doc "\@vindex $1\n\n";
      }
      out_struct($tmpl, $1);
    } elsif ($tmpl =~ /^struct Dwg_(\w+)/) {
      #if ($1 eq 'SummaryInfo') {
      #  print $doc "\n\@node SummaryInfo\n\@section SummaryInfo\n\@cindex SummaryInfo\n\n";
      #  print $doc "All Section SummaryInfo fields.\n\n";
      #} else
      {
        print $doc "\@strong{$1}\n";
        print $doc "\@vindex $1\n\n";
      }
      out_struct($tmpl, $1);
    }
    print $fh $post,"\n";
  } else {
    print $fh $_;
  }
}
chmod 0444, $fh;
close $fh;
chmod 0444, $doc;
close $doc;

# TODO: use dwg.h formats
my %FMT = (
    'double' => '%g',
    'unsigned char' => '%c',
    'unsigned int' => '%u',
    'unsigned long' => '%lu',
    'unsigned short int' => '%hu',
    'short' => '%hd',
    'long' => '%l',
    'char**' => '%p',
    'TV' => '%s',
    'T'  => '%s',
    'TU' => '%ls',
    'TFF' => '%s',
    'BD' => '%g',
    'BL' => '%u',
    'BS' => '%hu',
    'RD' => '%g',
    'RL' => '%u',
    'RS' => '%hu',
    'RC' => '%u',
    'RC*' => '%s',
    );

my $objfile = "$srcdir/objects.inc";
chmod 0644, $objfile if -e $objfile;
open my $inc, ">", $objfile or die "$objfile: $!";
print $inc <<"EOF";
/* ex: set ro ft=c: -*- mode: c; buffer-read-only: t -*- */
/*****************************************************************************/
/*  LibreDWG - free implementation of the DWG file format                    */
/*                                                                           */
/*  Copyright (C) 2019-2020 Free Software Foundation, Inc.                   */
/*                                                                           */
/*  This library is free software, licensed under the terms of the GNU       */
/*  General Public License as published by the Free Software Foundation,     */
/*  either version 3 of the License, or (at your option) any later version.  */
/*  You should have received a copy of the GNU General Public License        */
/*  along with this program.  If not, see <http://www.gnu.org/licenses/>.    */
/*****************************************************************************/

/*
 * objects.inc: define all object and entities
 * written by Reini Urban
 * generated by src/gen-dynapi.pl from include/dwg.h, do not modify.
 */

EOF

for my $name (@entity_names) {
  my $xname = $name =~ /^3/ ? "_$name" : $name; # 3DFACE, 3DSOLID
  next if $name eq 'DIMENSION_';
  next if $name eq 'PROXY_LWPOLYLINE';
  print $inc "DWG_ENTITY ($xname)\n";
}
print $inc "\n";
for my $name (@object_names) {
  print $inc "DWG_OBJECT ($name)\n";
}
chmod 0444, $inc;
close $inc;

my $infile = "$topdir/test/unit-testing/dynapi_test.c.in";
open $in, $infile or die "$infile: $!";
$cfile  = "$topdir/test/unit-testing/dynapi_test.c";
chmod 0644, $cfile if -e $cfile;
open $fh, ">", $cfile or die "$cfile: $!";
print $fh "/* ex: set ro ft=c: -*- mode: c; buffer-read-only: t -*- */\n";

for (<$in>) {
  print $fh $_;
  if (m{/\* \@\@for test_HEADER\@@ \*/}) {
    my $s = $c->struct('_dwg_header_variables');
    for my $d (@{$s->{declarations}}) {
      my $type = $d->{type};
      my $decl = $d->{declarators}->[0];
      my $name = $decl->{declarator};
      while ($name =~ /^\*/) {
        $name =~ s/^\*//;
        $type .= '*';
      }
      $type =~ s/ $//g;
      my $xname = $name =~ /^3/ ? "_$name" : $name;
      my $lname = lc $xname;
      my $var = $lname;
      my $sname = $name;
      if (exists $ENT{header_variables}->{$name}) {
        $type = $ENT{header_variables}->{$name};
      }
      $type =~ s/D_1$/D/;
      my $fmt = exists $FMT{$type} ? $FMT{$type} : undef;
      if (!$fmt) {
        if ($type =~ /[ \*]/ or $type eq 'H') {
          $fmt = '%p';
        } else {
          $fmt = "\" FORMAT_$type \"";
        }
      }
      my $is_ptr = ($type =~ /^(struct|Dwg_)/ or
                    $type =~ /^[23HT]/ or
                    $type =~ /\*$/ or
                    $var  =~ /\[\d+\]$/ or
                    $type =~ /^(BE|CMC)/)
        ? 1 : 0;
      if ($var  =~ /\[\d+\]$/) {
        $lname =~ s/\[\d+\]$//g;
        $sname =~ s/\[\d+\]$//g;
      }
      my $stype = $type;
      $type = 'BITCODE_'.$type unless ($type =~ /^(struct|Dwg_)/ or $type =~ /^[a-z]/);
      if (!$is_ptr) {
        print $fh <<"EOF";
  {
    $type $var;
    if (dwg_dynapi_header_value (dwg, "$name", &$var, NULL)
        && $var == dwg->header_vars.$name)
      pass ();
    else
      fail ("HEADER.$name [$stype] $fmt != $fmt", dwg->header_vars.$sname, $var);
EOF
        if ($type =~ /(int|long|short|char ||double|_B\b|_B[BSLD]\b|_R[CSLD])/) {
          print $fh "    $var++;\n";
        }
        print $fh <<"EOF";
    if (dwg_dynapi_header_set_value (dwg, "$name", &$var, 0)
        && $var == dwg->header_vars.$name)
      pass ();
    else
      fail ("HEADER.$name [$stype] set+1 $fmt != $fmt",
            dwg->header_vars.$sname, $var);
EOF
        if ($type =~ /(int|long|short|char ||double|_B\b|_B[BSLD]\b|_R[CSLD])/) {
          print $fh "    $var--;\n";
          print $fh "    dwg_dynapi_header_set_value (dwg, \"$name\", &$var, 0);\n";
        }
        print $fh "\n  }\n";
      } else {
        print $fh <<"EOF";
  {
    $type $var;
    if (dwg_dynapi_header_value (dwg, "$name", &$lname, NULL)
EOF
        if ($type !~ /\*\*/) {
          print $fh <<"EOF";
        && !memcmp (&$lname, &dwg->header_vars.$sname, sizeof (dwg->header_vars.$sname))
EOF
        }
        print $fh <<"EOF";
       )
      pass ();
    else
      fail ("HEADER.$name [$stype]");
  }
EOF
      }
    }
  }
  if (m{/\* \@\@for if_test_OBJECT\@\@ \*/}) {
    for my $name (@entity_names, @object_names) {
      my $xname = $name =~ /^3/ ? "_$name" : $name; # 3DFACE, 3DSOLID
      #next if $name eq 'DIMENSION_';
      next if $name =~ /^(PROXY_LWPOLYLINE|UNKNOWN_)/;
      print $fh "  else" if $name ne '3DFACE'; # the first
      print $fh <<"EOF";
  if (obj->fixedtype == DWG_TYPE_$xname)
    error += test_$xname(obj);
EOF
    }
  }

  if (m{/\* \@\@for test_OBJECT\@\@ \*/}) {
    for my $name (@entity_names, @object_names) {
      #next if $name eq 'DIMENSION_';
      #TABLE is stored as fixedtype UNKNOWN_ENT, so the dynapi test would fail
      next if $name =~ /^(PROXY_LWPOLYLINE|UNKNOWN_)/;
      my $is_ent = grep { $name eq $_ } @entity_names;
      my ($Entity, $lentity) = $is_ent ? ('Entity', 'entity') : ('Object', 'object');
      my $xname = $name =~ /^3/ ? "_$name" : $name;
      my $lname = lc $xname;
      my $struct = "Dwg_$Entity" . "_$xname";
      print $fh <<"EOF";
static int test_$xname (const Dwg_Object *obj)
{
  int error = 0;
  const Dwg_Object_$Entity *restrict obj_obj = obj->tio.$lentity;
  $struct *restrict $lname = obj->tio.$lentity->tio.$xname;
  failed = 0;
EOF

  for my $var (sort keys %{$ENT{$name}}) {
    my $type = $ENT{$name}->{$var};
    # if 0 ignored in .spec
    next if $type eq 'T' and $name eq 'LIGHT' and $var eq 'web_file';
    next if $type eq 'TF' and $name eq 'SUN' and $var eq 'bytes';
    my $fmt = exists $FMT{$type} ? $FMT{$type} : undef;
    if (!$fmt) {
      if ($type =~ /[ \*]/ or $type eq 'H') {
        $fmt = '%p';
      } else {
        $fmt = "\" FORMAT_$type \"";
      }
    }
    my $svar = $var;
    my $is_ptr = ($type =~ /^(struct|Dwg_)/ or
                  $type =~ /^[TH23]/ or
                  $type =~ /\*$/ or
                  $var =~ /\[\d+\]$/ or
                  $type =~ /^(BE|CMC|BLL)$/)
      ? 1 : 0;
    if ($var  =~ /\[\d+\]$/) {
      $svar =~ s/\[\d+\]$//g;
    }
    my $stype = $type;
    $type =~ s/D_1$/D/;
    $type = 'BITCODE_'.$type unless ($type =~ /^(struct|Dwg_)/ or $type =~ /^[a-z]/);
    if (!$is_ptr) {
      # TODO DEBUGGING [BR]D can be nan
      print $fh <<"EOF";
  {
    $type $var;
    if (dwg_dynapi_entity_value ($lname, "$name", "$var", &$svar, NULL)
        && $var == $lname->$svar)
      pass ();
    else
      fail ("$name.$var [$stype] $fmt != $fmt", $lname->$svar, $svar);
EOF
      if ($type =~ /(int|long|short|char|double|_B\b|_B[BSLD]\b|_R[CSLD])/) {
        print $fh "    $svar++;\n";
      }
      print $fh <<"EOF";
    if (dwg_dynapi_entity_set_value ($lname, "$name", "$var", &$svar, 0)
        && $var == $lname->$svar)
      pass ();
    else
      fail ("$name.$var [$stype] set+1 $fmt != $fmt", $lname->$svar, $svar);
EOF
      if ($type =~ /(int|long|short|char ||double|_B\b|_B[BSLD]\b|_R[CSLD])/) {
        print $fh "    $lname->$svar--;";
      }
      print $fh "\n  }\n";
    } elsif ($type =~ /\*$/ and $type !~ /(RC\*|struct _dwg_object_)/
             # no countfield
             and $var !~ /^(ref|block_size|extra_acis_data|objid_object_handles)$/
             # VECTOR_N
             and $var !~ /(_transform|_transmatrix1?|shhn_pts)$/) {
      my %countfield = (
        attrib_handles => 'num_owned',
        attribs => 'num_owned', # XXX TABLE
        vertex => 'num_owned',
        itemhandles => 'numitems',
        entities => 'num_owned',
        #inserts => 'num_inserts',
        #groups => 'num_groups',
        #field_handles => 'num_fields',
        sort_ents => 'num_ents',
        attr_def_id => 'num_attr_defs',
        layer_entries => 'num_entries',
        readdeps  => 'num_deps',
        writedeps => 'num_deps',
        dashes_r11 => 'num_dashes',
        texts => 'numitems',
        encr_sat_data => 'num_blocks',
        );
      my $countfield = exists $countfield{$var} ? $countfield{$var} : "num_$var";
      $countfield = 'num_dashes' if $name eq 'LTYPE' and $var eq 'styles';
      my $count = 1;
      if ($var eq 'encr_sat_data') {
        print $fh <<"EOF";
  {
    $type $var;
    if (dwg_dynapi_entity_value ($lname, "$name", "$var", &$svar, NULL)
        && !memcmp (&$svar, &$lname->$svar, sizeof ($lname->$svar)))
      pass ();
    else
      fail ("$name.$var [$stype]");
  }
EOF
      }
      elsif ($var eq 'reactors' and $type eq 'BITCODE_H*') {
        print $fh <<"EOF";
  {
    $type $var;
    BITCODE_BL count = obj_obj->num_reactors;
    if (dwg_dynapi_entity_value ($lname, "$name", "$var", &$svar, NULL)
        && $svar == $lname->$svar)
      pass ();
    else
      fail ("$name.$var [$stype] * %u $countfield", count);
  }
EOF
      } else {
        print $fh <<"EOF";
  {
    $type $var;
    BITCODE_BL count = 0;
    if (dwg_dynapi_entity_value ($lname, "$name", "$countfield", &count, NULL)
        && dwg_dynapi_entity_value ($lname, "$name", "$var", &$svar, NULL)
EOF
        if ($type eq 'BITCODE_BD') {
          print $fh "        && (isnan ($svar) || $svar == $lname->$svar)";
        }
        elsif ($type !~ /\*\*/) {
          print $fh "        && $svar == $lname->$svar";
        }
        print $fh ")\n";
        print $fh <<"EOF";
      pass ();
    else
      fail ("$name.$var [$stype] * %u $countfield", count);
  }
EOF
      }
    } else { # is_ptr
      my $is_str;
      my $vardecl = $var;
      my $size = "sizeof ($lname->$svar)";
      if (0 and $stype =~ /^TF/) {
        my $_size = $SIZE{$name}->{$var};
        if ($_size && $_size =~ /^\d+$/) {
          $type = 'char';
          $size = $_size;
          $vardecl .= "[$size]";
          if ($var eq 'strings_area') {
            $vardecl .= ";\n    const Dwg_Data* dwg = obj->parent;";
            $vardecl .= "\n    const int size = dwg->header.version >= 2004 ? 512 : 256";
            $size = 'size';
          }
        }
      }
      print $fh <<"EOF";
  {
    $type $vardecl;
    if (dwg_dynapi_entity_value ($lname, "$name", "$var", &$svar, NULL)
EOF
        if ($stype =~ /^(TV|T|TU|RC\*|unsigned char\*|char\*)$/) {
          $is_str = 1;
          print $fh "        && $svar\n";
          print $fh "           ? strEQ ((char *)$svar, (char *)$lname->$svar)\n";
          print $fh "           : !$lname->$svar)\n";
        } elsif (0 and $stype =~ /^TF/ and $size !~ /^sizeof/) {
          print $fh "        && !memcmp ($svar, $lname->$svar, $size))\n";
        } elsif ($type !~ /\*\*/) {
          print $fh "        && !memcmp (&$svar, &$lname->$svar, $size))\n";
        } else {
          print $fh ")\n";
        }
        if ($is_str) {
          print $fh <<"EOF";
      pass ();
    else
      fail ("$name.$var [$stype] '$fmt' <> '$fmt'", $svar, $lname->$svar);
  }
EOF
        } else {
          print $fh <<"EOF";
        pass ();
    else
        fail ("$name.$var [$stype]");
  }
EOF
        }
      }
    }
    print $fh <<"EOF";
  if (failed && (is_class_unstable ("$name") || is_class_debugging ("$name")))
    {
      ok ("%s failed %d tests (TODO unstable)", "$name", failed);
      failed = 0;
    }
  return failed;
}
EOF
    }
  }

  if (m{/\* \@\@for if_test_OBJECT\@\@ \*/}) {
    for my $name (@entity_names, @object_names) {
      my $xname = $name =~ /^3/ ? "_$name" : $name; # 3DFACE, 3DSOLID
      next if $name eq 'DIMENSION_';
      next if $name =~ /^(PROXY_LWPOLYLINE|UNKNOWN_)/;
      print $fh "  else" if $name ne '3DFACE'; # the first
      print $fh <<"EOF";
  if (obj->fixedtype == DWG_TYPE_$xname)
    error += test_$xname (obj);
EOF
    }
  }

  if (m{/\* \@\@for test_SIZES\@\@ \*/}) {
    for my $name (@entity_names) {
      my $xname = $name =~ /^3/ ? "_$name" : $name; # 3DFACE, 3DSOLID
      print $fh <<"EOF";
  size1 = sizeof (Dwg_Entity_$xname);
  size2 = dwg_dynapi_fields_size (\"$name\");
  if (size1 != size2)
    {
      fprintf (stderr, "sizeof(Dwg_Entity_$xname): %d != "
               "dwg_dynapi_fields_size (\\\"$name\\\"): %d\\n", size1, size2);
      error++;
    }
EOF
      if ($name eq 'PROXY_LWPOLYLINE') {
        print $fh <<"EOF";
  if (size1 != size2) // TODO
    error--;
EOF
      }
    }
    for my $name (@object_names) {
      my $xname = $name;
      print $fh <<"EOF";
  size1 = sizeof (struct _dwg_object_$xname);
  size2 = dwg_dynapi_fields_size (\"$name\");
  if (size1 != size2)
    {
      fprintf (stderr, "sizeof(struct _dwg_object_$xname): %d != "
               "dwg_dynapi_fields_size (\\\"$name\\\"): %d\\n", size1, size2);
      error++;
    }
EOF
    }
    for my $name (@subclasses) {
      my $xname = $name;
      my $struct = "struct $name";
      if ($unions{$name}) {
        $struct = "union $name";
      }
      $xname =~ s/^_dwg_//;
      print $fh <<"EOF";
  size1 = sizeof ($struct);
  size2 = dwg_dynapi_fields_size (\"$xname\");
  if (size1 != size2)
    {
      fprintf (stderr, "sizeof($struct): %d != "
               "dwg_dynapi_fields_size (\\\"$xname\\\"): %d\\n", size1, size2);
      error++;
    }
EOF
    }
  }
}
close $in;
chmod 0444, $fh;
close $fh;

# NOTE: in the 2 #line's below use __LINE__ + 1
__DATA__
/* ex: set ro ft=c: -*- mode: c; buffer-read-only: t -*- */
#line 1318 "gen-dynapi.pl"
/*****************************************************************************/
/*  LibreDWG - free implementation of the DWG file format                    */
/*                                                                           */
/*  Copyright (C) 2018-2020 Free Software Foundation, Inc.                   */
/*                                                                           */
/*  This library is free software, licensed under the terms of the GNU       */
/*  General Public License as published by the Free Software Foundation,     */
/*  either version 3 of the License, or (at your option) any later version.  */
/*  You should have received a copy of the GNU General Public License        */
/*  along with this program.  If not, see <http://www.gnu.org/licenses/>.    */
/*****************************************************************************/

/*
 * dynapi.c: dynamic access to all object and field names and types
 * written by Reini Urban
 * generated by src/gen-dynapi.pl from include/dwg.h, do not modify.
 */

#include "config.h"
#include <string.h>
#include <stdlib.h>
#include <assert.h>
#include "common.h"
#include "dynapi.h"
#define DWG_LOGLEVEL loglevel
#include "logging.h"
#include "decode.h"
#include "dwg.h"
#include "bits.h"
  
#ifndef _DWG_API_H_
Dwg_Object *dwg_obj_generic_to_object (const void *restrict obj,
                                       int *restrict error);
#endif

#define MAXLEN_ENTITIES @@scalar max_entity_names@@
#define MAXLEN_OBJECTS @@scalar max_object_names@@

/* sorted for bsearch. from typedef struct _dwg_entity_*: */
static const char dwg_entity_names[][MAXLEN_ENTITIES] = {
@@list entity_names@@
};
/* sorted for bsearch. from typedef struct _dwg_object_*: */
static const char dwg_object_names[][MAXLEN_OBJECTS] = {
@@list object_names@@
};

@@struct _dwg_header_variables@@
@@for dwg_entity_ENTITY@@
@@for dwg_object_OBJECT@@
@@for dwg_subclasses@@

/* common fields: */
@@struct _dwg_object_entity@@
@@struct _dwg_object_object@@

@@struct Dwg_SummaryInfo@@

struct _name_type_fields {
  const char *const name;
  const enum DWG_OBJECT_TYPE type;
  const Dwg_DYNAPI_field *const fields;
  const int size;
};

struct _name_subclass_fields {
  const char *const name;
  const int type;
  const char *const subclass;
  const Dwg_DYNAPI_field *const fields;
  const int size;
};

/* Fields for all the objects, sorted for bsearch. from enum DWG_OBJECT_TYPE: */
static const struct _name_type_fields dwg_name_types[] = {
@@enum DWG_OBJECT_TYPE@@
};

/* Fields for all the subclasses, sorted for bsearch */
static const struct _name_subclass_fields dwg_list_subclasses[] = {
@@list subclasses@@
};

#line 1401 "gen-dynapi.pl"
static int
_name_inl_cmp (const void *restrict key, const void *restrict elem)
{
  //https://en.cppreference.com/w/c/algorithm/bsearch
  return strcmp ((const char *)key, (const char *)elem); //inlined
}

struct _name
{
  const char *const name;
};

static int
_name_struct_cmp (const void *restrict key, const void *restrict elem)
{
  //https://en.cppreference.com/w/c/algorithm/bsearch
  const struct _name *f = (struct _name *)elem;
  return strcmp ((const char *)key, f->name); //deref
}

#define NUM_ENTITIES    ARRAY_SIZE(dwg_entity_names)
#define NUM_OBJECTS     ARRAY_SIZE(dwg_object_names)
#define NUM_NAME_TYPES  ARRAY_SIZE(dwg_name_types)
#define NUM_SUBCLASSES  ARRAY_SIZE(dwg_list_subclasses)

static
const struct _name_type_fields*
 __nonnull ((1))
_find_entity (const char *name)
{
  const char *p = bsearch (name, dwg_name_types, NUM_NAME_TYPES,
                           sizeof (dwg_name_types[0]),
                           _name_struct_cmp);
  if (p)
    {
      const int i = (p - (char *)dwg_name_types) / sizeof (dwg_name_types[0]);
      return &dwg_name_types[i];
    }
  else
    return NULL;
}

static
const struct _name_subclass_fields*
 __nonnull ((1))
_find_subclass (const char *name)
{
  const char *p = bsearch (name, dwg_list_subclasses, NUM_SUBCLASSES,
                           sizeof (dwg_list_subclasses[0]),
                           _name_struct_cmp);
  if (p)
    {
      const int i = (p - (char *)dwg_list_subclasses) / sizeof (dwg_list_subclasses[0]);
      return &dwg_list_subclasses[i];
    }
  else
    return NULL;
}

EXPORT bool
is_dwg_entity (const char *name)
{
  return bsearch (name, dwg_entity_names, NUM_ENTITIES, MAXLEN_ENTITIES,
                  _name_inl_cmp)
             ? true
             : false;
}

EXPORT bool
is_dwg_object (const char *name)
{
  return bsearch (name, dwg_object_names, NUM_OBJECTS, MAXLEN_OBJECTS,
                  _name_inl_cmp)
             ? true
             : false;
}

EXPORT const Dwg_DYNAPI_field *
dwg_dynapi_entity_fields (const char *name)
{
  const struct _name_type_fields *f = _find_entity (name);
  return f ? f->fields : NULL;
}

EXPORT const Dwg_DYNAPI_field *
dwg_dynapi_subclass_fields (const char *restrict name)
{
  const struct _name_subclass_fields *f = _find_subclass (name);
  return f ? f->fields : NULL;
}

EXPORT const Dwg_DYNAPI_field *
dwg_dynapi_common_entity_fields (void)
{
  return _dwg_object_entity_fields;
}

EXPORT const Dwg_DYNAPI_field *
dwg_dynapi_common_object_fields (void)
{
  return _dwg_object_object_fields;
}

EXPORT const Dwg_DYNAPI_field *
dwg_dynapi_entity_field (const char *restrict name, const char *restrict field)
{
  const Dwg_DYNAPI_field *fields = dwg_dynapi_entity_fields (name);
  if (fields)
    { /* linear search (unsorted) */
      Dwg_DYNAPI_field *f = (Dwg_DYNAPI_field *)fields;
      for (; f->name; f++)
        {
          if (strEQ (f->name, field))
            return f;
        }
    }
  return NULL;
}

EXPORT const Dwg_DYNAPI_field *
dwg_dynapi_subclass_field (const char *restrict name, const char *restrict field)
{
  const Dwg_DYNAPI_field *fields = dwg_dynapi_subclass_fields (name);
  if (fields)
    { /* linear search (unsorted) */
      Dwg_DYNAPI_field *f = (Dwg_DYNAPI_field *)fields;
      for (; f->name; f++)
        {
          if (strEQ (f->name, field))
            return f;
        }
    }
  return NULL;
}

EXPORT const Dwg_DYNAPI_field *
dwg_dynapi_header_field (const char *restrict fieldname)
{
  return (Dwg_DYNAPI_field *)bsearch (
              fieldname, _dwg_header_variables_fields,
              ARRAY_SIZE (_dwg_header_variables_fields) - 1, /* NULL terminated */
              sizeof (_dwg_header_variables_fields[0]), _name_struct_cmp);
}

EXPORT const Dwg_DYNAPI_field *
dwg_dynapi_common_entity_field (const char *restrict fieldname)
{
  return (Dwg_DYNAPI_field *)bsearch (
              fieldname, _dwg_object_entity_fields,
              ARRAY_SIZE (_dwg_object_entity_fields) - 1, /* NULL terminated */
              sizeof (_dwg_object_entity_fields[0]), _name_struct_cmp);
}

EXPORT const Dwg_DYNAPI_field *
dwg_dynapi_common_object_field (const char *restrict fieldname)
{
  return (Dwg_DYNAPI_field *)bsearch (
              fieldname, _dwg_object_object_fields,
              ARRAY_SIZE (_dwg_object_object_fields) - 1, /* NULL terminated */
              sizeof (_dwg_object_object_fields[0]), _name_struct_cmp);
}

EXPORT int
dwg_dynapi_entity_size (const char *restrict name)
{
  const struct _name_type_fields *f = _find_entity (name);
  return f ? f->size : 0;
}

EXPORT int
dwg_dynapi_subclass_size (const char *restrict name)
{
  const struct _name_subclass_fields *f = _find_subclass (name);
  return f ? f->size : 0;
}

/* generic field getters */
EXPORT bool
dwg_dynapi_entity_value (void *restrict _obj, const char *restrict name,
                         const char *restrict fieldname,
                         void *restrict out, Dwg_DYNAPI_field *restrict fp)
{
#ifndef HAVE_NONNULL
  if (!_obj || !name || !fieldname || !out)
    return false;
#endif
  {
    int error;
    const Dwg_Object* obj = dwg_obj_generic_to_object (_obj, &error);
    if (obj && strNE (obj->name, name)) // objid may be 0
      {
        const int loglevel = obj->parent->opts & DWG_OPTS_LOGLEVEL;
        LOG_ERROR ("%s: Invalid entity type %s, wanted %s", __FUNCTION__,
                   obj->name, name);
        return false;
      }
    {
      const Dwg_DYNAPI_field *f = dwg_dynapi_entity_field (name, fieldname);
      if (!f)
        {
          int loglevel;
          if (obj)
            loglevel = obj->parent->opts & DWG_OPTS_LOGLEVEL;
          else
            loglevel = DWG_LOGLEVEL_ERROR;
          LOG_ERROR ("%s: Invalid %s field %s", __FUNCTION__, name, fieldname);
          return false;
        }
      if (fp)
        memcpy (fp, f, sizeof (Dwg_DYNAPI_field));
      memcpy (out, &((char *)_obj)[f->offset], f->is_malloc ? sizeof(char*) : f->size);
      return true;
    }
  }
}

EXPORT bool
dwg_dynapi_entity_utf8text (void *restrict _obj, const char *restrict name,
                            const char *restrict fieldname,
                            char **restrict out, int *isnew,
                            Dwg_DYNAPI_field *restrict fp)
{
  if (isnew)
    *isnew = 0;
#ifndef HAVE_NONNULL
  if (!_obj || !name || !fieldname || !out)
    return false;
#endif
  {
    int error;
    const Dwg_Object* obj = dwg_obj_generic_to_object (_obj, &error);
    if (obj && strNE (obj->name, name)) // objid may be 0
      {
        const int loglevel = obj->parent->opts & DWG_OPTS_LOGLEVEL;
        LOG_ERROR ("%s: Invalid entity type %s, wanted %s", __FUNCTION__,
                   obj->name, name);
        return false;
      }
    {
      const Dwg_DYNAPI_field *f = dwg_dynapi_entity_field (name, fieldname);
      const Dwg_Version_Type dwg_version
          = obj ? obj->parent->header.version : R_INVALID;
      if (!f || !f->is_string)
        {
          int loglevel;
          if (obj)
            loglevel = obj->parent->opts & DWG_OPTS_LOGLEVEL;
          else
            loglevel = DWG_LOGLEVEL_ERROR;
          LOG_ERROR ("%s: Invalid %s text field %s", __FUNCTION__, name, fieldname);
          return false;
        }
      if (fp)
        memcpy (fp, f, sizeof (Dwg_DYNAPI_field));

      if (dwg_version >= R_2007 && strNE (f->type, "TF")) /* not TF */
        {
          BITCODE_TU wstr = *(BITCODE_TU*)((char*)_obj + f->offset);
          char *utf8 = bit_convert_TU (wstr);
          if (wstr && !utf8) // some conversion error, invalid wchar (nyi)
            return false;
          *out = utf8;
          if (isnew)
            *isnew = 1;
        }
      else
        {
          char *utf8 = *(char **)((char*)_obj + f->offset);
          *out = utf8;
        }

      return true;
    }
  }
}

EXPORT bool
dwg_dynapi_header_value (const Dwg_Data *restrict dwg,
                         const char *restrict fieldname, void *restrict out,
                         Dwg_DYNAPI_field *restrict fp)
{
#ifndef HAVE_NONNULL
  if (!dwg || !fieldname || !out)
    return false;
#endif
  {
    const Dwg_DYNAPI_field *f = dwg_dynapi_header_field (fieldname);
    if (f)
      {
        const Dwg_Header_Variables *const _obj = &dwg->header_vars;
        if (fp)
          memcpy (fp, f, sizeof (Dwg_DYNAPI_field));
        memcpy (out, &((char*)_obj)[f->offset], f->size);
        return true;
      }
    else
      {
        const int loglevel = dwg->opts & DWG_OPTS_LOGLEVEL;
        LOG_ERROR ("%s: Invalid header field %s", __FUNCTION__, fieldname);
        return false;
      }
  }
}

EXPORT bool
dwg_dynapi_header_utf8text (const Dwg_Data *restrict dwg,
                            const char *restrict fieldname,
                            char **restrict out, int *isnew,
                            Dwg_DYNAPI_field *restrict fp)
{
  if (isnew)
    *isnew = 0;
#ifndef HAVE_NONNULL
  if (!dwg || !fieldname || !out)
    return false;
#endif
  {
    const Dwg_DYNAPI_field *f = dwg_dynapi_header_field (fieldname);
    if (f && f->is_string)
      {
        const Dwg_Header_Variables *const _obj = &dwg->header_vars;
        const Dwg_Version_Type dwg_version = dwg->header.version;
        
        if (fp)
          memcpy (fp, f, sizeof (Dwg_DYNAPI_field));

        if (dwg_version >= R_2007 && strNE (f->type, "TF")) /* not TF */
          {
            BITCODE_TU wstr = *(BITCODE_TU*)((char*)_obj + f->offset);
            char *utf8 = bit_convert_TU (wstr);
            if (wstr && !utf8) // some conversion error, invalid wchar (nyi)
              return false;
            *out = utf8;
            if (isnew)
              *isnew = 1;
          }
        else
          {
            char *utf8 = *(char **)((char*)_obj + f->offset);
            *out = utf8;
          }

        return true;
      }
    else
      {
        const int loglevel = dwg->opts & DWG_OPTS_LOGLEVEL;
        LOG_ERROR ("%s: Invalid header text field %s", __FUNCTION__, fieldname);
        return false;
      }
  }
}

EXPORT bool
dwg_dynapi_common_value(void *restrict _obj, const char *restrict fieldname,
                        void *restrict out, Dwg_DYNAPI_field *restrict fp)
{
#ifndef HAVE_NONNULL
  if (!_obj || !fieldname || !out)
    return false;
#endif
  {
    const Dwg_DYNAPI_field *f;
    int error;
    const Dwg_Object *obj = dwg_obj_generic_to_object (_obj, &error);
    if (!obj)
      {
        const int loglevel = DWG_LOGLEVEL_ERROR;
        LOG_ERROR ("%s: dwg_obj_generic_to_object failed", __FUNCTION__);
        return false;
      }

    if (obj->supertype == DWG_SUPERTYPE_ENTITY)
      {
        f = dwg_dynapi_common_entity_field (fieldname);
        _obj = obj->tio.entity;
      }
    else if (obj->supertype == DWG_SUPERTYPE_OBJECT)
      {
        f = dwg_dynapi_common_object_field (fieldname);
        _obj = obj->tio.object;
      }
    else
      {
        const int loglevel = obj->parent->opts & DWG_OPTS_LOGLEVEL; // DWG_LOGLEVEL_ERROR;
        LOG_ERROR ("%s: Unhandled %s.supertype ", __FUNCTION__, obj->name);
        return false;
      }

    if (f)
      {
        int size = f->size;
        if (fp)
          memcpy (fp, f, sizeof(Dwg_DYNAPI_field));
        if (f->dxf == 160 && strEQc (fieldname, "preview_size")
            && obj->parent->header.version < R_2010)
          size = 4;
        memcpy (out, &((char *)_obj)[f->offset], size);
        return true;
      }
    else
      {
        const int loglevel = obj->parent->opts & DWG_OPTS_LOGLEVEL;
        LOG_ERROR ("%s: Invalid common field %s", __FUNCTION__, fieldname);
        return false;
      }
  }
}

EXPORT bool
dwg_dynapi_common_utf8text(void *restrict _obj, const char *restrict fieldname,
                           char **restrict out, int *isnew, Dwg_DYNAPI_field *restrict fp)
{
  if (isnew)
    *isnew = 0;
#ifndef HAVE_NONNULL
  if (!_obj || !fieldname || !out)
    return false;
#endif
  {
    Dwg_DYNAPI_field *f;
    int error;
    const Dwg_Object *obj = dwg_obj_generic_to_object (_obj, &error);
    Dwg_Data *dwg;

    if (!obj)
      {
        const int loglevel = DWG_LOGLEVEL_ERROR;
        LOG_ERROR ("%s: dwg_obj_generic_to_object failed", __FUNCTION__);
        return false;
      }
    if (obj->supertype == DWG_SUPERTYPE_ENTITY)
      {
        dwg = obj ? obj->parent : ((Dwg_Entity_UNKNOWN_ENT *)_obj)->parent->dwg;
        _obj = obj->tio.entity;
        f = (Dwg_DYNAPI_field *)bsearch (
            fieldname, _dwg_object_entity_fields,
            ARRAY_SIZE (_dwg_object_entity_fields) - 1, /* NULL terminated */
            sizeof (_dwg_object_entity_fields[0]), _name_struct_cmp);
      }
    else if (obj->supertype == DWG_SUPERTYPE_OBJECT)
      {
        dwg = obj ? obj->parent : ((Dwg_Object_UNKNOWN_OBJ *)_obj)->parent->dwg;
        _obj = obj->tio.object;
        f = (Dwg_DYNAPI_field *)bsearch (
            fieldname, _dwg_object_object_fields,
            ARRAY_SIZE (_dwg_object_object_fields) - 1, /* NULL terminated */
            sizeof (_dwg_object_object_fields[0]), _name_struct_cmp);
      }
    else
      {
        const int loglevel = DWG_LOGLEVEL_ERROR;
        LOG_ERROR ("%s: Unhandled %s.supertype ", __FUNCTION__, obj->name);
        return false;
      }

    if (f && f->is_string)
      {
        const Dwg_Version_Type dwg_version = dwg->header.version;

        if (fp)
          memcpy (fp, f, sizeof(Dwg_DYNAPI_field));

        if (dwg_version >= R_2007 && strNE (f->type, "TF")) /* not TF */
          {
            BITCODE_TU wstr = *(BITCODE_TU*)((char*)_obj + f->offset);
            char *utf8 = bit_convert_TU (wstr);
            if (wstr && !utf8) // some conversion error, invalid wchar (nyi)
              return false;
            *out = utf8;
            if (isnew)
              *isnew = 1;
          }
        else
          {
            char *utf8 = *(char **)((char*)_obj + f->offset);
            *out = utf8;
          }

        return true;
      }
    else
      {
        const int loglevel = dwg->opts & DWG_OPTS_LOGLEVEL;
        LOG_ERROR ("%s: Invalid common text field %s", __FUNCTION__, fieldname);
        return false;
      }
  }
}

// create a fresh string
static void
dynapi_set_helper (void *restrict old, const Dwg_DYNAPI_field *restrict f,
                   const Dwg_Version_Type dwg_version,
                   const void *restrict value, const bool is_utf8)
{
  // TODO: sanity checks. is_malloc (TF)
  // if text strcpy or wcscpy, or do utf8 conversion.
  //if ((char*)old && f->is_malloc)
  //  free (old);
  if (f->is_malloc)
    {
      // NULL ptr
      if (!*(char**)value)
        memcpy (old, value, f->size);
      // ascii
      else if (strEQc (f->type, "TF") || (f->is_string && dwg_version < R_2007))
        {
          char *str = malloc (strlen (*(char**)value)+1);
          strcpy (str, *(char**)value);
          memcpy (old, &str, sizeof (char*)); // size of ptr
        }
      // or wide
      else if (strNE (f->type, "TF") && (f->is_string && dwg_version >= R_2007))
        {
          BITCODE_TU wstr;
          if (is_utf8)
            wstr = bit_utf8_to_TU (*(char **)value);
          else // source is already TU
            {
#if defined(HAVE_WCHAR_H) && defined(SIZEOF_WCHAR_T) && SIZEOF_WCHAR_T == 2
              wstr = malloc (2 * (wcslen (*(wchar_t **)value) + 1));
              wcscpy ((wchar_t *)wstr, *(wchar_t **)value);
#else
              int length = 0;
              for (; (*(BITCODE_TU*)value)[length]; length++)
                ;
              length++;
              wstr = malloc (2 * length);
              memcpy (wstr, value, length * 2);
#endif
            }
          memcpy (old, &wstr, sizeof (char*)); // size of ptr
        }
      else
        memcpy (old, value, sizeof (char*));
    }
  // CMC <2004 is color.index only
  else if (strEQc (f->type, "CMC") && dwg_version < R_2004)
    {
      assert (OFF (struct _dwg_color, index) == 0);
      memcpy (old, value, 2);
    }
  else
    memcpy (old, value, f->size);
}

/* generic field setters */
EXPORT bool
dwg_dynapi_entity_set_value (void *restrict _obj, const char *restrict name,
                             const char *restrict fieldname,
                             const void *restrict value, const bool is_utf8)
{
#ifndef HAVE_NONNULL
  if (!_obj || !fieldname || !value) // cannot set NULL value
    return false;
#endif
  {
    int error;
    const Dwg_Object *obj = dwg_obj_generic_to_object (_obj, &error);
    if (obj && strNE (obj->name, name))
      {
        const int loglevel = obj->parent->opts & DWG_OPTS_LOGLEVEL;
        LOG_ERROR ("%s: Invalid entity type %s, wanted %s", __FUNCTION__,
                   obj->name, name);
        return false;
      }
    {
      void *old;
      const Dwg_DYNAPI_field *f = dwg_dynapi_entity_field (name, fieldname);
      const Dwg_Data *dwg
        = obj ? obj->parent
              : ((Dwg_Object_UNKNOWN_OBJ *)_obj)->parent->dwg;
      const Dwg_Version_Type dwg_version = dwg ? dwg->header.version : R_INVALID;

      if (!f)
        {
          const int loglevel = dwg->opts & DWG_OPTS_LOGLEVEL;
          LOG_ERROR ("%s: Invalid %s field %s", __FUNCTION__, name, fieldname);
          return false;
        }

      old = &((char*)_obj)[f->offset];
      dynapi_set_helper (old, f, dwg_version, value, is_utf8);
      return true;
    }
  }
}

EXPORT bool
dwg_dynapi_header_set_value (const Dwg_Data *restrict dwg,
                             const char *restrict fieldname,
                             const void *restrict value, const bool is_utf8)
{
#ifndef HAVE_NONNULL
  if (!dwg || !fieldname || !value) // cannot set NULL value
    return false;
#endif
  {
    Dwg_DYNAPI_field *f = (Dwg_DYNAPI_field *)bsearch (
        fieldname, _dwg_header_variables_fields,
        ARRAY_SIZE (_dwg_header_variables_fields) - 1, /* NULL terminated */
        sizeof (_dwg_header_variables_fields[0]), _name_struct_cmp);
    if (f)
      {
        void *old;
        // there are no malloc'd fields in the HEADER, so no need to free().
        const Dwg_Header_Variables *const _obj = &dwg->header_vars;

        old = &((char*)_obj)[f->offset];
        dynapi_set_helper (old, f, dwg->header.version, value, is_utf8);
        return true;
      }
    else
      {
        const int loglevel = dwg->opts & DWG_OPTS_LOGLEVEL;
        LOG_ERROR ("%s: Invalid header field %s", __FUNCTION__, fieldname);
        return false;
      }
  }
}

EXPORT bool
dwg_dynapi_common_set_value (void *restrict _obj,
                             const char *restrict fieldname,
                             const void *restrict value, const bool is_utf8)
{
#ifndef HAVE_NONNULL
  if (!_obj || !fieldname || !value)
    return false;
#endif
  {
    Dwg_DYNAPI_field *f;
    int error;
    void *old;
    const Dwg_Object *obj = dwg_obj_generic_to_object (_obj, &error);
    Dwg_Data *dwg;
    if (!obj)
      {
        const int loglevel = DWG_LOGLEVEL_ERROR;
        LOG_ERROR ("%s: dwg_obj_generic_to_object failed", __FUNCTION__);
        return false;
      }
    dwg = obj->parent;
    if (obj->supertype == DWG_SUPERTYPE_ENTITY)
      {
        _obj = obj->tio.entity;
        f = (Dwg_DYNAPI_field *)bsearch (
            fieldname, _dwg_object_entity_fields,
            ARRAY_SIZE (_dwg_object_entity_fields) - 1, /* NULL terminated */
            sizeof (_dwg_object_entity_fields[0]), _name_struct_cmp);
      }
    else if (obj->supertype == DWG_SUPERTYPE_OBJECT)
      {
        _obj = obj->tio.object;
        f = (Dwg_DYNAPI_field *)bsearch (
            fieldname, _dwg_object_object_fields,
            ARRAY_SIZE (_dwg_object_object_fields) - 1, /* NULL terminated */
            sizeof (_dwg_object_object_fields[0]), _name_struct_cmp);
      }
    else
      {
        const int loglevel = DWG_LOGLEVEL_ERROR;
        LOG_ERROR ("%s: Unhandled %s.supertype ", __FUNCTION__, obj->name);
        return false;
      }

    if (!f)
      {
        const int loglevel = obj->parent->opts & DWG_OPTS_LOGLEVEL;
        LOG_ERROR ("%s: Invalid %s common field %s", __FUNCTION__, obj->name, fieldname);
        return false;
      }

    old = &((char*)_obj)[f->offset];
    if (f->dxf == 160 && strEQc (fieldname, "preview_size"))
      {
        int size = f->size;
        if (dwg && dwg->header.version < R_2010)
          size = 4;
        memcpy (old, value, size);
      }
    else
      dynapi_set_helper (old, f, dwg ? dwg->header.version : R_INVALID, value, is_utf8);
    return true;
  }
}

// arbitrary structs, no text
EXPORT bool
dwg_dynapi_subclass_value (const void *restrict ptr,
                           const char *restrict subclass,
                           const char *restrict fieldname,
                           void *restrict out, Dwg_DYNAPI_field *restrict fp)
{
  const Dwg_DYNAPI_field *f;
#ifndef HAVE_NONNULL
  if (!ptr || !subclass || !fieldname || !out)
    return false;
#endif
  f = dwg_dynapi_subclass_field (subclass, fieldname);
  if (!f) // TODO maybe search via dwg_dynapi_subclass_name ()
    return false;
  memcpy (out, &((char*)ptr)[f->offset], f->size);
  if (fp)
    memcpy (fp, f, sizeof(Dwg_DYNAPI_field));
  return true;
}

// arbitrary structs, no text
EXPORT bool
dwg_dynapi_field_get_value (const void *restrict ptr,
                            const Dwg_DYNAPI_field *restrict field,
                            void *restrict out)
{
#ifndef HAVE_NONNULL
  if (!ptr || !field || !out)
    return false;
#endif
  memcpy (out, &((char*)ptr)[field->offset], field->size);
  return true;
}

// can do arbitrary structs, like subclasses
EXPORT bool
dwg_dynapi_field_set_value (const Dwg_Data *restrict dwg, /* only needed if unicode strings */
                            void *restrict ptr,
                            const Dwg_DYNAPI_field *restrict field,
                            const void *restrict value,
                            const bool is_utf8)
{
  void *off;
#ifndef HAVE_NONNULL
  if (!ptr || !field || !value)
    return false;
#endif
  off = &((char*)ptr)[field->offset];
  dynapi_set_helper (off, field, dwg ? dwg->header.version : R_INVALID, value, is_utf8);
  return true;
}

// check if the handle points to an object with a name.
// see also dwg_obj_table_get_name, which only supports tables.
EXPORT char*
dwg_dynapi_handle_name (const Dwg_Data *restrict dwg, Dwg_Object_Ref *restrict hdl)
{
  const Dwg_Version_Type dwg_version = dwg->header.version;
  Dwg_Object *obj;

#ifndef HAVE_NONNULL
  if (!dwg || !hdl)
    return NULL;
#endif

  obj = dwg_ref_object_silent (dwg, hdl);
  if (!obj)
    return NULL;
  {
    const Dwg_DYNAPI_field *f = dwg_dynapi_entity_field (obj->name, "name");
    // just some random type is enough.
    Dwg_Object_STYLE *_obj = obj->tio.object->tio.STYLE;

    if (!f || !f->is_string)
      return NULL;
    if (dwg_version >= R_2007 && strNE (f->type, "TF")) /* not TF */
      {
        BITCODE_TU wstr = *(BITCODE_TU *)((char *)_obj + f->offset);
        return bit_convert_TU (wstr);
      }
    else
      {
        return *(char **)((char *)_obj + f->offset);
      }
  }
}

// The sum of the size of all fields
int
_fields_size_sum (const Dwg_DYNAPI_field *restrict fields)
{
  Dwg_DYNAPI_field *f = (Dwg_DYNAPI_field *)fields;
  int sum = 0;
  if (!f)
    return 0;
  for (; f->name; f++)
    {
      sum += f->size;
    }
  return sum;
}

// The size of the entity or subclass struct, or the sum of the size of all fields.
EXPORT int
dwg_dynapi_fields_size (const char *restrict name)
{
  const struct _name_type_fields *f;
#ifndef HAVE_NONNULL
  if (!name)
    return 0;
#endif

  f = _find_entity (name);
  // TODO PROXY_LWPOLYLINE
  if (f)
    {
      if (f->size)
        return (int)f->size;
      else
        return _fields_size_sum (f->fields); // VERTEX_PFACE is not entity nor object yet
    }
  else
    {
      int size = dwg_dynapi_subclass_size (name);
      if (size)
        return size;
      else
        return _fields_size_sum (dwg_dynapi_subclass_fields (name));
    }
}

// Converts from the fields type, like "Dwg_MLINESTYLE_line*" to the
// subclass name, like "MLINESTYLE_line".
ATTRIBUTE_MALLOC char*
dwg_dynapi_subclass_name (const char *restrict type)
{
  char *name = NULL;
  int len = strlen (type);
  if (memBEGINc (type, "Dwg_"))
    {
      name = strdup (&type[4]);
      if (type[len - 1] == '*')
        name[len - 5] = '\0';
    }
  else if (memBEGINc (type, "struct _dwg_entity_"))
    {
      const int off = strlen ("struct _dwg_entity_"); // TABLE
      name = strdup (&type[off]);
      if (type[len - 1] == '*')
        name[len - off - 1] = '\0';
    }
  else if (memBEGINc (type, "struct _dwg_object_"))
    {
      const int off = strlen ("struct _dwg_object_"); // CELLSTYLEMAP*, EVALUATION_GRAPH, ...
      name = strdup (&type[off]);
      if (type[len - 1] == '*')
        name[len - off - 1] = '\0';
    }
  else if (memBEGINc (type, "struct _dwg_")) // CellStyle*
    {
      const int off = strlen ("struct _dwg_");
      name = strdup (&type[off]);
      if (type[len - 1] == '*')
        name[len - off - 1] = '\0';
    }
  return name;
}

/* Local Variables: */
/* mode: c */
/* End: */
