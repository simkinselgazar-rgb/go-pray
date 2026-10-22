use strict; use DynaLoader;
my $lib = shift;
my $h = DynaLoader::dl_load_file($lib, 0) or die "load fail: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($h, "mr_probe") or die "sym fail\n";
my $x = DynaLoader::dl_install_xsub("main::mr_probe", $sym);
&$x();
