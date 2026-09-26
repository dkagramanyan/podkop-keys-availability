#!/bin/bash
# sub-check.sh — show what a subscription URL ("main key") returns to each
# client app, WITHOUT printing secrets (uuids, keys, passwords are never shown,
# server addresses are shown only as "ip"/"domain").
# Works on macOS and Linux (needs curl and perl).
#
#   bash sub-check.sh 'https://sub.example.com/XXXX' ['https://...' ...]

UAS=("Happ/3.9.0" "Streisand/2.3.1" "INCY/1.2.0" "v2RayTun/5.12.0" "v2rayNG/1.10.2" "Hiddify/2.5.7" "sing-box/1.12.0" "curl/8.7.1")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

read -r -d '' PERL <<'PL'
use strict; use warnings; use MIME::Base64; use JSON::PP;
my $mode = shift // 'short'; local $/; my $t = <STDIN> // '';
$t =~ s/^\s+|\s+$//g;
my $max = $mode eq 'full' ? 100 : 3; my @rows; my $fmt;
sub b { my $s = shift // ''; utf8::encode($s) if utf8::is_utf8($s); $s }
sub maskh { my $h = shift // '?'; $h =~ s/^\[|\]$//g;
  return $h if $h =~ /^(0\.0\.0\.0|127\.|localhost$|::1?$)/; return ($h =~ /^[\d.]+$/ || $h =~ /:/) ? 'ip' : 'domain' }
sub out { print "COUNT ", scalar(@rows), "\n  format: $fmt\n"; my $i = 0;
  for (@rows) { last if $i++ >= $max; print "  $_\n" } print "  ... ", @rows - $max, " more\n" if @rows > $max; exit }
if ($t eq '') { $fmt = 'EMPTY answer'; out() }
if ($t !~ m{://} && $t =~ m{^[A-Za-z0-9+/=_\-\s]+$}) {
  (my $x = $t) =~ s/\s//g; $x =~ tr{-_}{+/}; $x .= '=' x ((4 - length($x) % 4) % 4);
  my $d = decode_base64($x); if ($d =~ m{://} || $d =~ /^\s*[\[{]/) { $t = $d; $t =~ s/^\s+|\s+$//g; $fmt = 'base64 of ' } }
$fmt //= '';
if ($t =~ /^\s*</) { my ($ti) = $t =~ m{<title>(.*?)</title>}is; $fmt .= 'HTML web page' . ($ti ? " (title: $ti)" : ''); out() }
if ($t =~ m{happ://crypt}) { $fmt .= 'encrypted happ://crypt links'; out() }
if ($t =~ /^\s*[\[{]/) {
  my $j = eval { JSON::PP->new->decode($t) }; unless ($j) { $fmt .= 'broken JSON'; out() }
  my @c = ref $j eq 'ARRAY' ? @$j : ($j); $fmt .= 'JSON (' . scalar(@c) . ' config(s))';
  for my $c (@c) { next unless ref $c eq 'HASH';
    for my $o (@{ $c->{outbounds} // [] }) { next unless ref $o eq 'HASH';
      my $p = $o->{protocol} // $o->{type} // '?'; next if $p =~ /^(freedom|blackhole|dns|direct|block|selector|urltest|loopback)$/;
      my $ad = $o->{server} // eval { $o->{settings}{vnext}[0]{address} } // eval { $o->{settings}{servers}[0]{address} };
      my $net = eval { $o->{streamSettings}{network} } // eval { $o->{transport}{type} } // 'tcp';
      my $sec = eval { $o->{streamSettings}{security} } // (eval { $o->{tls}{reality}{enabled} } ? 'reality' : eval { $o->{tls}{enabled} } ? 'tls' : 'none');
      push @rows, sprintf("%-10s %-11s %-8s %-7s %s", $p, $net, $sec, maskh($ad), b($c->{remarks} // $o->{tag} // '')) } }
  out() }
if ($t =~ /^\s*(proxies|mixed-port|port|proxy-groups):/m) { my $n = () = $t =~ /^\s*-\s*name:/mg; $fmt .= "Clash YAML ($n proxies)"; out() }
my @l = grep { m{^[a-z0-9]+://} } map { s/\r//gr } split /\n/, $t;
unless (@l) { (my $s = substr($t, 0, 120)) =~ s/[A-Za-z0-9+\/=_-]{16,}/<...>/g; $fmt .= "unknown text: $s"; out() }
$fmt .= 'list of ' . scalar(@l) . ' link(s)';
for (@l) {
  my ($s, $rest) = m{^([a-z0-9]+)://(.*)$}; my $name = ($rest =~ /#(.*)$/) ? $1 : '';
  $name =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
  if ($s eq 'vmess') { my $v = eval { JSON::PP->new->decode(decode_base64((split /#/, $rest)[0])) } // {};
    push @rows, sprintf("%-10s %-11s %-8s %-7s port=%-5s %s", 'vmess', $v->{net} // '-', $v->{tls} || 'none', maskh($v->{add}), $v->{port} // '?', b($v->{ps} // '')); next }
  my ($hp) = $rest =~ m{@([^?#/]+)}; $hp //= (split /[?#\/]/, $rest)[0];
  my ($h, $port) = $hp =~ /^(.*):(\d+)$/ ? ($1, $2) : ($hp, '-');
  my %q = map { my ($k, $v) = split /=/, $_, 2; ($k, $v // '') } split /&/, (($rest =~ /\?([^#]*)/) ? $1 : '');
  push @rows, sprintf("%-10s %-11s %-8s %-7s port=%-5s %s", $s, $q{type} // 'tcp', $q{security} // '-', maskh($h), $port, $name) }
out();
PL

hdr() { grep -i "^$1:" "$TMP/h" | tail -n 1 | cut -d' ' -f2- | tr -d '\r'; }

for url in "$@"; do
  host=$(echo "$url" | awk -F/ '{print $3}')
  echo "=================================================================="
  echo "subscription: $host/..."
  best=""; bestn=0
  for ua in "${UAS[@]}"; do
    code=$(curl -sL --max-time 20 -A "$ua" -H "Accept: */*" -H "x-hwid: 0123456789abcdef" \
      -H "x-device-os: Linux" -H "x-ver-os: OpenWrt" -H "x-device-model: OpenWrt" \
      -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' "$url")
    res=$(perl -e "$PERL" short < "$TMP/b")
    n=$(echo "$res" | sed -n 's/^COUNT //p')
    echo
    echo "--- as $ua: http=$code bytes=$(wc -c < "$TMP/b" | tr -d ' ') content-type=$(hdr content-type)"
    [ -n "$(hdr profile-title)" ] && echo "  profile-title: $(hdr profile-title)"
    [ -n "$(hdr subscription-userinfo)" ] && echo "  subscription-userinfo: $(hdr subscription-userinfo)"
    echo "$res" | grep -v '^COUNT '
    if [ "${n:-0}" -gt "$bestn" ]; then bestn=$n; best=$ua; cp "$TMP/b" "$TMP/best"; fi
  done
  if [ -n "$best" ]; then
    echo
    echo "=== full list as $best ($bestn entries):"
    perl -e "$PERL" full < "$TMP/best" | grep -v '^COUNT '
  fi
done
echo
echo "Done. Nothing secret is printed above; you can paste it as is."
